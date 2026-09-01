#!/bin/zsh
set -euo pipefail

readonly SOURCE_IPA="${1:-}"
readonly AUTH_BOOTSTRAP="${TFT_AUTH_BOOTSTRAP:-0}"
readonly PLAYCOVER_APP="/Applications/PlayCover.app"
readonly PLAYCOVER_BUNDLE_ID="io.playcover.PlayCover"
readonly PLAYTOOLS_FRAMEWORK="$HOME/Library/Frameworks/PlayTools.framework"
readonly BUNDLE_ID="com.riotgames.league.teamfighttactics"
readonly EXPECTED_BUILD="18.1.5392842"
readonly EXPECTED_BINARY_SHA="e683ca41528516c070ebed5a43ebc2fe47227ce5d2770ce6912d56bd18b082ab"
readonly PATCHED_BINARY_SHA="0b87b78e64120ce9d8528c74e7cf3d729d5427c86116325d1dc043c9cdd91928"
readonly MARKETPLACE_PATCH_OFFSET=$(( 0x748344 ))
readonly MARKETPLACE_EXPECTED_BYTES="60040036"
readonly MARKETPLACE_PATCHED_BYTES="23000014"
readonly SCRIPT_DIR="${0:A:h}"
readonly COMPATIBILITY_SOURCE="$SCRIPT_DIR/TFTCompatibility.m"
readonly COMPATIBILITY_LOAD_PATH="@executable_path/Frameworks/TFTCompatibility.dylib"
readonly PLAYTOOLS_LINK_PATH="@loader_path/PlayTools.framework/PlayTools"
readonly BUNDLED_PLAYTOOLS_LOAD_PATH="@rpath/PlayTools.framework/PlayTools"
readonly PLAYTOOLS_SWIZZLE_LOADER_OFFSET=$(( 0x9578 ))
readonly PLAYTOOLS_SWIZZLE_LOADER_BYTES="e923bb6d"
readonly PLAYTOOLS_RETURN_BYTES="c0035fd6"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -z "$SOURCE_IPA" || ! -f "$SOURCE_IPA" ]]; then
    print -u2 "Usage: ${0:t} /path/to/TFT.ipa [patched.ipa]"
    print -u2 "One-time sign-in: TFT_AUTH_BOOTSTRAP=1 ${0:t} /path/to/TFT.ipa"
    exit 1
fi
if [[ "$AUTH_BOOTSTRAP" != "0" && "$AUTH_BOOTSTRAP" != "1" ]]; then
    print -u2 "TFT_AUTH_BOOTSTRAP must be 0 or 1."
    exit 1
fi
if [[ ! -d "$PLAYCOVER_APP" ]]; then
    print -u2 "PlayCover is not installed in /Applications."
    exit 1
fi
if [[ ! -f "$PLAYTOOLS_FRAMEWORK/PlayTools" ]]; then
    print -u2 "PlayCover's PlayTools framework is not installed."
    exit 1
fi
if [[ ! -f "$COMPATIBILITY_SOURCE" ]]; then
    print -u2 "Missing compatibility source: $COMPATIBILITY_SOURCE"
    exit 1
fi

readonly SOURCE_DIR="${SOURCE_IPA:A:h}"
readonly SOURCE_NAME="${SOURCE_IPA:A:t:r}"
readonly OUTPUT_IPA="${2:-$SOURCE_DIR/$SOURCE_NAME-mactician.ipa}"
readonly NEXT_IPA="$OUTPUT_IPA.next.$$"
readonly BUILD_ROOT="$(mktemp -d /tmp/tft-ios-playcover.XXXXXX)"
readonly COMPILED_COMPATIBILITY="$BUILD_ROOT/TFTCompatibility.dylib"
readonly INSTALLED_ENTITLEMENTS="$BUILD_ROOT/PlayCover-entitlements.plist"
cleanup() {
    /bin/rm -rf -- "$BUILD_ROOT"
    [[ ! -e "$NEXT_IPA" ]] || /bin/rm -f -- "$NEXT_IPA"
}
trap cleanup EXIT

/usr/bin/xcrun --sdk macosx clang \
    -target arm64-apple-ios14.0-macabi \
    -fobjc-arc -dynamiclib "$COMPATIBILITY_SOURCE" \
    -o "$COMPILED_COMPATIBILITY" \
    -framework Foundation -framework CoreGraphics \
    -F "$HOME/Library/Frameworks" -Wl,-needed_framework,PlayTools \
    -install_name '@rpath/TFTCompatibility.dylib'
