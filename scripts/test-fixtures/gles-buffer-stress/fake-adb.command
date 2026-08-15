#!/bin/zsh
set -euo pipefail

readonly STATE_FILE="${TFT_FAKE_GLES_ADB_STATE:?TFT_FAKE_GLES_ADB_STATE is required}"

if [[ "$*" == *" start-server" ]]; then
    exit 0
fi
if [[ "$*" == *" get-state" ]]; then
    print device
    exit 0
fi
if [[ "$*" == *" shell getprop ro.boot.mactician.graphics_profile" ]]; then
    print osft
    exit 0
fi
if [[ "$*" == *" shell getprop debug.angle.feature_overrides_enabled" ]]; then
    print 'exposeNonConformantExtensionsAndVersions:exposeES32ForTesting'
    exit 0
fi
if [[ "$*" == *" shell getprop debug.angle.feature_overrides_disabled" ]]; then
    print preferSubmitAtFBOBoundary
    exit 0
fi
if [[ "$*" == *" shell getprop ro.boot.hardware.gltransport" ]]; then
    print virtio-gpu-asg
    exit 0
fi
if [[ "$*" == *" install -r -t "* ]]; then
    print Success
    exit 0
fi
if [[ "$*" == *" shell am start -W "* ]]; then
    typeset run_id="" rounds=0 updates=0 bytes=0 sync_every=0 barrier_every=0 warmup_rounds=0
    typeset previous=""
    typeset argument
    for argument in "$@"; do
        case "$previous" in
            run_id) run_id="$argument" ;;
            rounds) rounds="$argument" ;;
            updates) updates="$argument" ;;
            bytes) bytes="$argument" ;;
            sync_every) sync_every="$argument" ;;
            barrier_every) barrier_every="$argument" ;;
            warmup_rounds) warmup_rounds="$argument" ;;
        esac
        previous="$argument"
    done
    if [[ -z "$run_id" || "$rounds" != <-> || "$warmup_rounds" != <-> ]]; then
        print -u2 "fake ADB could not parse benchmark extras"
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$run_id" "$rounds" "$updates" "$bytes" "$sync_every" \
        "$barrier_every" "$warmup_rounds" > "$STATE_FILE"
    print 'Status: ok'
    print 'TotalTime: 1'
    exit 0
fi
if [[ "$*" == *" logcat -d "* ]]; then
    typeset run_id rounds updates bytes sync_every barrier_every warmup_rounds
    IFS=$'\t' read -r run_id rounds updates bytes sync_every barrier_every warmup_rounds \
        < "$STATE_FILE"
    print -r -- "{\"kind\":\"attestation\",\"run_id\":\"$run_id\",\"renderer\":\"ANGLE (Apple, Vulkan 1.3)\",\"version\":\"OpenGL ES 3.2\",\"guest_angle_mapped\":true,\"gfxstream_gles_encoder_mapped\":false,\"ranchu_vulkan_mapped\":true}"
    integer round
    for (( round = 0; round < rounds; round++ )); do
        typeset warmup=false
        (( round < warmup_rounds )) && warmup=true
        print -r -- "{\"kind\":\"buffer_stress_round\",\"run_id\":\"$run_id\",\"round\":$round,\"warmup\":$warmup,\"updates\":$updates,\"bytes\":$bytes,\"sync_every\":$sync_every,\"barrier_every\":$barrier_every,\"elapsed_ns\":1000000,\"ns_per_update\":1000.0,\"mib_per_second\":15625.0,\"gl_error\":0}"
    done
    print -r -- "{\"kind\":\"buffer_stress_summary\",\"run_id\":\"$run_id\",\"measured_rounds\":$(( rounds - warmup_rounds )),\"median_ns_per_update\":1000.0,\"p95_ns_per_update\":1000.0,\"median_mib_per_second\":15625.0,\"gl_error_rounds\":0}"
    exit 0
fi
if [[ "$*" == *" shell am force-stop "* || "$*" == *" uninstall "* ]]; then
    exit 0
fi

print -u2 "unexpected fake ADB invocation: $*"
exit 1
