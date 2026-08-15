#!/bin/zsh
set -euo pipefail

readonly BEFORE_PATH="${1:-}"
readonly AFTER_PATH="${2:-}"
readonly OUTPUT_PATH="${3:-}"
readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"

if [[ -z "$BEFORE_PATH" || -z "$AFTER_PATH" ]]; then
    print -u2 "Usage: ${0:t} before.json after.json [output.json]"
    exit 2
fi
for input_path in "$BEFORE_PATH" "$AFTER_PATH"; do
    if [[ ! -r "$input_path" ]]; then
        print -u2 "Thread snapshot is unreadable: $input_path"
        exit 1
    fi
done
if [[ ! -x "$JQ" ]]; then
    print -u2 "jq is required to compare thread scheduler snapshots."
    exit 1
fi
if ! "$JQ" -e '
    .schema_version == 1
    and (.pid | type == "number")
    and (.captured_epoch_ms | type == "number")
    and (.clock_ticks_per_second | type == "number" and . > 0)
    and (.threads | type == "array")
    and all(.threads[];
      (.tid | type == "number") and (.name | type == "string")
      and (.cpu_ticks | type == "number") and (.runtime_ns | type == "number")
      and (.runqueue_wait_ns | type == "number") and (.timeslices | type == "number"))
  ' "$BEFORE_PATH" "$AFTER_PATH" >/dev/null; then
    print -u2 "A thread snapshot does not satisfy schema version 1."
    exit 2
fi

readonly WORK_ROOT="$(mktemp -d -t mactician-thread-compare)"
cleanup() {
    local exit_code=$?
    rm -rf "$WORK_ROOT"
    return "$exit_code"
}
trap cleanup EXIT
readonly GENERATED_PATH="$WORK_ROOT/comparison.json"

"$JQ" -s '
    def role:
      if . == "GameThread" then "GameThread"
      elif test("^RHIThread") then "RHIThread"
      elif test("^RenderThread") then "RenderThread"
      elif test("^AudioMixer") then "AudioMixer"
      elif test("^(Foreground|Background) Work|^TaskGraph") then "TaskGraphWorkers"
      elif test("PSO|ProgramService"; "i") then "PSOWorkers"
      else "Other"
      end;
    .[0] as $before
    | .[1] as $after
    | if $before.pid != $after.pid then error("PID changed between snapshots") else . end
    | if $before.clock_ticks_per_second != $after.clock_ticks_per_second
        then error("clock-tick frequency changed between snapshots") else . end
    | ($before.threads | map({key: ((.tid | tostring) + "\u0000" + .name), value: .}) | from_entries) as $by_key
    | [ $after.threads[]
        | . as $a
        | ((.tid | tostring) + "\u0000" + .name) as $key
        | select($by_key[$key] != null)
        | $by_key[$key] as $b
        | {
            tid: $a.tid,
            name: $a.name,
            role: ($a.name | role),
            priority: $a.priority,
            nice: $a.nice,
            state_after: $a.state,
            wchan_after: $a.wchan,
            delta_cpu_ticks: ($a.cpu_ticks - $b.cpu_ticks),
            delta_cpu_ms: (($a.cpu_ticks - $b.cpu_ticks) * 1000 / $after.clock_ticks_per_second),
            delta_runtime_ms: (($a.runtime_ns - $b.runtime_ns) / 1000000),
            delta_runqueue_wait_ms: (($a.runqueue_wait_ns - $b.runqueue_wait_ns) / 1000000),
            delta_timeslices: ($a.timeslices - $b.timeslices)
          }
        | . + {runqueue_wait_percent:
            (if (.delta_runtime_ms + .delta_runqueue_wait_ms) > 0
             then (.delta_runqueue_wait_ms * 100 / (.delta_runtime_ms + .delta_runqueue_wait_ms))
             else 0 end)}
        | select(.delta_cpu_ticks >= 0 and .delta_runtime_ms >= 0
            and .delta_runqueue_wait_ms >= 0 and .delta_timeslices >= 0)
      ] as $deltas
    | ($deltas | group_by(.role)
        | map({
            role: .[0].role,
            thread_count: length,
            active_thread_count: (map(select(.delta_runtime_ms > 0
                or .delta_runqueue_wait_ms > 0 or .delta_cpu_ms > 0)) | length),
            delta_cpu_ms: (map(.delta_cpu_ms) | add),
            delta_runtime_ms: (map(.delta_runtime_ms) | add),
            delta_runqueue_wait_ms: (map(.delta_runqueue_wait_ms) | add),
            delta_timeslices: (map(.delta_timeslices) | add)
          })
        | map(. + {runqueue_wait_percent:
            (if (.delta_runtime_ms + .delta_runqueue_wait_ms) > 0
             then (.delta_runqueue_wait_ms * 100 / (.delta_runtime_ms + .delta_runqueue_wait_ms))
             else 0 end)})
        | sort_by(-.delta_cpu_ms)) as $roles
    | {
        schema_version: 1,
        pid: $before.pid,
        window: {
          before_epoch_ms: $before.captured_epoch_ms,
          after_epoch_ms: $after.captured_epoch_ms,
          elapsed_ms: ($after.captured_epoch_ms - $before.captured_epoch_ms),
          clock_ticks_per_second: $after.clock_ticks_per_second
        },
        coverage: {
          before_threads: ($before.threads | length),
          after_threads: ($after.threads | length),
          matched_nonnegative_threads: ($deltas | length)
        },
        totals: {
          delta_cpu_ms: ([$deltas[].delta_cpu_ms] | add // 0),
          delta_runtime_ms: ([$deltas[].delta_runtime_ms] | add // 0),
          delta_runqueue_wait_ms: ([$deltas[].delta_runqueue_wait_ms] | add // 0),
          delta_timeslices: ([$deltas[].delta_timeslices] | add // 0)
        },
        roles: $roles,
        threads: ($deltas | sort_by(-.delta_cpu_ms)),
        interpretation: "Run-queue wait is scheduler delay, not GPU/transport blocking; compare it with simpleperf symbols and pacing tails."
      }
  ' "$BEFORE_PATH" "$AFTER_PATH" > "$GENERATED_PATH"

if [[ -n "$OUTPUT_PATH" ]]; then
    mkdir -p "${OUTPUT_PATH:h}"
    cp "$GENERATED_PATH" "$OUTPUT_PATH"
else
    print -r -- "$(<"$GENERATED_PATH")"
fi
