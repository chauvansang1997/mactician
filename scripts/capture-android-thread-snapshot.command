#!/bin/zsh
set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"
source "$PROJECT_DIR/scripts/android-environment.sh"

readonly GAME_PID="${1:-}"
readonly OUTPUT_PATH="${2:-}"
readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"
readonly SERIAL="${TFT_SERIAL:-emulator-5582}"
readonly ADB_SERVER_PORT="${TFT_ADB_SERVER_PORT:-5038}"
readonly FIXTURE_TSV="${TFT_THREAD_SNAPSHOT_TSV:-}"
readonly CAPTURED_EPOCH_MS="${TFT_THREAD_SNAPSHOT_CAPTURED_EPOCH_MS:-$(($(date +%s) * 1000))}"

if [[ "$GAME_PID" != <-> ]] || (( GAME_PID < 1 )); then
    print -u2 "Usage: ${0:t} game-pid [output.json]"
    exit 2
fi
if [[ ! -x "$JQ" ]]; then
    print -u2 "jq is required to build a thread scheduler snapshot."
    exit 1
fi
if [[ "$CAPTURED_EPOCH_MS" != <-> ]]; then
    print -u2 "TFT_THREAD_SNAPSHOT_CAPTURED_EPOCH_MS must be a non-negative integer."
    exit 2
fi

readonly WORK_ROOT="$(mktemp -d -t mactician-thread-snapshot)"
cleanup() {
    local exit_code=$?
    rm -rf "$WORK_ROOT"
    return "$exit_code"
}
trap cleanup EXIT
readonly THREADS_TSV="$WORK_ROOT/threads.tsv"
typeset CLOCK_TICKS="${TFT_THREAD_SNAPSHOT_CLOCK_TICKS:-}"

if [[ -n "$FIXTURE_TSV" ]]; then
    if [[ ! -r "$FIXTURE_TSV" ]]; then
        print -u2 "Thread snapshot fixture is unreadable: $FIXTURE_TSV"
        exit 1
    fi
    cp "$FIXTURE_TSV" "$THREADS_TSV"
    CLOCK_TICKS="${CLOCK_TICKS:-100}"
else
    if [[ "$ADB_SERVER_PORT" != <-> ]] \
            || (( ADB_SERVER_PORT < 1024 || ADB_SERVER_PORT > 65534 )); then
        print -u2 "TFT_ADB_SERVER_PORT must be a TCP port from 1024 through 65534."
        exit 2
    fi
    ADB="$(tft_resolve_adb)"
    readonly ADB
    unset ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS
    export ANDROID_ADB_SERVER_PORT="$ADB_SERVER_PORT"
    if ! "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
        print -u2 "The Android device is unavailable on $SERIAL."
        exit 1
    fi
    CLOCK_TICKS="${CLOCK_TICKS:-$(
        "$ADB" -s "$SERIAL" shell getconf CLK_TCK 2>/dev/null | tr -d '\r' || true
    )}"
    [[ "$CLOCK_TICKS" == <-> ]] || CLOCK_TICKS=100

    # One ADB round trip keeps the snapshot boundary tight. Only public procfs
    # scheduler counters and thread names are emitted; no stacks or game data
    # are read.
    "$ADB" -s "$SERIAL" shell "
        pid='$GAME_PID'
        for task_dir in /proc/\$pid/task/[0-9]*; do
            test -r \"\$task_dir/stat\" || continue
            tid=\${task_dir##*/}
            task_stat=\$(cat \"\$task_dir/stat\" 2>/dev/null) || continue
            stat_tail=\${task_stat##*) }
            set -- \$stat_tail
            state=\${1:-?}
            utime=\${12:-0}
            stime=\${13:-0}
            priority=\${16:-0}
            nice_value=\${17:-0}
            name=\$(tr '\\t\\r\\n' '   ' < \"\$task_dir/comm\" 2>/dev/null)
            set -- \$(cat \"\$task_dir/schedstat\" 2>/dev/null)
            runtime_ns=\${1:-0}
            runqueue_wait_ns=\${2:-0}
            timeslices=\${3:-0}
            wchan=\$(tr '\\t\\r\\n' '   ' < \"\$task_dir/wchan\" 2>/dev/null)
            printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \
                \"\$tid\" \"\$name\" \"\$state\" \"\$utime\" \"\$stime\" \
                \"\$priority\" \"\$nice_value\" \"\$runtime_ns\" \
                \"\$runqueue_wait_ns\" \"\$timeslices\" \"\$wchan\"
        done
    " > "$THREADS_TSV"
fi

if [[ "$CLOCK_TICKS" != <-> ]] || (( CLOCK_TICKS < 1 || CLOCK_TICKS > 1000000 )); then
    print -u2 "Invalid clock-tick frequency: ${CLOCK_TICKS:-empty}"
    exit 2
fi
if [[ ! -s "$THREADS_TSV" ]]; then
    print -u2 "No readable task scheduler records were captured for PID $GAME_PID."
    exit 1
fi

readonly GENERATED_PATH="$WORK_ROOT/snapshot.json"
"$JQ" -Rn \
    --argjson pid "$GAME_PID" \
    --argjson captured_epoch_ms "$CAPTURED_EPOCH_MS" \
    --argjson clock_ticks_per_second "$CLOCK_TICKS" '
    [inputs
      | split("\t")
      | select(length >= 11)
      | {
          tid: (.[0] | tonumber),
          name: (.[1] | gsub("^\\s+|\\s+$"; "")),
          state: .[2],
          utime_ticks: (.[3] | tonumber),
          stime_ticks: (.[4] | tonumber),
          cpu_ticks: ((.[3] | tonumber) + (.[4] | tonumber)),
          priority: (.[5] | tonumber),
          nice: (.[6] | tonumber),
          runtime_ns: (.[7] | tonumber),
          runqueue_wait_ns: (.[8] | tonumber),
          timeslices: (.[9] | tonumber),
          wchan: (.[10] | gsub("^\\s+|\\s+$"; ""))
        }
    ] | sort_by(.tid) as $threads
    | {
        schema_version: 1,
        pid: $pid,
        captured_epoch_ms: $captured_epoch_ms,
        clock_ticks_per_second: $clock_ticks_per_second,
        privacy: "procfs scheduler counters and thread names only",
        totals: {
          thread_count: ($threads | length),
          cpu_ticks: ([$threads[].cpu_ticks] | add // 0),
          runtime_ns: ([$threads[].runtime_ns] | add // 0),
          runqueue_wait_ns: ([$threads[].runqueue_wait_ns] | add // 0)
        },
        threads: $threads
      }
  ' < "$THREADS_TSV" > "$GENERATED_PATH"

if [[ -n "$OUTPUT_PATH" ]]; then
    mkdir -p "${OUTPUT_PATH:h}"
    cp "$GENERATED_PATH" "$OUTPUT_PATH"
else
    print -r -- "$(<"$GENERATED_PATH")"
fi
