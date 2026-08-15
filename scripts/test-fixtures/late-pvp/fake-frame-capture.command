#!/bin/zsh
set -euo pipefail

readonly stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
readonly output_dir="${TFT_MEASUREMENT_ROOT:?}/${stamp}__${TFT_SCENE:?}__${TFT_VARIANT:?}"
print frame-capture >> "${TFT_FAKE_ADB_LOG:?}"
mkdir -p "$output_dir"
jq -n \
    --arg stage "${TFT_EXPECTED_STAGE:?}" \
    --arg profile_sha256 "$(shasum -a 256 "${TFT_PROFILE_PATH:?}" | awk '{ print $1 }')" \
    '{
        schema_version: 1,
        semantic_gate: {stage_before: $stage, valid: true},
        device: {version_name: "18.1.5300314", display: "Physical size: 2560x1440",
            density: "Physical density: 416"},
        graphics: {renderer: "angle-opengl", guest_gl_driver: "angle",
            active_apk_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            profile_sha256: $profile_sha256},
        host: {stable: true, power_source: "AC Power", power_mode: "Automatic",
            thermal_state: "nominal"},
        pacing: {
            fps: 24.5,
            p95_ms: 48.0,
            p99_ms: 62.0,
            frames_over_ms: {"50": 3}
        }
    }' > "$output_dir/summary.json"
