#!/bin/zsh
set -euo pipefail

readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"
if [[ -z "$JQ" || ! -x "$JQ" ]]; then
    print -u2 "jq is required to summarize a GLES UBO campaign."
    exit 1
fi
if (( $# < 3 || $# % 2 == 0 )); then
    print -u2 "Usage: ${0:t} <control-summary> <candidate-summary> <control-summary> [...]"
    exit 2
fi
for summary_file in "$@"; do
    if [[ ! -f "$summary_file" ]] || ! "$JQ" -e '.schema_version == 1' "$summary_file" >/dev/null; then
        print -u2 "Invalid UBO summary: $summary_file"
        exit 1
    fi
done

"$JQ" -s '
    def mean: add / length;
    def percent_delta($candidate; $control):
        if $control == 0 then null else (($candidate / $control) - 1) * 100 end;
    sort_by(.utc) as $runs
    | if all(range(0; $runs | length; 2); $runs[.].mode == "single_subdata")
         and all(range(1; ($runs | length) - 1; 2); $runs[.].mode != "single_subdata")
         and ([ $runs[].probe.apk_sha256 ] | unique | length) == 1
         and ([ $runs[].probe.activity_source_sha256 ] | unique | length) == 1
         and ([ $runs[].probe.manifest_sha256 ] | unique | length) == 1
         and ([ $runs[].graphics_profile ] | unique | length) == 1
         and ([ $runs[].angle_features ] | unique | length) == 1
         and ([ $runs[].workload ] | unique | length) == 1
         and all($runs[]; .result.gl_error_rounds == 0)
      then .
      else error("campaign must alternate hash-identical control/candidate runs")
      end
    | [range(1; ($runs | length) - 1; 2) as $index
       | ($runs[$index - 1]) as $before
       | ($runs[$index]) as $candidate
       | ($runs[$index + 1]) as $after
       | (($before.result.median_ns_per_draw + $after.result.median_ns_per_draw) / 2) as $control_median
       | (($before.result.p95_ns_per_draw + $after.result.p95_ns_per_draw) / 2) as $control_p95
       | {candidate_mode: $candidate.mode,
          candidate_utc: $candidate.utc,
          control_before_utc: $before.utc,
          control_after_utc: $after.utc,
          bracketing_control_median_ns_per_draw: $control_median,
          candidate_median_ns_per_draw: $candidate.result.median_ns_per_draw,
          median_delta_percent: percent_delta($candidate.result.median_ns_per_draw; $control_median),
          bracketing_control_p95_ns_per_draw: $control_p95,
          candidate_p95_ns_per_draw: $candidate.result.p95_ns_per_draw,
          p95_delta_percent: percent_delta($candidate.result.p95_ns_per_draw; $control_p95),
          decision: (
            if (percent_delta($candidate.result.median_ns_per_draw; $control_median)) <= -5
               and (percent_delta($candidate.result.p95_ns_per_draw; $control_p95)) <= -5
            then "synthetic_faster"
            elif (percent_delta($candidate.result.median_ns_per_draw; $control_median)) >= 5
            then "synthetic_slower"
            else "synthetic_neutral_or_mixed"
            end)}
      ] as $blocks
    | {
        schema_version: 1,
        kind: "android_gles_ubo_strategy_campaign",
        generated_utc: (now | todateiso8601),
        purpose: "Rank UBO update strategies on the attested guest ANGLE to Vulkan path without TFT authentication.",
        limitations: [
          "This synthetic workload is not a TFT FPS measurement.",
          "A favorable result only prioritizes an Unreal-side candidate for matched late-PvP validation.",
          "No candidate is safe to promote until TFT visual correctness, stability, and matched combat tails are verified."
        ],
        probe: $runs[0].probe,
        runtime: {
          graphics_profile: $runs[0].graphics_profile,
          transport: $runs[0].transport,
          angle_features: $runs[0].angle_features,
          renderer: $runs[0].renderer,
          ubo_alignment: $runs[0].attestation.ubo_alignment,
          ubo_stride: $runs[0].attestation.ubo_stride
        },
        workload: $runs[0].workload,
        campaign: {
          successful_runs: ($runs | length),
          control_runs: ([$runs[] | select(.mode == "single_subdata")] | length),
          candidate_runs: ([$runs[] | select(.mode != "single_subdata")] | length),
          failed_runs: 0,
          alternating_bracket_design: true
        },
        runs: [$runs[] | {
          utc: .utc, label: .label, mode: .mode,
          median_ns_per_draw: .result.median_ns_per_draw,
          p95_ns_per_draw: .result.p95_ns_per_draw,
          median_frames_per_second: .result.median_frames_per_second,
          gl_error_rounds: .result.gl_error_rounds
        }],
        comparisons: $blocks,
        strategy_summary: [
          $blocks | group_by(.candidate_mode)[]
          | {mode: .[0].candidate_mode,
             blocks: length,
             mean_median_delta_percent: ([.[].median_delta_percent] | mean),
             mean_p95_delta_percent: ([.[].p95_delta_percent] | mean),
             decisions: ([.[].decision] | group_by(.) | map({decision: .[0], blocks: length}))}
        ]
      }
' "$@"
