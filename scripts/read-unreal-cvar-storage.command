#!/bin/zsh
set -euo pipefail

readonly SERIAL="${TFT_SERIAL:-emulator-5582}"
readonly PACKAGE="${TFT_PACKAGE:-com.riotgames.league.teamfighttactics}"
readonly ADB="${TFT_ADB:-$(command -v adb 2>/dev/null || true)}"
readonly EXPECTED_BINARY_SHA256="${TFT_UNREAL_BINARY_SHA256:-4edeb935c1e800c6846aac77d066d9895435d0e68e2d585937601484e7589822}"
readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"

if [[ ! -x "$ADB" || ! -x "$JQ" ]]; then
    print -u2 "adb and jq are required to read Unreal CVar storage."
    exit 1
fi
if [[ ! "$EXPECTED_BINARY_SHA256" =~ '^[0-9a-f]{64}$' ]]; then
    print -u2 "TFT_UNREAL_BINARY_SHA256 must be a lowercase SHA-256 digest."
    exit 2
fi

typeset -a SPECS
if (( $# > 0 )); then
    SPECS=("$@")
else
    SPECS=(
        'OpenGL.UseStagingBuffer=0xbc7ccdc'
        'OpenGL.UseMapBuffer=0xb9f9e8c'
        'OpenGL.MaxSubDataSize=0xbc7cce4'
        'OpenGL.RebindTextureBuffers=0xbc7cce8'
        'OpenGL.UseBufferDiscard=0xb9f9e90'
        'OpenGL.UseUnsynchronizedBufferMapping=0xb9f9e94'
        'OpenGL.UsePersistentMappingStagingBuffer=0xb9f9e88'
        'OpenGL.UBOPoolSize=0xbc7dbf4'
        'OpenGL.UBODirectWrite=0xbc7dbf8'
    )
fi

typeset process_id
process_id="$("$ADB" -s "$SERIAL" shell "pidof $PACKAGE" | tr -d '\r[:space:]')"
if [[ ! "$process_id" =~ '^[0-9]+$' ]]; then
    print -u2 "TFT is not running on $SERIAL."
    exit 1
fi

typeset maps_text lib_line lib_range load_bias_hex lib_path remote_sha
maps_text="$("$ADB" -s "$SERIAL" shell "su 0 cat /proc/$process_id/maps")"
lib_line="$(print -r -- "$maps_text" | awk '$3 == "00000000" && $NF ~ /\/libUnreal[.]so$/ { print }')"
if [[ -z "$lib_line" ]]; then
    print -u2 "The offset-zero libUnreal.so mapping was not found."
    exit 1
fi
lib_range="${lib_line%% *}"
load_bias_hex="${lib_range%%-*}"
lib_path="${lib_line##* }"
if [[ ! "$load_bias_hex" =~ '^[0-9a-f]+$' || "$lib_path" != /*/libUnreal.so ]]; then
    print -u2 "The libUnreal.so mapping could not be parsed safely."
    exit 1
fi
remote_sha="$("$ADB" -s "$SERIAL" shell "su 0 sha256sum '$lib_path'" \
    | awk '{ print $1 }' | tr -d '\r')"
if [[ "$remote_sha" != "$EXPECTED_BINARY_SHA256" ]]; then
    print -u2 "The loaded libUnreal.so does not match TFT_UNREAL_BINARY_SHA256."
    print -u2 "Actual SHA-256: ${remote_sha:-<missing>}"
    exit 1
fi

readonly WORK_ROOT="$(mktemp -d -t mactician-unreal-cvar-storage)"
cleanup() {
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT
readonly VALUES_TSV="$WORK_ROOT/values.tsv"

typeset spec cvar vma_hex vma_value runtime_address raw_hex decoded_value
for spec in "${SPECS[@]}"; do
    if [[ "$spec" != *=* ]]; then
        print -u2 "Invalid CVar storage spec: $spec"
        exit 2
    fi
    cvar="${spec%%=*}"
    vma_hex="${spec#*=}"
    if [[ ! "$cvar" =~ '^[A-Za-z][A-Za-z0-9.]+$' \
            || ! "$vma_hex" =~ '^0x[0-9a-f]+$' ]]; then
        print -u2 "Invalid CVar storage spec: $spec"
        exit 2
    fi
    vma_value=$(( 16#${vma_hex#0x} ))
    runtime_address=$(( 16#$load_bias_hex + vma_value ))
    raw_hex="$("$ADB" -s "$SERIAL" shell \
        "su 0 sh -c 'toybox xxd -p -c 4 -s 0x${(l:16::0:)${(L)$(printf %x $runtime_address)}} -l 4 /proc/$process_id/mem'" \
        | tr -d '\r[:space:]')"
    if [[ ! "$raw_hex" =~ '^[0-9a-f]{8}$' ]]; then
        print -u2 "Could not read four bytes for $cvar at $vma_hex."
        exit 1
    fi
    decoded_value="$(perl -e 'print unpack("V", pack("H*", $ARGV[0]))' "$raw_hex")"
    print -r -- "$cvar"$'\t'"$vma_hex"$'\t'"$(printf '0x%x' $runtime_address)"$'\t'"$raw_hex"$'\t'"$decoded_value" \
        >> "$VALUES_TSV"
done

"$JQ" -Rn \
    --arg serial "$SERIAL" \
    --arg package "$PACKAGE" \
    --argjson process_id "$process_id" \
    --arg binary_sha256 "$remote_sha" \
    --arg load_bias "0x$load_bias_hex" '
    {
        schema_version: 1,
        source: {
            serial: $serial,
            package: $package,
            process_id: $process_id,
            binary_sha256: $binary_sha256,
            load_bias: $load_bias
        },
        methodology: {
            mapping: "offset-zero libUnreal.so mapping plus static ELF VMA",
            read: "four bytes from /proc/PID/mem through root toybox xxd",
            decode: "unsigned little-endian 32-bit integer",
            scope: "live referenced storage only; semantic interpretation still depends on the CVar type and call sites"
        },
        values: [inputs | split("\t") | {
            cvar: .[0],
            storage_vma: .[1],
            runtime_address: .[2],
            raw_le_hex: .[3],
            value_u32: (.[4] | tonumber)
        }]
    }
' < "$VALUES_TSV"
