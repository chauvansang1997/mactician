#!/bin/zsh
set -euo pipefail

unsetopt BG_NICE

readonly PROJECT_DIR="${0:A:h:h}"
readonly CAMPAIGN_SCRIPT="${0:A}"
source "$PROJECT_DIR/scripts/android-environment.sh"
readonly TRIAL_RUNNER="$PROJECT_DIR/scripts/run-autonomous-trial-benchmark.command"
readonly LEADERBOARD_BUILDER="$PROJECT_DIR/scripts/build-performance-leaderboard.command"
readonly CLASSIFIER_BUILD="$PROJECT_DIR/scripts/build-tft-screen-classifier.command"
readonly CLASSIFIER_TEST="$PROJECT_DIR/scripts/test-tft-screen-classifier.command"
readonly CANDIDATE_MANIFEST="$PROJECT_DIR/scripts/performance-candidates.json"
readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"
readonly CAMPAIGN_ROOT="${TFT_PERFORMANCE_CAMPAIGN_ROOT:-$PROJECT_DIR/runtime/measurements/performance-campaign}"
readonly ACTIVE_FILE="$CAMPAIGN_ROOT/active-campaign.txt"
ADB="$(tft_resolve_adb)"
readonly ADB
readonly SERIAL="${TFT_SERIAL:-emulator-5582}"
readonly ADB_SERVER_PORT="${TFT_ADB_SERVER_PORT:-5038}"
readonly DEFAULT_DURATION="10h"
readonly FINAL_RESERVE_SECONDS=2400
readonly CANDIDATE_WATCHDOG_SECONDS=3000

typeset DURATION="$DEFAULT_DURATION"
typeset RESUME=0
typeset DRY_RUN=0
typeset SELF_TEST=0
typeset CUSTOM_QUEUE_CSV=""

while (( $# > 0 )); do
    case "$1" in
        --duration)
            (( $# >= 2 )) || { print "--duration requires a value such as 10h"; exit 2; }
            DURATION="$2"
            shift 2
            ;;
        --resume)
            RESUME=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --queue)
            (( $# >= 2 )) || { print "--queue requires comma-separated candidate IDs"; exit 2; }
            CUSTOM_QUEUE_CSV="$2"
            shift 2
            ;;
        -h|--help)
            print "Usage: ${0:t} [--duration 10h] [--queue id,id,...] [--resume] [--dry-run] [--self-test]"
            exit 0
            ;;
        *)
            print "Unknown argument: $1"
            exit 2
            ;;
    esac
done

if [[ -n "$CUSTOM_QUEUE_CSV" ]] \
        && ! print -r -- "$CUSTOM_QUEUE_CSV" \
            | grep -Eq '^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$'; then
    print "--queue must be a comma-separated list of lowercase candidate IDs."
    exit 2
fi

duration_seconds() {
    local value="$1"
    if ! print -r -- "$value" | grep -Eq '^[1-9][0-9]*[hms]$'; then
        print "Duration must use a value such as 10h, 30m, or 600s."
        return 2
    fi
    local number="${value[1,-2]}"
    case "${value[-1]}" in
        h) print $(( number * 3600 )) ;;
        m) print $(( number * 60 )) ;;
        s) print "$number" ;;
    esac
}

readonly REQUESTED_DURATION_SECONDS="$(duration_seconds "$DURATION")"
if (( REQUESTED_DURATION_SECONDS < 60 )); then
    print "The campaign must run for at least 60 seconds."
    exit 2
fi

if (( SELF_TEST == 0 && DRY_RUN == 0 )) \
        && [[ "${TFT_CAMPAIGN_CAFFEINATED:-0}" != "1" ]]; then
    typeset -a caffeinated_args
    caffeinated_args=(--duration "$DURATION")
    (( RESUME == 1 )) && caffeinated_args+=(--resume)
    [[ -n "$CUSTOM_QUEUE_CSV" ]] && caffeinated_args+=(--queue "$CUSTOM_QUEUE_CSV")
    exec /usr/bin/caffeinate -dimsu \
        /usr/bin/env TFT_CAMPAIGN_CAFFEINATED=1 \
        "$CAMPAIGN_SCRIPT" "${caffeinated_args[@]}"
fi

for required_file in "$TRIAL_RUNNER" "$LEADERBOARD_BUILDER" "$CLASSIFIER_BUILD" "$CLASSIFIER_TEST" \
        "$CANDIDATE_MANIFEST" "$JQ"; do
    if [[ ! -e "$required_file" ]]; then
        print "Required campaign file not found: $required_file"
        exit 1
    fi
done
if ! "$JQ" -e '.schemaVersion == 1' "$CANDIDATE_MANIFEST" >/dev/null; then
    print "Invalid candidate manifest: $CANDIDATE_MANIFEST"
    exit 2
fi