/usr/bin/install_name_tool -change '@rpath/PlayTools.framework/PlayTools' \
    "$PLAYTOOLS_LINK_PATH" "$COMPILED_COMPATIBILITY"
/usr/bin/codesign --force --sign - "$COMPILED_COMPATIBILITY"

/usr/bin/ditto -x -k "$SOURCE_IPA" "$BUILD_ROOT"
readonly APP_PATH="$(find "$BUILD_ROOT/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" || ! -f "$APP_PATH/Info.plist" ]]; then
    print -u2 "The IPA does not contain an application in Payload."
    exit 1
fi

readonly ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist")"
readonly ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP_PATH/Info.plist")"
readonly EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "$APP_PATH/Info.plist")"
readonly BINARY="$APP_PATH/$EXECUTABLE"
readonly ACTUAL_BINARY_SHA="$(shasum -a 256 "$BINARY" | awk '{ print $1 }')"
readonly ACTUAL_MARKETPLACE_BYTES="$(xxd -p -l 4 -s "$MARKETPLACE_PATCH_OFFSET" "$BINARY")"

if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" \
        || "$ACTUAL_BUILD" != "$EXPECTED_BUILD" \
        || "$ACTUAL_BINARY_SHA" != "$EXPECTED_BINARY_SHA" \
        || "$ACTUAL_MARKETPLACE_BYTES" != "$MARKETPLACE_EXPECTED_BYTES" ]]; then
    print -u2 "Unsupported TFT IPA; compatibility patches cancelled."
    print -u2 "Bundle: $ACTUAL_BUNDLE_ID, build: $ACTUAL_BUILD, SHA-256: $ACTUAL_BINARY_SHA"
    exit 1
fi

/usr/bin/printf '\043\000\000\024' \
    | /bin/dd of="$BINARY" bs=1 seek="$MARKETPLACE_PATCH_OFFSET" conv=notrunc status=none
if [[ "$(xxd -p -l 4 -s "$MARKETPLACE_PATCH_OFFSET" "$BINARY")" != "$MARKETPLACE_PATCHED_BYTES" \
        || "$(shasum -a 256 "$BINARY" | awk '{ print $1 }')" != "$PATCHED_BINARY_SHA" ]]; then
    print -u2 "The guarded ARM64 patch did not produce the verified binary."
    exit 1
fi

/usr/libexec/PlistBuddy -c 'Delete :UIApplicationSupportsIndirectInputEvents' \
    "$APP_PATH/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :UIApplicationSupportsIndirectInputEvents bool false' \
    "$APP_PATH/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' \
    "$APP_PATH/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Delete :LSEnvironment:DYLD_INSERT_LIBRARIES' \
    "$APP_PATH/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $COMPATIBILITY_LOAD_PATH" \
    "$APP_PATH/Info.plist"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$BUILD_ROOT/Payload" "$NEXT_IPA"
if ! unzip -tq "$NEXT_IPA" >/dev/null; then
    print -u2 "The patched IPA failed ZIP validation."
    exit 1
fi
/bin/mv -f "$NEXT_IPA" "$OUTPUT_IPA"

print "Patched TFT IPA is ready: $OUTPUT_IPA"
print "MarketplaceKit guard patched at 0x748344."

if [[ "${TFT_PLAYCOVER_PATCH_ONLY:-0}" == "1" ]]; then
    exit 0
fi

readonly INSTALLED_APP="$HOME/Library/Containers/io.playcover.PlayCover/Applications/$BUNDLE_ID.app"
readonly INSTALLED_BINARY="$INSTALLED_APP/$EXECUTABLE"
readonly INSTALLED_COMPATIBILITY="$INSTALLED_APP/Frameworks/TFTCompatibility.dylib"
readonly BUNDLED_PLAYTOOLS="$INSTALLED_APP/Frameworks/PlayTools.framework"
readonly BUNDLED_PLAYTOOLS_BINARY="$BUNDLED_PLAYTOOLS/PlayTools"
readonly AKINTERFACE="$INSTALLED_APP/PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface"
readonly STREAMING_METADATA_DB="$HOME/Library/Containers/$BUNDLE_ID/Data/Documents/TFT/PersistentDownloadDir/StreamingInstalls/Metadata.db"
readonly SAVED_APPLICATION_STATE="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Saved Application State/$BUNDLE_ID~iosmac.savedState"
readonly LAUNCH_LOG="/tmp/mactician-tft-launch.log"

playtools_is_injected() {
    /usr/bin/otool -L "$1" 2>/dev/null | /usr/bin/grep -Fq '/PlayTools.framework/PlayTools'
}

