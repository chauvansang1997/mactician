#!/bin/zsh
set -euo pipefail

unsetopt BG_NICE

readonly PROJECT_DIR="${0:A:h}"
readonly LAUNCHER_NAME="${0:t}"
readonly VERIFIED_CANDIDATE="control"
readonly VERIFIED_CAMPAIGN_ID="20260805T211959Z"

usage() {
    print "Usage: $LAUNCHER_NAME [--resolution PRESET] [--ui-scale SCALE] [--print-config]"
    print "       $LAUNCHER_NAME --list-resolutions"
    print ""
    print "PRESET: 1440p, 1620p, 1800p, or 2160p (default: 1440p)."
    print "SCALE: 1.0, 1.25, 1.5, 1.75, or 2.0 (default: 1.0)."
}

list_resolutions() {
    print "Available resolutions:"
    print "  1440p  2560x1440 @ 416 dpi  — verified default"
    print "  1620p  2880x1620 @ 468 dpi  — SurfaceView verified; battle not confirmed"
    print "  1800p  3200x1800 @ 520 dpi  — provisional: 98.2% of 1440p FPS at stage 1-8"
    print "  2160p  3840x2160 @ 624 dpi  — experimental; battle not verified"
}

typeset resolution_preset="1440p"
typeset ui_scale="1.0"
integer print_config=0

while (( $# > 0 )); do
    case "$1" in
        --resolution|-r)
            if (( $# < 2 )); then
                print "$1 requires a preset."
                usage
                exit 2
            fi
            resolution_preset="$2"
            shift 2
            ;;
        --resolution=*)
            resolution_preset="${1#*=}"
            shift
            ;;
        --ui-scale)
            if (( $# < 2 )); then
                print "$1 requires a scale."
                usage
                exit 2
            fi
            ui_scale="$2"
            shift 2
            ;;
        --ui-scale=*)
            ui_scale="${1#*=}"
            shift
            ;;
        --print-config)
            print_config=1
            shift
            ;;
        --list-resolutions)
            list_resolutions
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

typeset display_size display_density resolution_status
case "$resolution_preset" in
    1440|1440p|2560x1440)
        resolution_preset="1440p"
        display_size="2560x1440"
        display_density="416"
        resolution_status="verified"
        ;;
    1620|1620p|2880x1620)
        resolution_preset="1620p"
        display_size="2880x1620"
        display_density="468"
        resolution_status="surface-verified"
        ;;
    1800|1800p|3200x1800)
        resolution_preset="1800p"
        display_size="3200x1800"
        display_density="520"
        resolution_status="provisional"
        ;;
    2160|2160p|3840x2160)
        resolution_preset="2160p"
        display_size="3840x2160"
        display_density="624"
        resolution_status="experimental"
        ;;
    *)
        print "Unknown resolution preset: $resolution_preset"
        list_resolutions
        exit 2
        ;;
esac
readonly RESOLUTION_PRESET="$resolution_preset"
readonly RESOLUTION_STATUS="$resolution_status"
case "$ui_scale" in
    1|1.0|1.00)
        ui_scale="1.0"
        ;;
    1.25)
        ;;
    1.5|1.50)
        ui_scale="1.5"
        ;;
    1.75)
        ;;
    2|2.0|2.00)
        ui_scale="2.0"
        ;;
    *)
        print "Unknown UI scale: $ui_scale (allowed: 1.0, 1.25, 1.5, 1.75, or 2.0)."
        exit 2
        ;;
esac
readonly UI_SCALE="$ui_scale"

# No experimental candidate passed the required cold confirmation. Clear every
# known experiment override first: this entrypoint always means the stable
# renderer/runtime stack even when its display preset is explicitly changed.
unset TFT_ANGLE_DISABLED_FEATURES TFT_ANGLE_EXTRA_FEATURES
unset TFT_ANGLE_OPENGL_PROFILE TFT_ANGLE_OPENGL_PROFILE_SHA256
unset TFT_ANGLE_OPENGL_APK TFT_ANGLE_OPENGL_APK_SHA256
unset TFT_UNREAL_LIB_OVERLAY TFT_UNREAL_LIB_OVERLAY_SHA256
unset TFT_GL_DRAW_FLUSH_INTERVAL TFT_ASG_WRITE_BUFFER_SIZE
unset TFT_ASG_WRITE_STEP_SIZE TFT_ASG_DATA_RING_SIZE
unset MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS

export TFT_ADB_SERVER_PORT=5038
source "$PROJECT_DIR/scripts/android-environment.sh"
TFT_ROOT_SDK="$(tft_resolve_android_sdk_root)"
export TFT_ROOT_SDK
TFT_ADB="$(tft_resolve_adb)"
export TFT_ADB
TFT_ROOT_AVD_HOME="${TFT_ROOT_AVD_HOME:-$(tft_resolve_avd_home)}"
export TFT_ROOT_AVD_HOME
export TFT_AVD_HOME="$TFT_ROOT_AVD_HOME"
export TFT_AVD_NAME=TftRootAffinity
export TFT_SERIAL=emulator-5582
export TFT_EMULATOR_PORT=5582
TFT_EMULATOR="$(tft_resolve_emulator)"
export TFT_EMULATOR
export TFT_LAUNCHER="$PROJECT_DIR/run-tft-angle-opengl.command"
export TFT_GLTRANSPORT=virtio-gpu-asg
export TFT_EXPECTED_GLTRANSPORT_BASELINE=pipe
export TFT_RENDERER=angle-opengl
export TFT_GUEST_GL_DRIVER=angle
export TFT_GRAPHICS_PROFILE=osft
export TFT_GUEST_SUBMIT_THREAD=on-demand
export TFT_VULKAN_BATCHED_DESCRIPTORS=0
export TFT_MVK_QUEUE_MODE=async
export MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=64
export MVK_CONFIG_FAST_MATH_ENABLED=1
export TFT_MACOS_GAME_MODE=0
export TFT_VIRTIO_GPU_NATIVE_SYNC=0
export TFT_VIRTIO_GPU_NEXT=0
export TFT_HWUI_RENDERER=skiagl
export TFT_DISPLAY_SIZE="$display_size"
export TFT_DISPLAY_DENSITY="$display_density"
export TFT_UI_SCALE="$UI_SCALE"
export TFT_PERFORMANCE_MODE=0
export TFT_CPU_CORES=7
export TFT_MEMORY_MB=8960
export TFT_AUDIO_ENABLED=1
export TFT_INPUT_BRIDGE_ENABLED=1

print "TFT best verified: $VERIFIED_CANDIDATE, Emulator 37.1.11, ASG, ANGLE/OpenGL, MoltenVK-64."
print "Display preset: ${RESOLUTION_PRESET} (${RESOLUTION_STATUS}), ${TFT_DISPLAY_SIZE}@${TFT_DISPLAY_DENSITY}, UI ${TFT_UI_SCALE}x."
print "100% render scale, dynamic resolution off, FXAA4/aniso8."
print "Verified campaign ID: $VERIFIED_CAMPAIGN_ID (see docs/benchmarks.md)."
print "MVK128 remains available only through run-tft-mvk128-experimental.command."

if (( print_config == 1 )); then
    env | LC_ALL=C sort | grep -E \
        '^(TFT_(ADB_SERVER_PORT|AUDIO_ENABLED|AVD_NAME|CPU_CORES|DISPLAY_DENSITY|DISPLAY_SIZE|EMULATOR|GLTRANSPORT|GRAPHICS_PROFILE|GUEST_GL_DRIVER|GUEST_SUBMIT_THREAD|HWUI_RENDERER|INPUT_BRIDGE_ENABLED|LAUNCHER|MACOS_GAME_MODE|MEMORY_MB|MVK_QUEUE_MODE|PERFORMANCE_MODE|RENDERER|SERIAL|UI_SCALE|VIRTIO_GPU_NATIVE_SYNC|VIRTIO_GPU_NEXT|VULKAN_BATCHED_DESCRIPTORS)=|MVK_CONFIG_(FAST_MATH_ENABLED|MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE)=)'
    exit 0
fi

exec "$PROJECT_DIR/run-tft-fast-quality.command"