mkdir -p "$CAMPAIGN_ROOT"
typeset CAMPAIGN_DIR="" RESUMED_QUEUE_CSV=""
typeset RESUMED_FOCUSED_QUEUE=0
typeset START_EPOCH DEADLINE_EPOCH QUEUE_INDEX=0
if (( RESUME == 1 )) && [[ -f "$ACTIVE_FILE" ]]; then
    IFS= read -r CAMPAIGN_DIR < "$ACTIVE_FILE" || true
    if [[ -n "$CAMPAIGN_DIR" && -f "$CAMPAIGN_DIR/checkpoint.json" ]]; then
        if [[ "$("$JQ" -r '.status' "$CAMPAIGN_DIR/checkpoint.json")" == complete ]]; then
            CAMPAIGN_DIR=""
        else
            START_EPOCH="$("$JQ" -r '.started_epoch' "$CAMPAIGN_DIR/checkpoint.json")"
            DEADLINE_EPOCH="$("$JQ" -r '.deadline_epoch' "$CAMPAIGN_DIR/checkpoint.json")"
            QUEUE_INDEX="$("$JQ" -r '.queue_index // 0' "$CAMPAIGN_DIR/checkpoint.json")"
            RESUMED_QUEUE_CSV="$("$JQ" -r '(.queue // []) | join(",")' "$CAMPAIGN_DIR/checkpoint.json")"
            if [[ "$("$JQ" -r '.focused_queue // false' "$CAMPAIGN_DIR/checkpoint.json")" == true ]]; then
                RESUMED_FOCUSED_QUEUE=1
            fi
        fi
    else
        CAMPAIGN_DIR=""
    fi
fi

if [[ -z "$CAMPAIGN_DIR" ]]; then
    readonly CAMPAIGN_STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
    CAMPAIGN_DIR="$CAMPAIGN_ROOT/$CAMPAIGN_STAMP"
    mkdir -p "$CAMPAIGN_DIR/runs"
    START_EPOCH="$(date +%s)"
    DEADLINE_EPOCH=$(( START_EPOCH + REQUESTED_DURATION_SECONDS ))
    # A self-test owns a disposable checkpoint and must not replace the pointer
    # to the last real campaign/leaderboard used by release and launcher audits.
    if (( SELF_TEST == 0 )); then
        print -r -- "$CAMPAIGN_DIR" > "$ACTIVE_FILE.next"
        mv -f "$ACTIVE_FILE.next" "$ACTIVE_FILE"
    fi
else
    mkdir -p "$CAMPAIGN_DIR/runs"
fi

readonly CAMPAIGN_DIR START_EPOCH DEADLINE_EPOCH
readonly CHECKPOINT="$CAMPAIGN_DIR/checkpoint.json"
readonly EVENTS="$CAMPAIGN_DIR/events.jsonl"
readonly RUN_LOG_ROOT="$CAMPAIGN_DIR/runs"
readonly CAMPAIGN_MANIFEST="$CAMPAIGN_DIR/candidates.json"
if [[ ! -f "$CAMPAIGN_MANIFEST" ]]; then
    cp "$CANDIDATE_MANIFEST" "$CAMPAIGN_MANIFEST"
else
    # Refresh canonical candidates while preserving dynamically derived
    # profile/resolution/sustained entries across --resume.
    "$JQ" -s '
        .[0] as $base | .[1] as $campaign
        | ($base.candidates | map(.id)) as $base_ids
        | $base
        | .candidates += [$campaign.candidates[] | select(.id as $id | ($base_ids | index($id)) == null)]
    ' "$CANDIDATE_MANIFEST" "$CAMPAIGN_MANIFEST" > "$CAMPAIGN_MANIFEST.next"
    mv -f "$CAMPAIGN_MANIFEST.next" "$CAMPAIGN_MANIFEST"
fi

typeset -a QUEUE
QUEUE=(
    control
    submit
    control
    shader-prewarm-control
    submit-prewarm
    angle-no-fbo-submit
    descriptor-batching-off
    upstream-asg
    mvk128
    mvk256
)
typeset -a COMBINATION_QUEUE
COMBINATION_QUEUE=(submit-no-fbo submit-upstream-asg submit-mvk128)
typeset FOCUSED_QUEUE=0
if [[ -n "$RESUMED_QUEUE_CSV" ]]; then
    if [[ -n "$CUSTOM_QUEUE_CSV" \
            && ( "$CUSTOM_QUEUE_CSV" != "$RESUMED_QUEUE_CSV" \
                || "$RESUMED_FOCUSED_QUEUE" != 1 ) ]]; then
        print "--queue does not match the focused queue stored in the resumed campaign checkpoint."
        exit 2
    fi
    QUEUE=("${(@s:,:)RESUMED_QUEUE_CSV}")
    FOCUSED_QUEUE="$RESUMED_FOCUSED_QUEUE"
    (( FOCUSED_QUEUE == 1 )) && COMBINATION_QUEUE=()
elif [[ -n "$CUSTOM_QUEUE_CSV" ]]; then
    QUEUE=("${(@s:,:)CUSTOM_QUEUE_CSV}")
    COMBINATION_QUEUE=()
    FOCUSED_QUEUE=1
fi

typeset CURRENT_CHILD_PID=""
typeset CURRENT_CANDIDATE=""
integer RUN_SEQUENCE=0
typeset ORIGINAL_POWER_MODE="$(
    pmset -g custom 2>/dev/null \
        | awk '/^AC Power:/{ ac=1; next } ac && $1 == "powermode" { print $2; exit }'
)"
typeset POWER_MODE_CHANGED=0
typeset CAMPAIGN_CLEANING_UP=0

