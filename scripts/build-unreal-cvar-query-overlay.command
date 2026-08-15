#!/bin/zsh
set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"
readonly SOURCE_APK="${1:-$PROJECT_DIR/runtime/base-angle-opengl-current-en.apk}"
readonly EXPECTED_SOURCE_SHA256="${2:-}"
readonly OUTPUT="${3:-$PROJECT_DIR/runtime/base-angle-opengl-cvar-query.apk}"
readonly WORK_DIR="$(mktemp -d -t mactician-cvar-query-overlay)"
readonly COMMAND_LINE_PATH="assets/UECommandLine.txt"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE_APK" || ! "$EXPECTED_SOURCE_SHA256" =~ '^[0-9a-f]{64}$' ]]; then
    print -u2 "Usage: ${0:t} SOURCE_APK EXPECTED_SHA256 [OUTPUT_APK]"
    exit 2
fi
readonly ACTUAL_SOURCE_SHA256="$(shasum -a 256 "$SOURCE_APK" | awk '{ print $1 }')"
if [[ "$ACTUAL_SOURCE_SHA256" != "$EXPECTED_SOURCE_SHA256" ]]; then
    print -u2 "The source overlay SHA-256 does not match the expected value."
    exit 1
fi

readonly ORIGINAL_COMMAND_LINE="$(unzip -p "$SOURCE_APK" "$COMMAND_LINE_PATH")"
if [[ "$ORIGINAL_COMMAND_LINE" != *'-project="../../../TFT/TFT.uproject"'* \
        || "$ORIGINAL_COMMAND_LINE" != *' -opengl '* \
        || "$ORIGINAL_COMMAND_LINE" == *'-ExecCmds='* ]]; then
    print -u2 "The source overlay has an unexpected Unreal command line."
    exit 1
fi

typeset -a QUERY_NAMES
QUERY_NAMES=(
    r.RHICmdBypass
    r.RHIThread.Enable
    r.OpenGL.AllowRHIThread
    r.RHICmd.ParallelTranslate.Enable
    r.RHICmdBufferWriteLocks
    r.UniformBufferPooling
    OpenGL.UBOPoolSize
    OpenGL.UBODirectWrite
    r.RenderCommandPipe.NiagaraDynamicData
    r.RenderCommandPipe.SkeletalMesh
    fx.Budget.Enabled
    fx.Budget.GameThread
    fx.Budget.GameThreadConcurrent
    fx.Budget.RenderThread
    fx.Niagara.UseGlobalFXBudget
    fx.Niagara.Scalability.GlobalBudgetCulling
    tft.Tick.RelevancyEnabled
    FX.AllowAsyncTick
    FX.BatchAsync
    FX.EarlyScheduleAsync
    fx.Niagara.SystemSimulation.AllowASync
    fx.Niagara.SystemSimulation.BatchGPUTickSubmit
    fx.Niagara.SystemSimulation.TickBatchMode
    a.ParallelAnimEvaluation
    a.ParallelAnimUpdate
    a.ForceParallelAnimUpdate
    a.URO.Enable
    r.AllowOcclusionQueries
    r.HZBOcclusion
    r.OpenGL.AllowPSOPrecaching
    Android.OpenGL.NumRemoteProgramCompileServices
    DumpCVars
)
for query_name in "${QUERY_NAMES[@]}"; do
    if [[ ! "$query_name" =~ '^[A-Za-z][A-Za-z0-9.]+$' ]]; then
        print -u2 "Unsafe CVar query name: $query_name"
        exit 2
    fi
done
readonly EXEC_COMMANDS="${(j:,:)QUERY_NAMES}"
readonly DIAGNOSTIC_COMMAND_LINE="${ORIGINAL_COMMAND_LINE%$'\n'} -ExecCmds=\"$EXEC_COMMANDS\""

mkdir -p "$WORK_DIR/assets" "${OUTPUT:h}"
cp -p "$SOURCE_APK" "$WORK_DIR/query.apk"
zip -q -d "$WORK_DIR/query.apk" "$COMMAND_LINE_PATH"
print -r -- "$DIAGNOSTIC_COMMAND_LINE" > "$WORK_DIR/$COMMAND_LINE_PATH"
(
    cd "$WORK_DIR"
    zip -q -9 query.apk "$COMMAND_LINE_PATH"
)
readonly EXTRACTED="$(unzip -p "$WORK_DIR/query.apk" "$COMMAND_LINE_PATH")"
if [[ "$EXTRACTED" != "$DIAGNOSTIC_COMMAND_LINE" ]]; then
    print -u2 "The query overlay command line did not verify after repackaging."
    exit 1
fi
mv -f "$WORK_DIR/query.apk" "$OUTPUT"
print "output=$OUTPUT"
print "sha256=$(shasum -a 256 "$OUTPUT" | awk '{ print $1 }')"
print "queries=${(j:,:)QUERY_NAMES}"
