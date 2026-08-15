#!/bin/zsh
set -euo pipefail

readonly STATE_FILE="${TFT_FAKE_GLES_UBO_ADB_STATE:?TFT_FAKE_GLES_UBO_ADB_STATE is required}"

if [[ "$*" == *" start-server" ]]; then exit 0; fi
if [[ "$*" == *" get-state" ]]; then print device; exit 0; fi
if [[ "$*" == *" shell getprop ro.boot.mactician.graphics_profile" ]]; then print osft; exit 0; fi
if [[ "$*" == *" shell getprop debug.angle.feature_overrides_enabled" ]]; then
    print 'exposeNonConformantExtensionsAndVersions:exposeES32ForTesting'; exit 0
fi
if [[ "$*" == *" shell getprop debug.angle.feature_overrides_disabled" ]]; then
    print preferSubmitAtFBOBoundary; exit 0
fi
if [[ "$*" == *" shell getprop ro.boot.hardware.gltransport" ]]; then print virtio-gpu-asg; exit 0; fi
if [[ "$*" == *" install -r -t "* ]]; then print Success; exit 0; fi
if [[ "$*" == *" logcat -c"* ]]; then exit 0; fi
if [[ "$*" == *" shell am start -W "* ]]; then
    typeset run_id="" mode="" rounds=0 frames=0 draws=0 warmup=0 previous="" argument
    for argument in "$@"; do
        case "$previous" in
            run_id) run_id="$argument" ;;
            mode) mode="$argument" ;;
            rounds) rounds="$argument" ;;
            frames) frames="$argument" ;;
            draws_per_frame) draws="$argument" ;;
            warmup_rounds) warmup="$argument" ;;
        esac
        previous="$argument"
    done
    if [[ -z "$run_id" || -z "$mode" || "$rounds" != <-> || "$warmup" != <-> ]]; then
        print -u2 "fake ADB could not parse UBO benchmark extras"; exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$run_id" "$mode" "$rounds" "$frames" "$draws" "$warmup" > "$STATE_FILE"
    print 'Status: ok'; print 'TotalTime: 1'; exit 0
fi
if [[ "$*" == *" logcat -d "* ]]; then
    typeset run_id mode rounds frames draws warmup
    IFS=$'\t' read -r run_id mode rounds frames draws warmup < "$STATE_FILE"
    print -r -- "{\"kind\":\"attestation\",\"run_id\":\"$run_id\",\"mode\":\"$mode\",\"renderer\":\"ANGLE (Apple, Vulkan 1.3)\",\"version\":\"OpenGL ES 3.2\",\"guest_angle_mapped\":true,\"gfxstream_gles_encoder_mapped\":true,\"ranchu_vulkan_mapped\":true,\"ubo_alignment\":256,\"ubo_stride\":256,\"ubo_bytes\":32}"
    integer round
    for (( round = 0; round < rounds; round++ )); do
        typeset is_warmup=false
        (( round < warmup )) && is_warmup=true
        print -r -- "{\"kind\":\"ubo_stress_round\",\"run_id\":\"$run_id\",\"mode\":\"$mode\",\"round\":$round,\"warmup\":$is_warmup,\"frames\":$frames,\"draws_per_frame\":$draws,\"elapsed_ns\":1000000,\"ns_per_draw\":1000.0,\"frames_per_second\":60.0,\"gl_error\":0}"
    done
    print -r -- "{\"kind\":\"ubo_stress_summary\",\"run_id\":\"$run_id\",\"mode\":\"$mode\",\"measured_rounds\":$(( rounds - warmup )),\"median_ns_per_draw\":1000.0,\"p95_ns_per_draw\":1000.0,\"median_frames_per_second\":60.0,\"gl_error_rounds\":0}"
    exit 0
fi
if [[ "$*" == *" shell am force-stop "* || "$*" == *" uninstall "* ]]; then exit 0; fi

print -u2 "unexpected fake ADB invocation: $*"
exit 1