write_checkpoint() {
    local checkpoint_status="$1"
    local phase="$2"
    local note="${3:-}"
    local now="$(date +%s)"
    "$JQ" -n \
        --arg campaign_dir "$CAMPAIGN_DIR" \
        --arg status "$checkpoint_status" \
        --arg phase "$phase" \
        --arg note "$note" \
        --arg queue "${(j:,:)QUEUE}" \
        --arg current_candidate "$CURRENT_CANDIDATE" \
        --argjson started_epoch "$START_EPOCH" \
        --argjson deadline_epoch "$DEADLINE_EPOCH" \
        --argjson last_heartbeat_epoch "$now" \
        --argjson queue_index "$QUEUE_INDEX" \
        --argjson focused_queue "$FOCUSED_QUEUE" \
        --argjson current_child_pid "${CURRENT_CHILD_PID:-null}" \
        '{
            schema_version: 1,
            campaign_dir: $campaign_dir,
            status: $status,
            phase: $phase,
            note: $note,
            started_epoch: $started_epoch,
            deadline_epoch: $deadline_epoch,
            last_heartbeat_epoch: $last_heartbeat_epoch,
            queue_index: $queue_index,
            queue: (if $queue == "" then [] else ($queue | split(",")) end),
            focused_queue: ($focused_queue == 1),
            current_candidate: (if $current_candidate == "" then null else $current_candidate end),
            current_child_pid: $current_child_pid
        }' > "$CHECKPOINT.next"
    mv -f "$CHECKPOINT.next" "$CHECKPOINT"
}

record_event() {
    local event="$1"
    local detail="${2:-}"
    "$JQ" -nc \
        --arg utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg event "$event" \
        --arg detail "$detail" \
        --arg candidate "$CURRENT_CANDIDATE" \
        '{utc: $utc, event: $event, detail: $detail, candidate: (if $candidate == "" then null else $candidate end)}' \
        >> "$EVENTS"
}

restore_power_mode() {
    if (( POWER_MODE_CHANGED == 1 )) && [[ -n "$ORIGINAL_POWER_MODE" ]]; then
        /usr/bin/sudo -n /usr/bin/pmset -a powermode "$ORIGINAL_POWER_MODE" >/dev/null 2>&1 || true
        POWER_MODE_CHANGED=0
        record_event power_mode_restored "$ORIGINAL_POWER_MODE"
    fi
}

campaign_cleanup() {
    local exit_code=$?
    if (( CAMPAIGN_CLEANING_UP == 1 )); then
        return
    fi
    CAMPAIGN_CLEANING_UP=1
    trap - EXIT
    set +e
    if [[ -n "$CURRENT_CHILD_PID" ]] && kill -0 "$CURRENT_CHILD_PID" >/dev/null 2>&1; then
        kill -TERM "$CURRENT_CHILD_PID" >/dev/null 2>&1
        integer waited=0
        while kill -0 "$CURRENT_CHILD_PID" >/dev/null 2>&1 && (( waited < 180 )); do
            sleep 1
            (( waited += 1 ))
        done
        wait "$CURRENT_CHILD_PID" >/dev/null 2>&1 || true
    fi
    CURRENT_CHILD_PID=""
    restore_power_mode
    "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
    if (( exit_code == 0 )); then
        write_checkpoint complete final_cleanup "campaign completed"
    else
        write_checkpoint interrupted final_cleanup "exit_status=$exit_code; use --resume"
    fi
    exit "$exit_code"
}
trap campaign_cleanup EXIT
trap 'exit 130' HUP INT TERM

offline_maintenance() {
    local syntax_script queued_candidate queued_count
    record_event offline_maintenance_start
    for syntax_script in \
            "$TRIAL_RUNNER" \
            "$PROJECT_DIR/scripts/capture-frame-pacing.command" \
            "$PROJECT_DIR/scripts/login-tft-from-keychain.command" \
            "$PROJECT_DIR/scripts/run-asg-experiment.command" \
            "$CAMPAIGN_SCRIPT" \
            "$LEADERBOARD_BUILDER"; do
        zsh -o NO_BG_NICE -n "$syntax_script"
    done
    "$JQ" -e '
        .schemaVersion == 1
        and (.candidates | type == "array" and length > 0)
        and ([.candidates[].id] | length == (unique | length))
        and ([.candidates[].variant] | length == (unique | length))
    ' \
        "$CAMPAIGN_MANIFEST" >/dev/null
    for queued_candidate in "${QUEUE[@]}" "${COMBINATION_QUEUE[@]}"; do
        queued_count="$(
            "$JQ" --arg id "$queued_candidate" \
                '[.candidates[] | select(.id == $id)] | length' \
                "$CAMPAIGN_MANIFEST"
        )"
        if [[ "$queued_count" != "1" ]]; then
            print "Campaign queue candidate must occur exactly once: $queued_candidate"
            return 2
        fi
    done
    "$CLASSIFIER_BUILD" > "$CAMPAIGN_DIR/classifier-build.log"
    "$CLASSIFIER_TEST" > "$CAMPAIGN_DIR/classifier-test.log"
    "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
    record_event offline_maintenance_complete
}

latest_run_dir() {
    local candidate="$1"
    find "$PROJECT_DIR/runtime/measurements/autonomous-trial" -maxdepth 1 -type d \
        -name "*__${candidate}__*" -print 2>/dev/null | sort | tail -n 1
}