installed_base_is_ready() {
    [[ -f "$INSTALLED_BINARY" \
        && "$(plutil -extract CFBundleVersion raw -o - "$INSTALLED_APP/Info.plist" 2>/dev/null)" == "$EXPECTED_BUILD" \
        && "$(xxd -p -l 4 -s "$MARKETPLACE_PATCH_OFFSET" "$INSTALLED_BINARY" 2>/dev/null)" == "$MARKETPLACE_PATCHED_BYTES" \
        && "$(plutil -extract UIApplicationSupportsIndirectInputEvents raw -o - "$INSTALLED_APP/Info.plist" 2>/dev/null)" == "false" \
        && -x "$AKINTERFACE" ]] \
        && playtools_is_injected "$INSTALLED_BINARY"
}

stop_running_game() {
    local pids
    pids="$(/usr/bin/pgrep -x "$EXECUTABLE" || true)"
    [[ -z "$pids" ]] && return 0
    /usr/bin/pkill -TERM -x "$EXECUTABLE" || true
    for _ in {1..10}; do
        /usr/bin/pgrep -x "$EXECUTABLE" >/dev/null || return 0
        /bin/sleep 1
    done
    print -u2 "TFT did not stop; installation was cancelled."
    return 1
}

checkpoint_streaming_metadata() {
    [[ -f "$STREAMING_METADATA_DB" && -s "$STREAMING_METADATA_DB-wal" ]] || return 0
    if [[ "$(/usr/bin/sqlite3 -readonly "$STREAMING_METADATA_DB" 'PRAGMA quick_check;')" != "ok" ]]; then
        print -u2 "TFT streaming metadata is corrupt; WAL repair was cancelled."
        return 1
    fi

    print "Finalizing TFT streaming metadata left by the interrupted update…"
    local checkpoint_result
    checkpoint_result="$(/usr/bin/sqlite3 -cmd '.timeout 10000' "$STREAMING_METADATA_DB" \
        'PRAGMA wal_checkpoint(TRUNCATE);')"
    if [[ "$checkpoint_result" != 0\|* \
            || "$(/usr/bin/sqlite3 -readonly "$STREAMING_METADATA_DB" 'PRAGMA quick_check;')" != "ok" ]]; then
        print -u2 "TFT streaming metadata WAL could not be finalized safely."
        return 1
    fi
}

reset_saved_application_state() {
    [[ -e "$SAVED_APPLICATION_STATE" ]] || return 0
    print "Discarding stale TFT window restoration state…"
    /bin/rm -rf -- "$SAVED_APPLICATION_STATE"
}

prepare_installed_app() {
    /usr/bin/codesign -d --entitlements :- "$INSTALLED_APP" \
        2>/dev/null > "$INSTALLED_ENTITLEMENTS"
    /usr/bin/plutil -lint "$INSTALLED_ENTITLEMENTS" >/dev/null
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
            "$INSTALLED_ENTITLEMENTS" 2>/dev/null)" != "true" ]]; then
        print -u2 "PlayCover sandbox entitlements are missing; signing was cancelled."
        return 1
    fi
    /bin/cp -f "$COMPILED_COMPATIBILITY" "$INSTALLED_COMPATIBILITY"

    # PlayTools 1.1.7 applies a display swizzle that maps UIViewController.view
    # to initWithCoder: on macOS 26. Keep the rest of PlayTools (including
    # touch emulation), but disable only that loader in an app-local copy.
    /bin/rm -rf -- "$BUNDLED_PLAYTOOLS"
    /usr/bin/ditto "$PLAYTOOLS_FRAMEWORK" "$BUNDLED_PLAYTOOLS"
    local thin_playtools="$BUNDLED_PLAYTOOLS_BINARY.next.$$"
    /usr/bin/lipo "$PLAYTOOLS_FRAMEWORK/PlayTools" -thin arm64 -output "$thin_playtools"
    /bin/mv -f "$thin_playtools" "$BUNDLED_PLAYTOOLS_BINARY"
    if [[ "$(xxd -p -l 4 -s "$PLAYTOOLS_SWIZZLE_LOADER_OFFSET" \
            "$BUNDLED_PLAYTOOLS_BINARY")" != "$PLAYTOOLS_SWIZZLE_LOADER_BYTES" ]]; then
        print -u2 "Unsupported PlayTools build; the macOS 26 fix was cancelled."
        return 1
    fi
    /usr/bin/printf '\300\003\137\326' | /bin/dd of="$BUNDLED_PLAYTOOLS_BINARY" \
        bs=1 seek="$PLAYTOOLS_SWIZZLE_LOADER_OFFSET" conv=notrunc status=none
    if [[ "$(xxd -p -l 4 -s "$PLAYTOOLS_SWIZZLE_LOADER_OFFSET" \
            "$BUNDLED_PLAYTOOLS_BINARY")" != "$PLAYTOOLS_RETURN_BYTES" ]]; then
        print -u2 "PlayTools swizzle-loader patch verification failed."
        return 1
    fi

    local current_playtools_load_path
    current_playtools_load_path="$(/usr/bin/otool -L "$INSTALLED_BINARY" \
        | /usr/bin/awk '/PlayTools\.framework\/PlayTools/{print $1; exit}')"
    if [[ -z "$current_playtools_load_path" ]]; then
        print -u2 "The PlayCover PlayTools load command is missing."
        return 1
    fi
    if [[ "$current_playtools_load_path" != "$BUNDLED_PLAYTOOLS_LOAD_PATH" ]]; then
        /usr/bin/install_name_tool -change "$current_playtools_load_path" \
            "$BUNDLED_PLAYTOOLS_LOAD_PATH" "$INSTALLED_BINARY"
    fi
    /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' \
        "$INSTALLED_APP/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Delete :LSEnvironment:DYLD_INSERT_LIBRARIES' \
        "$INSTALLED_APP/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy \
        -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $COMPATIBILITY_LOAD_PATH" \
        "$INSTALLED_APP/Info.plist"
    /usr/bin/codesign --force --sign - "$INSTALLED_COMPATIBILITY"
    /usr/bin/codesign --force --sign - "$BUNDLED_PLAYTOOLS"
    /usr/bin/codesign --force --sign - \
        --identifier "$BUNDLE_ID" --entitlements "$INSTALLED_ENTITLEMENTS" "$INSTALLED_APP"
    /usr/bin/codesign --verify --deep --strict "$INSTALLED_APP"
    "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null
}

