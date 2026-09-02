#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

readonly PROJECT_DIR="${0:A:h}"
source "$PROJECT_DIR/scripts/android-environment.sh"

readonly ADB_SERVER_PORT="${TFT_ADB_SERVER_PORT:-5038}"
SDK_ROOT="$(tft_resolve_android_sdk_root)"
readonly SDK_ROOT
EMULATOR="$(tft_resolve_emulator)"
readonly EMULATOR
ADB="$(tft_resolve_adb)"
readonly ADB
readonly AVD_HOME="${TFT_ROOT_AVD_HOME:-$(tft_resolve_avd_home)}"
readonly AVD_NAME="${TFT_AVD_NAME:-TftPlay}"
readonly SERIAL="${TFT_SERIAL:-emulator-5582}"
readonly EMULATOR_PORT="${TFT_EMULATOR_PORT:-${SERIAL#emulator-}}"
readonly BOOT_TIMEOUT_SECONDS="${TFT_BOOT_TIMEOUT_SECONDS:-180}"
readonly DISPLAY_SIZE="${TFT_DISPLAY_SIZE:-1920x1080}"
readonly DISPLAY_DENSITY="${TFT_DISPLAY_DENSITY:-320}"
readonly CPU_CORES="${TFT_CPU_CORES:-6}"
readonly MEMORY_MB="${TFT_MEMORY_MB:-6144}"
readonly GAME_LANGUAGE="${TFT_GAME_LANGUAGE:-en-US}"
readonly PACKAGE="${TFT_PACKAGE:-com.riotgames.league.teamfighttacticsvn}"
readonly FALLBACK_PACKAGE="${TFT_FALLBACK_PACKAGE:-com.riotgames.league.teamfighttactics}"
readonly PACKAGED_EMULATOR_APP="$PROJECT_DIR/Mactician Game Host.app"

case "$PACKAGE" in
    com.riotgames.league.teamfighttactics|com.riotgames.league.teamfighttacticsvn) ;;
    *) print -u2 "Unsupported preferred TFT package: $PACKAGE"; exit 2 ;;
esac
case "$FALLBACK_PACKAGE" in
    com.riotgames.league.teamfighttactics|com.riotgames.league.teamfighttacticsvn) ;;
    *) print -u2 "Unsupported fallback TFT package: $FALLBACK_PACKAGE"; exit 2 ;;
esac
if [[ "$ADB_SERVER_PORT" != <-> ]] \
        || (( ADB_SERVER_PORT < 1024 || ADB_SERVER_PORT > 65534 )); then
    print -u2 "TFT_ADB_SERVER_PORT must be a TCP port from 1024 to 65534."
    exit 2
fi
if [[ "$EMULATOR_PORT" != <-> || "$SERIAL" != "emulator-$EMULATOR_PORT" ]]; then
    print -u2 "TFT_SERIAL/TFT_EMULATOR_PORT must be a matching emulator-PORT and PORT pair."
    exit 2
fi
if [[ ! -x "$EMULATOR" || ! -x "$ADB" ]]; then
    print -u2 "The Android emulator runtime is incomplete."
    exit 1
fi
if [[ ! -f "$AVD_HOME/$AVD_NAME.ini" ]]; then
    print -u2 "The Google Play AVD was not found: $AVD_HOME/$AVD_NAME.ini"
    exit 1
fi

unset ADB_SERVER_SOCKET ANDROID_ADB_SERVER_ADDRESS
export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_AVD_HOME="$AVD_HOME"
export ANDROID_ADB_SERVER_PORT="$ADB_SERVER_PORT"
export ADB_MDNS_AUTO_CONNECT=""
"$ADB" -P "$ADB_SERVER_PORT" start-server >/dev/null

if "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
    print -u2 "$AVD_NAME is already running on $SERIAL."
    exit 1
fi

typeset -a emulator_arguments
emulator_arguments=(
    "@$AVD_NAME"
    -id "TFT-$AVD_NAME"
    -port "$EMULATOR_PORT"
    -gpu host
    -skin "$DISPLAY_SIZE"
    -vsync-rate 60
    -dns-server 1.1.1.1,8.8.8.8
    -cores "$CPU_CORES"
    -memory "$MEMORY_MB"
    -no-snapshot
    -no-metrics
    -no-boot-anim
    -crash-report-mode disabled
)

if [[ -x "$PACKAGED_EMULATOR_APP/Contents/MacOS/MacticianGameHost" ]]; then
    /usr/bin/open -n -W \
        --env "ANDROID_SDK_ROOT=$SDK_ROOT" \
        --env "ANDROID_AVD_HOME=$AVD_HOME" \
        --env "ANDROID_ADB_SERVER_PORT=$ADB_SERVER_PORT" \
        --env "ADB_MDNS_AUTO_CONNECT=" \
        "$PACKAGED_EMULATOR_APP" --args "${emulator_arguments[@]}" &
else
    "$EMULATOR" "${emulator_arguments[@]}" &
fi
readonly EMULATOR_PID=$!

stop_emulator() {
    if kill -0 "$EMULATOR_PID" >/dev/null 2>&1; then
        "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
        wait "$EMULATOR_PID" >/dev/null 2>&1 || true
    fi
}
trap stop_emulator INT TERM HUP

typeset -i waited=0
until "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 \
        && [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    if ! kill -0 "$EMULATOR_PID" >/dev/null 2>&1; then
        print -u2 "The emulator exited before Android finished booting."
        wait "$EMULATOR_PID" || true
        exit 1
    fi
    if (( waited >= BOOT_TIMEOUT_SECONDS )); then
        print -u2 "Android did not finish booting within ${BOOT_TIMEOUT_SECONDS} seconds."
        stop_emulator
        exit 1
    fi
    sleep 1
    (( waited += 1 ))
done

"$ADB" -s "$SERIAL" shell wm size "$DISPLAY_SIZE" >/dev/null
"$ADB" -s "$SERIAL" shell wm density "$DISPLAY_DENSITY" >/dev/null

typeset launch_package=""
typeset candidate
typeset candidate_paths
for candidate in "$PACKAGE" "$FALLBACK_PACKAGE"; do
    "$ADB" -s "$SERIAL" shell cmd locale set-app-locales \
        "$candidate" "$GAME_LANGUAGE" >/dev/null 2>&1 || true
    if [[ -z "$launch_package" ]]; then
        candidate_paths="$("$ADB" -s "$SERIAL" shell pm path "$candidate" 2>/dev/null | tr -d '\r' || true)"
        if [[ "$candidate_paths" == package:* ]]; then
            launch_package="$candidate"
        fi
    fi
done

if [[ -n "$launch_package" ]]; then
    "$ADB" -s "$SERIAL" shell am start -n \
        "$launch_package/com.epicgames.unreal.SplashActivity" >/dev/null
    print "Started $launch_package from the persistent Google Play device."
else
    "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    print "Android is ready. Install TFT from Google Play; the device will remain open."
fi

wait "$EMULATOR_PID"