partial_candidate_fails_baseline() {
    local candidate="$1"
    [[ "$candidate" != control && "$candidate" != sustained-* \
            && -f "$CAMPAIGN_DIR/leaderboard.tsv" ]] || return 1
    local baseline_fps partial_summary candidate_fps
    baseline_fps="$(awk -F '\t' '$1 == "control" { print $3; exit }' \
        "$CAMPAIGN_DIR/leaderboard.tsv")"
    [[ -n "$baseline_fps" && "$baseline_fps" != 0 ]] || return 1
    partial_summary="$({
        find "$PROJECT_DIR/runtime/measurements/autonomous-trial" -maxdepth 2 -type f \
            -path "*__${candidate}__*/result-summary-1-2.json" -print 2>/dev/null \
            | sort -r | head -n 1
    } || true)"
    [[ -n "$partial_summary" ]] || return 1
    candidate_fps="$("$JQ" -r '.pacing.fps // 0' "$partial_summary")"
    awk -v score="$candidate_fps" -v baseline="$baseline_fps" \
        'BEGIN { exit !(score > 0 && score < baseline * 0.95) }'
}

is_login_block() {
    local run_dir="$1"
    [[ -f "$run_dir/current.json" ]] || return 1
    local state reason
    state="$("$JQ" -r '.state // "unknown"' "$run_dir/current.json")"
    reason="$("$JQ" -r '.reason // ""' "$run_dir/current.json")"
    [[ "$state" == login || "$state" == login_service_error \
        || "$reason" == *login* || "$reason" == *service_error* ]]
}

wait_with_heartbeat() {
    local seconds="$1"
    local note="$2"
    local wait_deadline=$(( $(date +%s) + seconds ))
    while (( $(date +%s) < wait_deadline && $(date +%s) < DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )); do
        write_checkpoint running login_backoff "$note"
        sleep 30
    done
}

thermal_pressure_present() {
    local report
    report="$(pmset -g therm 2>/dev/null || true)"
    [[ -n "$report" ]] || return 1
    [[ "$report" == *"No thermal warning level has been recorded"* ]] && return 1
    [[ "$report" == *"CPU_Speed_Limit"* && "$report" != *"CPU_Speed_Limit = 100"* ]] && return 0
    [[ "$report" == *"Thermal_Level"* && "$report" != *"Thermal_Level = 0"* ]] && return 0
    return 1
}

wait_for_thermal_headroom() {
    local waited=0
    while thermal_pressure_present; do
        record_event thermal_pause "waited=${waited}s"
        write_checkpoint running thermal_pause "candidate=$CURRENT_CANDIDATE waited=${waited}s"
        if (( $(date +%s) >= DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )); then
            return 75
        fi
        "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
        sleep 30
        (( waited += 30 ))
    done
    (( waited > 0 )) && record_event thermal_resumed "waited=${waited}s"
    return 0
}

