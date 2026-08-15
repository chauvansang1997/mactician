#!/bin/zsh
set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"
readonly SOURCE_DIR="$PROJECT_DIR/artifacts/android-gles-ubo-stress-app"
readonly BUILD_TOOLS="${TFT_ANDROID_BUILD_TOOLS:-/private/tmp/mactician-android-build-tools-36/android-16}"
readonly PLATFORM="${TFT_ANDROID_PLATFORM:-/private/tmp/mactician-android-platform-36/android-36}"
readonly ANDROID_JAR="$PLATFORM/android.jar"
readonly OUTPUT="${1:-$PROJECT_DIR/runtime/mactician-gles-ubo-stress.apk}"
readonly KEYSTORE="${TFT_GLES_STRESS_KEYSTORE:-$PROJECT_DIR/runtime/mactician-gles-probe-debug.keystore}"
readonly BUILD_DIR="$(mktemp -d -t mactician-gles-ubo-app)"

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

for tool in "$BUILD_TOOLS/aapt2" "$BUILD_TOOLS/d8" \
        "$BUILD_TOOLS/zipalign" "$BUILD_TOOLS/apksigner" "$ANDROID_JAR"; do
    if [[ ! -e "$tool" ]]; then
        print -u2 "Android 36 build dependency is unavailable: $tool"
        exit 1
    fi
done
if ! command -v javac >/dev/null 2>&1 || ! command -v keytool >/dev/null 2>&1; then
    print -u2 "JDK javac and keytool are required to build the GLES UBO-stress app."
    exit 1
fi

mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex" "${OUTPUT:h}" "${KEYSTORE:h}"
if [[ ! -f "$KEYSTORE" ]]; then
    keytool -genkeypair -noprompt \
        -keystore "$KEYSTORE" -storepass android -keypass android \
        -alias mactician-gles-probe -keyalg RSA -keysize 2048 -validity 10000 \
        -dname 'CN=Mactician GLES Probe, OU=Local Benchmark, O=Mactician, C=IL' \
        >/dev/null 2>&1
fi

javac -Xlint:-options -source 8 -target 8 -bootclasspath "$ANDROID_JAR" \
    -d "$BUILD_DIR/classes" \
    "$SOURCE_DIR/src/dev/sergeinaumov/mactician/glesubo/UboStressActivity.java"
typeset -a CLASS_FILES
CLASS_FILES=("$BUILD_DIR"/classes/**/*.class(N))
if (( ${#CLASS_FILES} == 0 )); then
    print -u2 "javac did not produce UBO-stress benchmark classes."
    exit 1
fi
"$BUILD_TOOLS/d8" --lib "$ANDROID_JAR" --min-api 26 \
    --output "$BUILD_DIR/dex" "${CLASS_FILES[@]}"
"$BUILD_TOOLS/aapt2" link -o "$BUILD_DIR/unsigned.apk" \
    --manifest "$SOURCE_DIR/AndroidManifest.xml" -I "$ANDROID_JAR" \
    --min-sdk-version 26 --target-sdk-version 36
(
    cd "$BUILD_DIR/dex"
    zip -q -j "$BUILD_DIR/unsigned.apk" classes.dex
)
"$BUILD_TOOLS/zipalign" -f 4 "$BUILD_DIR/unsigned.apk" "$BUILD_DIR/aligned.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android \
    --key-pass pass:android --out "$OUTPUT" "$BUILD_DIR/aligned.apk"
"$BUILD_TOOLS/apksigner" verify --verbose "$OUTPUT" >/dev/null
print "$OUTPUT"
