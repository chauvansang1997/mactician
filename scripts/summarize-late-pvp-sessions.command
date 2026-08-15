#!/bin/zsh
set -euo pipefail

unsetopt BG_NICE

readonly PROJECT_DIR="${0:A:h:h}"
readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"

if (( $# < 3 || $# > 4 )); then
    print -u2 "Usage: ${0:t} SESSION_ROOT CONTROL_VARIANT CANDIDATE_VARIANT [OUTPUT.json]"
    exit 2
fi

readonly SESSION_ROOT="${1:A}"
readonly CONTROL_VARIANT="$2"
readonly CANDIDATE_VARIANT="$3"
readonly OUTPUT_PATH="${4:-}"

if [[ ! -d "$SESSION_ROOT" ]]; then
    print -u2 "Late-PvP session root does not exist: $SESSION_ROOT"
    exit 2
fi
if [[ ! -x "$JQ" ]]; then
    print -u2 "jq is required to summarize late-PvP sessions."
    exit 1
fi
if [[ "$CONTROL_VARIANT" == "$CANDIDATE_VARIANT" ]]; then
    print -u2 "Control and candidate variants must be different."
    exit 2
fi
for variant_name in "$CONTROL_VARIANT" "$CANDIDATE_VARIANT"; do
    if ! print -r -- "$variant_name" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
        print -u2 "Variant names must match [a-z0-9][a-z0-9_-]*."
        exit 2
    fi
done

readonly WORK_DIR="$(mktemp -d -t mactician-late-pvp-summary)"
readonly CAPTURES_JSONL="$WORK_DIR/captures.jsonl"
readonly SOURCES_JSONL="$WORK_DIR/sources.jsonl"
cleanup() {
    local exit_code=$?
    rm -rf "$WORK_DIR"
    return "$exit_code"
}
trap cleanup EXIT
: > "$CAPTURES_JSONL"
: > "$SOURCES_JSONL"

integer SCANNED_SESSIONS=0
integer ELIGIBLE_SESSIONS=0
integer INVALID_SESSIONS=0

typeset summary_path session_dir manifest_path manifest_variant manifest_profile_sha session_id
typeset summary_sha manifest_sha capture_lines
while IFS= read -r summary_path; do
    (( SCANNED_SESSIONS += 1 ))
    session_dir="${summary_path:h}"
    manifest_path="$session_dir/manifest.json"
    session_id="${session_dir:t}"
    if [[ ! -f "$manifest_path" ]] \
            || ! "$JQ" -e '
                .schema_version == 1
                and .mode == "passive_late_pvp"
                and (.capture.profile_sha256 | type == "string"
                    and test("^[0-9a-f]{64}$"))
                and .capture.active_profile_attestation.passed == true
                and (.capture.active_profile_attestation.process_pid
                    | type == "number" and floor == . and . > 0)
                and (.capture.active_profile_attestation.mount_count
                    | type == "number" and floor == . and . == 1)
                and .capture.active_profile_attestation.sha256
                    == .capture.profile_sha256
              ' \
                "$manifest_path" >/dev/null 2>&1 \
            || ! "$JQ" -e '.schema_version == 1 and (.captures | type == "array")' \
                "$summary_path" >/dev/null 2>&1; then
        (( INVALID_SESSIONS += 1 ))
        continue
    fi

    manifest_variant="$("$JQ" -r '.capture.variant // empty' "$manifest_path")"
    manifest_profile_sha="$("$JQ" -r '.capture.profile_sha256' "$manifest_path")"
    if [[ "$manifest_variant" != "$CONTROL_VARIANT" \
            && "$manifest_variant" != "$CANDIDATE_VARIANT" ]]; then
        continue
    fi
    if ! "$JQ" -e --arg profile_sha256 "$manifest_profile_sha" '
            all(.captures[]?; .graphics.profile_sha256 == $profile_sha256)
          ' "$summary_path" >/dev/null; then
        (( INVALID_SESSIONS += 1 ))
        continue
    fi

    summary_sha="$(shasum -a 256 "$summary_path" | awk '{ print $1 }')"
    manifest_sha="$(shasum -a 256 "$manifest_path" | awk '{ print $1 }')"
    "$JQ" -nc \
        --arg id "$session_id" \
        --arg variant "$manifest_variant" \
        --arg summary_sha256 "$summary_sha" \
        --arg manifest_sha256 "$manifest_sha" \
        --argjson declared_accepted \
            "$("$JQ" '.accepted_captures // 0' "$summary_path")" \
        '{id: $id, variant: $variant, declared_accepted_captures: $declared_accepted,
          summary_sha256: $summary_sha256, manifest_sha256: $manifest_sha256}' \
        >> "$SOURCES_JSONL"

    capture_lines="$("$JQ" -c \
        --arg session_id "$session_id" \
        --arg manifest_variant "$manifest_variant" \
        --arg control "$CONTROL_VARIANT" \
        --arg candidate "$CANDIDATE_VARIANT" \
        '
        .captures[]?
        | {
            session_id: $session_id,
            variant: (.variant // $manifest_variant),
            stage: (.semantic_gate.stage_before // ""),
            stage_after: (.semantic_gate.stage_after // .semantic_gate.stage_before // ""),
            phase_before: (.semantic_gate.phase_before // "combat"),
            phase_after: (.semantic_gate.phase_after // .semantic_gate.phase_before // "combat"),
            semantic_valid: (.semantic_gate.valid == true),
            host_stable: (.host.stable == true),
            power_source: (.host.power_source // "unknown"),
            power_mode: (.host.power_mode // "unknown"),
            thermal_state: (.host.thermal_state // "unknown"),
            game_version: (.device.version_name // "unknown"),
            display: (.device.display // "unknown"),
            density: (.device.density // "unknown"),
            renderer: (.graphics.renderer // "unknown"),
            guest_gl_driver: (.graphics.guest_gl_driver // "unknown"),
            active_apk_sha256: (.graphics.active_apk_sha256 // "unknown"),
            profile_sha256: (.graphics.profile_sha256 // "unknown"),
            fps: .pacing.fps,
            p95_ms: .pacing.p95_ms,
            p99_ms: .pacing.p99_ms,
            frames_over_50_ms: (.pacing.frames_over_ms["50"] // 0)
        }
        | select(.variant == $control or .variant == $candidate)
        | select(.semantic_valid and .stage == .stage_after)
        | select(.host_stable)
        | select(.power_source != "unknown" and .power_mode != "unknown")
        | select(.thermal_state != "unknown" and .thermal_state != "unavailable")
        | select((.game_version | type) == "string"
            and (.game_version | length) > 0 and .game_version != "unknown")
        | select((.display | type) == "string"
            and (.display | length) > 0 and .display != "unknown")
        | select((.density | type) == "string"
            and (.density | length) > 0 and .density != "unknown")
        | select((.renderer | type) == "string"
            and (.renderer | length) > 0 and .renderer != "unknown")
        | select((.guest_gl_driver | type) == "string"
            and (.guest_gl_driver | length) > 0 and .guest_gl_driver != "unknown")
        | select((.active_apk_sha256 | type) == "string"
            and (.active_apk_sha256 | test("^[0-9a-f]{64}$")))
        | select(.phase_before == "combat" and .phase_after == "combat")
        | select((.stage | type) == "string"
            and (.stage | test("^[4-9]-(1|2|3|5|6)$")))
        | select((.fps | type) == "number" and .fps > 0)
        | select((.p95_ms | type) == "number" and .p95_ms > 0)
        | select((.p99_ms | type) == "number" and .p99_ms > 0)
        | select((.frames_over_50_ms | type) == "number" and .frames_over_50_ms >= 0)
        | .conditions = {
            stage: .stage,
            power_source: .power_source,
            power_mode: .power_mode,
            thermal_state: .thermal_state,
            game_version: .game_version,
            display: .display,
            density: .density,
            renderer: .renderer,
            guest_gl_driver: .guest_gl_driver,
            active_apk_sha256: .active_apk_sha256
        }
        | .stratum_key = ([.conditions.stage, .conditions.power_source,
            .conditions.power_mode, .conditions.thermal_state, .conditions.game_version,
            .conditions.display,
            .conditions.density, .conditions.renderer, .conditions.guest_gl_driver]
            + [.conditions.active_apk_sha256]
            | join("|"))
        | del(.semantic_valid, .host_stable, .stage_after, .phase_before, .phase_after,
            .stage, .power_source, .power_mode, .thermal_state, .game_version,
            .display, .density, .renderer, .guest_gl_driver, .active_apk_sha256)
        ' "$summary_path")"
    if [[ -n "$capture_lines" ]]; then
        print -r -- "$capture_lines" >> "$CAPTURES_JSONL"
        (( ELIGIBLE_SESSIONS += 1 ))
    fi
done < <(find "$SESSION_ROOT" -mindepth 2 -maxdepth 2 -type f \
    -name summary.json -print | LC_ALL=C sort)

if [[ ! -s "$CAPTURES_JSONL" ]]; then
    print -u2 "No valid late-PvP captures were found for $CONTROL_VARIANT or $CANDIDATE_VARIANT."
    exit 1
fi

typeset result
result="$("$JQ" -s \
    --arg control_variant "$CONTROL_VARIANT" \
    --arg candidate_variant "$CANDIDATE_VARIANT" \
    --argjson scanned_sessions "$SCANNED_SESSIONS" \
    --argjson eligible_sessions "$ELIGIBLE_SESSIONS" \
    --argjson invalid_sessions "$INVALID_SESSIONS" \
    --slurpfile sources "$SOURCES_JSONL" \
    '
    def average: if length == 0 then null else add / length end;
    def metrics:
        {
            captures: length,
            sessions: (map(.session_id) | unique | length),
            profile_sha256: (map(.profile_sha256) | unique),
            mean_fps: (map(.fps) | average),
            minimum_fps: (map(.fps) | min),
            mean_p95_ms: (map(.p95_ms) | average),
            worst_p95_ms: (map(.p95_ms) | max),
            mean_p99_ms: (map(.p99_ms) | average),
            worst_p99_ms: (map(.p99_ms) | max),
            frames_over_50_ms: (map(.frames_over_50_ms) | add)
        };
    . as $captures
    | [group_by(.stratum_key)[]
        | . as $stratum
        | ($stratum | map(select(.variant == $control_variant))) as $control
        | ($stratum | map(select(.variant == $candidate_variant))) as $candidate
        | select(($control | length) > 0 and ($candidate | length) > 0)
        | {
            stratum_key: $stratum[0].stratum_key,
            conditions: $stratum[0].conditions,
            control: ($control | metrics),
            candidate: ($candidate | metrics)
          }
        | .delta = {
            fps_percent: ((.candidate.mean_fps / .control.mean_fps - 1) * 100),
            mean_p95_percent: ((.candidate.mean_p95_ms / .control.mean_p95_ms - 1) * 100),
            mean_p99_percent: ((.candidate.mean_p99_ms / .control.mean_p99_ms - 1) * 100)
          }
      ] as $strata
    | ($strata | map(.stratum_key)) as $common_keys
    | ($strata | map(.control.captures) | add // 0) as $control_captures
    | ($strata | map(.candidate.captures) | add // 0) as $candidate_captures
    | ($captures
        | map(select(.variant == $control_variant
            and (.stratum_key as $key | $common_keys | index($key) != null))
            | .session_id)
        | unique | length) as $control_common_sessions
    | ($captures
        | map(select(.variant == $candidate_variant
            and (.stratum_key as $key | $common_keys | index($key) != null))
            | .session_id)
        | unique | length) as $candidate_common_sessions
    | ($captures
        | map(select(.variant == $control_variant
            and (.stratum_key as $key | $common_keys | index($key) != null))
            | .profile_sha256)
        | unique) as $control_profile_hashes
    | ($captures
        | map(select(.variant == $candidate_variant
            and (.stratum_key as $key | $common_keys | index($key) != null))
            | .profile_sha256)
        | unique) as $candidate_profile_hashes
    | ($captures | map(select(.variant == $control_variant) | .session_id) | unique | length)
        as $control_all_sessions
    | ($captures | map(select(.variant == $candidate_variant) | .session_id) | unique | length)
        as $candidate_all_sessions
    | {
        schema_version: 1,
        workload: "passive_late_player_combat",
        comparison: {
            control_variant: $control_variant,
            candidate_variant: $candidate_variant,
            matching: "exact_stage_round_host_graphics_game_version_and_apk",
            weighting: "equal_weight_per_common_stratum",
            uncontrolled: ["board_composition", "opponent_composition", "combat_timeline"]
        },
        input: {
            scanned_sessions: $scanned_sessions,
            sessions_with_valid_selected_captures: $eligible_sessions,
            invalid_session_files: $invalid_sessions,
            control_sessions_with_any_valid_capture: $control_all_sessions,
            candidate_sessions_with_any_valid_capture: $candidate_all_sessions,
            sources: ($sources | sort_by(.id))
        },
        common_strata: $strata,
        aggregate: (if ($strata | length) == 0 then null else {
            common_strata: ($strata | length),
            control_captures: $control_captures,
            candidate_captures: $candidate_captures,
            control_sessions: $control_common_sessions,
            candidate_sessions: $candidate_common_sessions,
            control_profile_sha256: $control_profile_hashes,
            candidate_profile_sha256: $candidate_profile_hashes,
            control: {
                mean_fps: ($strata | map(.control.mean_fps) | average),
                mean_p95_ms: ($strata | map(.control.mean_p95_ms) | average),
                mean_p99_ms: ($strata | map(.control.mean_p99_ms) | average)
            },
            candidate: {
                mean_fps: ($strata | map(.candidate.mean_fps) | average),
                mean_p95_ms: ($strata | map(.candidate.mean_p95_ms) | average),
                mean_p99_ms: ($strata | map(.candidate.mean_p99_ms) | average)
            }
        } | .delta = {
            fps_percent: ((.candidate.mean_fps / .control.mean_fps - 1) * 100),
            mean_p95_percent: ((.candidate.mean_p95_ms / .control.mean_p95_ms - 1) * 100),
            mean_p99_percent: ((.candidate.mean_p99_ms / .control.mean_p99_ms - 1) * 100)
        } end),
        decision: {
            minimum_common_strata: 2,
            minimum_sessions_per_variant: 2,
            minimum_fps_gain_percent: 3,
            maximum_mean_p95_regression_percent: 0,
            maximum_mean_p99_regression_percent: 3,
            common_strata_gate: (($strata | length) >= 2),
            control_session_gate: ($control_common_sessions >= 2),
            candidate_session_gate: ($candidate_common_sessions >= 2),
            control_profile_consistency_gate: (
                ($control_profile_hashes | length) == 1
                and $control_profile_hashes[0] != "unknown"),
            candidate_profile_consistency_gate: (
                ($candidate_profile_hashes | length) == 1
                and $candidate_profile_hashes[0] != "unknown"),
            distinct_profile_gate: (
                ($control_profile_hashes | length) == 1
                and ($candidate_profile_hashes | length) == 1
                and $control_profile_hashes[0] != $candidate_profile_hashes[0]),
            fps_gate: (($strata | length) > 0 and
                ((($strata | map(.candidate.mean_fps) | average) /
                  ($strata | map(.control.mean_fps) | average) - 1) * 100) >= 3),
            p95_gate: (($strata | length) > 0 and
                ($strata | map(.candidate.mean_p95_ms) | average) <=
                ($strata | map(.control.mean_p95_ms) | average)),
            p99_gate: (($strata | length) > 0 and
                ($strata | map(.candidate.mean_p99_ms) | average) <=
                (($strata | map(.control.mean_p99_ms) | average) * 1.03)),
            visual_fidelity_gate: "not_measured"
        }
      }
    | .decision.late_pvp_screen_passed = (
        .decision.common_strata_gate
        and .decision.control_session_gate
        and .decision.candidate_session_gate
        and .decision.control_profile_consistency_gate
        and .decision.candidate_profile_consistency_gate
        and .decision.distinct_profile_gate
        and .decision.fps_gate
        and .decision.p95_gate
        and .decision.p99_gate)
    | .decision.promotion_eligible = false
    | .decision.promotion_note = (if .decision.late_pvp_screen_passed then
        "Performance screen passed; cold confirmation and visual-fidelity review remain required."
      else
        "Performance screen did not pass or does not yet have enough matched evidence."
      end)
    ' "$CAPTURES_JSONL")"

if [[ -n "$OUTPUT_PATH" ]]; then
    mkdir -p "${OUTPUT_PATH:A:h}"
    print -r -- "$result" > "$OUTPUT_PATH"
    print "Late-PvP comparison: $OUTPUT_PATH"
else
    print -r -- "$result"
fi