run_candidate() {
    local candidate="$1"
    local manifest="${2:-$CAMPAIGN_MANIFEST}"
    local attempt=0 child_status run_dir result_state log_file candidate_started candidate_deadline run_tag
    local -a login_backoff
    login_backoff=(900 1800 3600)
    CURRENT_CANDIDATE="$candidate"

    if partial_candidate_fails_baseline "$candidate"; then
        record_event candidate_fail_fast \
            "existing partial 1-2 result is below 95% control; no retry"
        CURRENT_CANDIDATE=""
        return 65
    fi

    while (( attempt < 4 )); do
        if (( $(date +%s) >= DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )); then
            record_event candidate_skipped "final reserve reached"
            return 75
        fi
        wait_for_thermal_headroom || return $?
        (( attempt += 1 ))
        (( RUN_SEQUENCE += 1 ))
        candidate_started="$(date +%s)"
        run_tag="$(date -u '+%Y%m%dT%H%M%SZ')-${RUN_SEQUENCE}"
        candidate_deadline=$(( candidate_started + CANDIDATE_WATCHDOG_SECONDS ))
        log_file="$RUN_LOG_ROOT/${candidate}-${run_tag}-attempt-${attempt}.log"
        write_checkpoint running trial "attempt=$attempt"
        record_event candidate_start "attempt=$attempt manifest=$manifest"

        if (( DRY_RUN == 1 )); then
            print "DRY-RUN candidate=$candidate attempt=$attempt" | tee "$log_file"
            record_event candidate_dry_run
            CURRENT_CANDIDATE=""
            return 0
        fi

        TFT_PERFORMANCE_CANDIDATES="$manifest" \
        TFT_TRIAL_NAVIGATION_TIMEOUT=2400 \
        TFT_ADB_SERVER_PORT="$ADB_SERVER_PORT" \
        TFT_SERIAL="$SERIAL" \
            "$TRIAL_RUNNER" "$candidate" > "$log_file" 2>&1 &
        CURRENT_CHILD_PID=$!
        while kill -0 "$CURRENT_CHILD_PID" >/dev/null 2>&1; do
            if (( $(date +%s) >= candidate_deadline )); then
                record_event candidate_watchdog "timeout=$CANDIDATE_WATCHDOG_SECONDS"
                kill -TERM "$CURRENT_CHILD_PID" >/dev/null 2>&1 || true
                break
            fi
            write_checkpoint running trial "attempt=$attempt pid=$CURRENT_CHILD_PID"
            sleep 30
        done
        set +e
        wait "$CURRENT_CHILD_PID"
        child_status=$?
        set -e
        CURRENT_CHILD_PID=""
        run_dir="$(latest_run_dir "$candidate")"
        "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
        result_state=failed
        if [[ -n "$run_dir" && -f "$run_dir/run-result.json" ]] \
                && "$JQ" -e '
                    (.benchmark_succeeded == true
                      or .transport_screen_succeeded == true
                      or .gles_stress_succeeded == true
                      or .gles_draw_succeeded == true)
                    and .rollback.verified == true
                ' \
                    "$run_dir/run-result.json" >/dev/null 2>&1; then
            result_state=success
        elif [[ -n "$run_dir" && -f "$run_dir/run-result.json" ]] \
                && ! "$JQ" -e '.rollback.verified == true' "$run_dir/run-result.json" >/dev/null 2>&1; then
            result_state=rollback_failed
        elif [[ -n "$run_dir" ]] \
                && grep -Fq 'The Trial ended before all semantic stages or the minimum duration were measured.' \
                    "$log_file" 2>/dev/null; then
            result_state=trial_ended_early
        elif [[ -n "$run_dir" ]] \
                && grep -Eq 'Target stage [1-9]-[0-9]+ was missed' \
                    "$log_file" 2>/dev/null; then
            result_state=semantic_stage_missed
        elif [[ -n "$run_dir" ]] && is_login_block "$run_dir"; then
            result_state=login_blocked
        fi
        "$JQ" -nc \
            --arg utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            --arg candidate "$candidate" \
            --arg run_dir "$run_dir" \
            --arg state "$result_state" \
            --argjson attempt "$attempt" \
            --argjson exit_status "$child_status" \
            '{utc: $utc, candidate: $candidate, attempt: $attempt, exit_status: $exit_status, state: $state, run_dir: $run_dir}' \
            >> "$CAMPAIGN_DIR/runs.jsonl"
        record_event candidate_complete "attempt=$attempt status=$child_status state=$result_state run_dir=$run_dir"

        if [[ "$result_state" == success ]]; then
            CURRENT_CANDIDATE=""
            return 0
        fi
        if [[ "$result_state" == rollback_failed ]]; then
            print "Rollback for candidate $candidate was not confirmed; campaign stopped: $run_dir"
            return 4
        fi
        if [[ ( "$result_state" == trial_ended_early \
                || "$result_state" == semantic_stage_missed ) && attempt -lt 3 ]]; then
            if partial_candidate_fails_baseline "$candidate"; then
                record_event candidate_fail_fast \
                    "partial 1-2 result is below 95% control; retry suppressed"
                CURRENT_CANDIDATE=""
                return "$child_status"
            fi
            record_event candidate_retry "reason=$result_state next_attempt=$(( attempt + 1 ))"
            continue
        fi
        if [[ "$result_state" != login_blocked ]] || (( attempt >= 4 )); then
            CURRENT_CANDIDATE=""
            return "$child_status"
        fi
        offline_maintenance
        wait_with_heartbeat "${login_backoff[$attempt]:-3600}" "candidate=$candidate retry=$(( attempt + 1 ))"
    done
    CURRENT_CANDIDATE=""
    return 3
}

candidate_is_eligible() {
    local candidate="$1"
    local table="$CAMPAIGN_DIR/leaderboard.tsv"
    [[ -f "$table" ]] || return 1
    local control_score control_p95 candidate_score candidate_p95 candidate_runs
    control_score="$(awk -F '\t' '$1 == "control" { print $6; exit }' "$table")"
    control_p95="$(awk -F '\t' '$1 == "control" { print $7; exit }' "$table")"
    candidate_score="$(awk -F '\t' -v candidate="$candidate" '$1 == candidate { print $6; exit }' "$table")"
    candidate_p95="$(awk -F '\t' -v candidate="$candidate" '$1 == candidate { print $7; exit }' "$table")"
    candidate_runs="$(awk -F '\t' -v candidate="$candidate" '$1 == candidate { print $2; exit }' "$table")"
    [[ -n "$control_score" && -n "$candidate_score" && "$control_score" != 0 && "$candidate_score" != 0 \
            && "${candidate_runs:-0}" -ge 2 ]] \
        || return 1
    awk -v score="$candidate_score" -v baseline="$control_score" \
        -v p95="$candidate_p95" -v baseline_p95="$control_p95" \
        'BEGIN { exit !(score >= baseline * 1.03 && p95 <= baseline_p95 * 1.05) }'
}

resolution_is_acceptable() {
    local candidate="$1"
    local baseline="$2"
    local table="$CAMPAIGN_DIR/leaderboard.tsv"
    [[ -f "$table" ]] || return 1
    local baseline_score baseline_p95 candidate_score candidate_p95
    baseline_score="$(awk -F '\t' -v id="$baseline" '$1 == id { print $6; exit }' "$table")"
    baseline_p95="$(awk -F '\t' -v id="$baseline" '$1 == id { print $7; exit }' "$table")"
    candidate_score="$(awk -F '\t' -v id="$candidate" '$1 == id { print $6; exit }' "$table")"
    candidate_p95="$(awk -F '\t' -v id="$candidate" '$1 == id { print $7; exit }' "$table")"
    [[ -n "$baseline_score" && -n "$candidate_score" && "$baseline_score" != 0 && "$candidate_score" != 0 ]] \
        || return 1
    awk -v score="$candidate_score" -v baseline="$baseline_score" \
        -v p95="$candidate_p95" -v baseline_p95="$baseline_p95" \
        'BEGIN { exit !(score >= baseline * 0.98 && p95 <= baseline_p95 * 1.05) }'
}