launch_installed_app() {
    checkpoint_streaming_metadata || return 1
    stop_running_game || return 1
    reset_saved_application_state
    : > "$LAUNCH_LOG"
    if [[ "$AUTH_BOOTSTRAP" == "1" ]]; then
        print "One-time TFT authentication bootstrap enabled. Relaunch normally after sign-in."
    fi
    /usr/bin/open -n -F \
        --stdout "$LAUNCH_LOG" --stderr "$LAUNCH_LOG" \
        --env "MACTICIAN_TFT_AUTH_BOOTSTRAP=$AUTH_BOOTSTRAP" \
        "$INSTALLED_APP"

    local pid=""
    for _ in {1..15}; do
        pid="$(/usr/bin/pgrep -x "$EXECUTABLE" | /usr/bin/head -1 || true)"
        [[ -n "$pid" ]] && break
        /bin/sleep 1
    done
    [[ -n "$pid" ]] || return 1

    /bin/sleep 8
    /usr/bin/osascript -e \
        "tell application \"System Events\" to tell first application process whose unix id is $pid to set frontmost to true" \
        -e \
        "tell application \"System Events\" to tell first application process whose unix id is $pid to set position of first window to {100, 100}" \
        >/dev/null 2>&1 || true
    /bin/sleep 4
    /bin/kill -0 "$pid" 2>/dev/null
}

if installed_base_is_ready; then
    stop_running_game
    prepare_installed_app
    launch_installed_app || {
        print -u2 "The patched TFT build is installed, but it did not stay running."
        print -u2 "Launch log: $LAUNCH_LOG"
        exit 1
    }
    print "TFT $EXPECTED_BUILD launched through PlayCover."
    exit 0
fi

stop_running_game
/usr/bin/defaults write "$PLAYCOVER_BUNDLE_ID" AlwaysInstallPlayTools -bool true
/usr/bin/defaults write "$PLAYCOVER_BUNDLE_ID" ShowInstallPopup -bool false
/usr/bin/open -b "$PLAYCOVER_BUNDLE_ID" "$OUTPUT_IPA"
print "Waiting for PlayCover to install TFT $EXPECTED_BUILD with PlayTools…"

for _ in {1..180}; do
    if installed_base_is_ready; then
        prepare_installed_app
        launch_installed_app || {
            print -u2 "PlayCover installed TFT, but it did not stay running."
            print -u2 "Launch log: $LAUNCH_LOG"
            exit 1
        }
        print "TFT $EXPECTED_BUILD launched through PlayCover."
        exit 0
    fi
    /bin/sleep 1
done

print -u2 "PlayCover did not finish installation within three minutes."
print -u2 "Complete any PlayCover dialog, then run this script again."
exit 1