candidate_improves_baseline() {
    local candidate="$1"
    local baseline="$2"
    local table="$CAMPAIGN_DIR/leaderboard.tsv"
    [[ -f "$table" ]] || return 1
    local baseline_score baseline_p95 candidate_score candidate_p95
    baseline_score="$(awk -F '\t' -v id="$baseline" '$1 == id { print $6; exit }' "$table")"
    baseline_p95="$(awk -F '\t' -v id="$baseline" '$1 == id { print $7; exit }' "$table")"
    candidate_score="$(awk -F '\t' -v id="$candidate" '$1 == id { print $6; exit }' "$table")"
    candidate_p95="$(awk -F '\t' -v id="$candidate" '$1 == id { print $7; exit }' "$table")"
    [[ -n "$baseline_score" && -n "$candidate_score" && "$baseline_score" != 0 && "$candidate_score" != 0 ]] \
        || return 1
    awk -v score="$candidate_score" -v baseline="$baseline_score" \
        -v p95="$candidate_p95" -v baseline_p95="$baseline_p95" \
        'BEGIN { exit !(score >= baseline * 1.03 && p95 <= baseline_p95 * 1.05) }'
}

combination_prerequisite() {
    case "$1" in
        submit-no-fbo) print angle-no-fbo-submit ;;
        submit-upstream-asg) print upstream-asg ;;
        submit-mvk128) print mvk128 ;;
        *) print "" ;;
    esac
}

champion_candidate() {
    local table="$CAMPAIGN_DIR/leaderboard.tsv"
    [[ -f "$table" ]] || return 1
    local control_score control_p95
    control_score="$(awk -F '\t' '$1 == "control" { print $6; exit }' "$table")"
    control_p95="$(awk -F '\t' '$1 == "control" { print $7; exit }' "$table")"
    [[ -n "$control_score" && -n "$control_p95" ]] || return 1
    awk -F '\t' -v baseline="$control_score" -v baseline_p95="$control_p95" '
        NR > 1 && $6 + 0 > 0 && $1 !~ /^champion-/ && $1 !~ /^resolution-/ \
            && $1 !~ /^profile-/ && $1 !~ /^sustained-/ \
            && ($1 == "control" || ($2 >= 2 && $6 >= baseline * 1.03 && $7 <= baseline_p95 * 1.05)) {
                print $1
                exit
            }
    ' "$table"
}

add_derived_candidate() {
    local base_id="$1"
    local id="$2"
    local display="$3"
    local density="$4"
    local stages_json="$5"
    "$JQ" \
        --arg base "$base_id" \
        --arg id "$id" \
        --arg display "$display" \
        --argjson density "$density" \
        --argjson stages "$stages_json" \
        '.candidates as $all
         | ($all[] | select(.id == $base)) as $source
         | .candidates = ([.candidates[] | select(.id != $id)] + [
             ($source + {
                 id: $id,
                 variant: ($source.variant + "_" + ($display | gsub("x"; "_"))),
                 display: $display,
                 density: $density,
                 stages: $stages
             })
         ])' "$CAMPAIGN_MANIFEST" > "$CAMPAIGN_MANIFEST.next"
    mv -f "$CAMPAIGN_MANIFEST.next" "$CAMPAIGN_MANIFEST"
}

set_candidate_extras() {
    local id="$1"
    local profile_stage="$2"
    local minimum_trial_seconds="$3"
    "$JQ" \
        --arg id "$id" \
        --arg profile_stage "$profile_stage" \
        --argjson minimum_trial_seconds "$minimum_trial_seconds" \
        '.candidates = [.candidates[]
            | if .id == $id then
                . + {
                    profileStage: (if $profile_stage == "" then null else $profile_stage end),
                    minimumTrialSeconds: $minimum_trial_seconds
                }
              else . end
        ]' "$CAMPAIGN_MANIFEST" > "$CAMPAIGN_MANIFEST.next"
    mv -f "$CAMPAIGN_MANIFEST.next" "$CAMPAIGN_MANIFEST"
}

if (( SELF_TEST == 1 )); then
    write_checkpoint running self_test start
    record_event self_test_start
    offline_maintenance
    QUEUE_INDEX=2
    write_checkpoint interrupted self_test simulated_interrupt
    QUEUE_INDEX="$("$JQ" -r '.queue_index' "$CHECKPOINT")"
    [[ "$QUEUE_INDEX" == 2 ]] || { print "Checkpoint resume self-test failed."; exit 1; }
    [[ "$("$JQ" -r '.queue | join(",")' "$CHECKPOINT")" == "${(j:,:)QUEUE}" ]] \
        || { print "Checkpoint queue self-test failed."; exit 1; }
    [[ "$("$JQ" -r '.focused_queue' "$CHECKPOINT")" == \
            "$([[ "$FOCUSED_QUEUE" == 1 ]] && print true || print false)" ]] \
        || { print "Checkpoint queue-mode self-test failed."; exit 1; }
    record_event self_test_complete
    print "Performance campaign self-test: OK ($CAMPAIGN_DIR)"
    exit 0
fi

offline_maintenance
write_checkpoint running primary "campaign started or resumed"
record_event campaign_start "deadline_epoch=$DEADLINE_EPOCH resume=$RESUME"

while (( QUEUE_INDEX < ${#QUEUE} )); do
    if (( $(date +%s) >= DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )); then
        break
    fi
    candidate="${QUEUE[$(( QUEUE_INDEX + 1 ))]}"
    prerequisite="$(combination_prerequisite "$candidate")"
    if [[ "$candidate" == submit-* ]] && ! candidate_is_eligible submit; then
        CURRENT_CANDIDATE="$candidate"
        record_event candidate_skipped "submit-thread not independently eligible"
        CURRENT_CANDIDATE=""
    elif [[ -n "$prerequisite" ]] && ! candidate_is_eligible "$prerequisite"; then
        CURRENT_CANDIDATE="$candidate"
        record_event candidate_skipped "prerequisite $prerequisite not eligible"
        CURRENT_CANDIDATE=""
    else
        run_candidate "$candidate" "$CAMPAIGN_MANIFEST" || true
    fi
    (( QUEUE_INDEX += 1 ))
    write_checkpoint running experiments "queue advanced"
done

"$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true

if (( FOCUSED_QUEUE == 1 )); then
    record_event focused_queue_complete "queue=${(j:,:)QUEUE}"
    write_checkpoint complete focused_queue "requested candidates completed"
    print "Focused performance campaign completed: $CAMPAIGN_DIR"
    exit 0
fi

# A single lucky scene is not reproducibility. Repeat the two strongest
# completed one-factor candidates before selecting a champion or combining
# factors. Resume naturally skips a candidate once it has two full 1-5 runs.
typeset -a repeat_candidates
repeat_candidates=("${(@f)$(
    awk -F '\t' '
        NR > 1 && $1 != "control" && $6 + 0 > 0 &&
            $1 !~ /^profile-/ && $1 !~ /^sustained-/ && $1 !~ /^champion-/ {
                print $1 "\t" $6
            }
    ' "$CAMPAIGN_DIR/leaderboard.tsv" | sort -t $'\t' -k2,2nr | head -n 2 | cut -f1
)}")
for repeat_candidate in "${repeat_candidates[@]}"; do
    [[ -n "$repeat_candidate" ]] || continue
    (( $(date +%s) < DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )) || break
    repeat_runs="$(awk -F '\t' -v id="$repeat_candidate" '$1 == id { print $2; exit }' "$CAMPAIGN_DIR/leaderboard.tsv")"
    (( ${repeat_runs:-0} >= 2 )) && continue
    CURRENT_CANDIDATE="$repeat_candidate"
    record_event candidate_repeat_scheduled "completed_runs=${repeat_runs:-0}"
    CURRENT_CANDIDATE=""
    run_candidate "$repeat_candidate" "$CAMPAIGN_MANIFEST" || true
    "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
done

# Combinations are deliberately evaluated only after independent repeats.
for combination_candidate in "${COMBINATION_QUEUE[@]}"; do
    (( $(date +%s) < DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )) || break
    if awk -F '\t' -v id="$combination_candidate" '$1 == id && $6 + 0 > 0 { found=1 } END { exit !found }' \
            "$CAMPAIGN_DIR/leaderboard.tsv"; then
        CURRENT_CANDIDATE="$combination_candidate"
        record_event combination_resume_skipped "successful result already exists"
        CURRENT_CANDIDATE=""
        continue
    fi
    prerequisite="$(combination_prerequisite "$combination_candidate")"
    if ! candidate_is_eligible submit; then
        CURRENT_CANDIDATE="$combination_candidate"
        record_event candidate_skipped "submit-thread not independently eligible after repeats"
        CURRENT_CANDIDATE=""
    elif [[ -n "$prerequisite" ]] && ! candidate_is_eligible "$prerequisite"; then
        CURRENT_CANDIDATE="$combination_candidate"
        record_event candidate_skipped "prerequisite $prerequisite not eligible after repeats"
        CURRENT_CANDIDATE=""
    else
        run_candidate "$combination_candidate" "$CAMPAIGN_MANIFEST" || true
        "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
    fi
done

champion="$(champion_candidate || true)"
selected_candidate="$champion"
resolution_selected=0

# Below 55 FPS in the heavy scene, capture a short symbol-only guest profile
# plus a host QEMU sample on the current winner. It contains no game log or
# screen text and is accepted only between the same 1-8 combat gates.
if [[ -n "$champion" && $(date +%s) -lt $(( DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )) ]] \
        && ! grep -Fq '"event":"profiling_scheduled"' "$EVENTS" 2>/dev/null; then
    champion_score="$(awk -F '\t' -v id="$champion" '$1 == id { print $6; exit }' "$CAMPAIGN_DIR/leaderboard.tsv")"
    if [[ -n "$champion_score" ]] \
            && awk -v score="$champion_score" 'BEGIN { exit !(score < 55) }'; then
        profile_candidate="profile-$champion"
        add_derived_candidate "$champion" "$profile_candidate" 2560x1440 416 '["1-5", "1-8"]'
        # Profile the first heavy fixed scene. Its combat window is long
        # enough for a bounded 4-second guest/host sample after pacing capture;
        # 1-8 can transition before the post-profile semantic screenshot.
        set_candidate_extras "$profile_candidate" 1-5 0
        record_event profiling_scheduled "candidate=$profile_candidate heavy_score=$champion_score"
        run_candidate "$profile_candidate" "$CAMPAIGN_MANIFEST" || true
        "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
    fi
elif [[ -n "$champion" ]]; then
    record_event profiling_resume_skipped \
        "profiling was already attempted; resume continues with resolution"
fi

if [[ -n "$champion" && $(date +%s) -lt $(( DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )) ]] \
        && ! grep -Fq '"event":"resolution_sweep_stopped"' "$EVENTS" 2>/dev/null; then
    record_event champion_selected "$champion"
    add_derived_candidate "$champion" champion-2880 2880x1620 468 '["1-5", "1-8"]'
    add_derived_candidate "$champion" champion-3200 3200x1800 520 '["1-5", "1-8"]'
    add_derived_candidate "$champion" champion-3840 3840x2160 624 '["1-5", "1-8"]'
    for resolution_candidate in champion-2880 champion-3200 champion-3840; do
        (( $(date +%s) < DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )) || break
        if ! run_candidate "$resolution_candidate" "$CAMPAIGN_MANIFEST"; then
            record_event resolution_sweep_stopped "$resolution_candidate failed"
            break
        fi
        "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
        if ! resolution_is_acceptable "$resolution_candidate" "$champion"; then
            record_event resolution_sweep_stopped "$resolution_candidate below acceptance threshold"
            break
        fi
        selected_candidate="$resolution_candidate"
        resolution_selected=1
        record_event resolution_accepted "$resolution_candidate"
    done
elif [[ -n "$champion" ]]; then
    record_event resolution_resume_skipped \
        "resolution sweep was already attempted; resume keeps 2560x1440"
fi

# High Power is attempted only when sudo is already non-interactive. The
# original power mode is restored by the EXIT trap regardless of A/B outcome.
if [[ -n "$champion" && $(date +%s) -lt $(( DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )) ]] \
        && /usr/bin/sudo -n true >/dev/null 2>&1; then
    add_derived_candidate "$champion" champion-high-power 2560x1440 416 '["1-5", "1-8"]'
    if /usr/bin/sudo -n /usr/bin/pmset -a powermode 2 >/dev/null 2>&1; then
        POWER_MODE_CHANGED=1
        record_event power_mode_high_power enabled
        run_candidate champion-high-power "$CAMPAIGN_MANIFEST" || true
        restore_power_mode
        "$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true
        if (( resolution_selected == 0 )) \
                && candidate_improves_baseline champion-high-power "$champion"; then
            selected_candidate=champion-high-power
            record_event power_mode_winner champion-high-power
        fi
    fi
else
    record_event power_mode_ab_skipped "non-interactive sudo unavailable or no time/champion"
fi

"$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true

# A 30-minute single-boot run keeps fighting after the measured early gates.
# It validates late effects, memory snapshots, thermal state and accumulated
# pacing before the cold A/B/A confirmation.
if [[ -n "$selected_candidate" && $(date +%s) -lt $(( DEADLINE_EPOCH - FINAL_RESERVE_SECONDS )) ]]; then
    sustained_candidate="sustained-$selected_candidate"
    selected_display="$("$JQ" -r --arg id "$selected_candidate" '.candidates[] | select(.id == $id) | .display' "$CAMPAIGN_MANIFEST")"
    selected_density="$("$JQ" -r --arg id "$selected_candidate" '.candidates[] | select(.id == $id) | .density' "$CAMPAIGN_MANIFEST")"
    add_derived_candidate "$selected_candidate" "$sustained_candidate" \
        "$selected_display" "$selected_density" '["1-2", "1-5", "1-8", "1-10", "2-1"]'
    set_candidate_extras "$sustained_candidate" "" 1800
    record_event sustained_scheduled "$sustained_candidate minimum=1800s"
    run_candidate "$sustained_candidate" "$CAMPAIGN_MANIFEST" || true
fi

for final_candidate in "$selected_candidate" control "$selected_candidate"; do
    [[ -n "$final_candidate" ]] || continue
    (( $(date +%s) < DEADLINE_EPOCH - 600 )) || break
    run_candidate "$final_candidate" "$CAMPAIGN_MANIFEST" || true
done

CURRENT_CANDIDATE=""
write_checkpoint running final_cleanup "validating final state"
restore_power_mode
"$LEADERBOARD_BUILDER" "$CAMPAIGN_DIR" >/dev/null 2>&1 || true

if "$ADB" -P "$ADB_SERVER_PORT" -s "$SERIAL" get-state >/dev/null 2>&1; then
    print "Final check failed: emulator $SERIAL is still running."
    exit 4
fi
typeset AVD_DIR="${TFT_ROOT_AVD_HOME:-$(tft_resolve_avd_home)}/${TFT_AVD_NAME:-TftRootAffinity}.avd"
if [[ -e "$AVD_DIR/.mactician-avd.lock" \
        || -e "$AVD_DIR/config.ini.mactician-asg-backup" \
        || -e "$AVD_DIR/hardware-qemu.ini.mactician-asg-backup" ]]; then
    print "Final check failed: AVD rollback markers were not removed."
    exit 4
fi

write_checkpoint complete complete "final cleanup and rollback verified"
record_event campaign_complete
print "Performance campaign completed: $CAMPAIGN_DIR"
