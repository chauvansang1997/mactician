#!/bin/zsh
set -euo pipefail

readonly REPORT_PATH="${1:-}"
readonly OUTPUT_PATH="${2:-}"
readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"

if [[ -z "$REPORT_PATH" || ! -f "$REPORT_PATH" ]]; then
    print -u2 "Usage: ${0:t} /path/to/simpleperf-report.txt [output.json]"
    exit 2
fi
if [[ ! -x "$JQ" ]]; then
    print -u2 "jq is required to summarize a simpleperf report."
    exit 1
fi
if [[ -n "$OUTPUT_PATH" && "$OUTPUT_PATH" == "$REPORT_PATH" ]]; then
    print -u2 "The output path must differ from the input report."
    exit 2
fi

readonly WORK_ROOT="$(mktemp -d -t mactician-simpleperf-summary)"
cleanup() {
    local exit_code=$?
    rm -rf "$WORK_ROOT"
    return "$exit_code"
}
trap cleanup EXIT

readonly ROWS_PATH="$WORK_ROOT/rows.tsv"
readonly THREADS_PATH="$WORK_ROOT/threads.tsv"
readonly SYMBOLS_PATH="$WORK_ROOT/symbols.tsv"
readonly CATEGORIES_PATH="$WORK_ROOT/categories.tsv"
readonly GENERATED_PATH="$WORK_ROOT/summary.json"

# simpleperf pads Command to 42 characters before the numeric Pid/Tid fields.
# Preserve that fixed-width column so thread names containing spaces remain
# unambiguous. Rows are exclusive sample overheads; call-chain lines start with
# whitespace and are intentionally ignored.
perl -ne '
    if (/^([0-9]+(?:\.[0-9]+)?)%\s+(.{1,42})\s+(\d+)\s+(\d+)\s+(.+)$/) {
        $overhead = $1;
        $command = $2;
        $symbol = $5;
        $command =~ s/\s+$//;
        print "$overhead\t$command\t$symbol\n";
    }
' "$REPORT_PATH" > "$ROWS_PATH"

if [[ ! -s "$ROWS_PATH" ]]; then
    print -u2 "No simpleperf overhead rows were found in: $REPORT_PATH"
    exit 1
fi

awk -F '\t' '{ value[$2] += $1 } END { for (key in value) printf "%.6f\t%s\n", value[key], key }' \
    "$ROWS_PATH" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 > "$THREADS_PATH"
awk -F '\t' '{ value[$3] += $1 } END { for (key in value) printf "%.6f\t%s\n", value[key], key }' \
    "$ROWS_PATH" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 > "$SYMBOLS_PATH"
awk -F '\t' '
    function category(symbol) {
        if (symbol ~ /^(writew|ring_buffer_available_read)$/ || symbol ~ /AddressSpaceStream::/) {
            return "virtio_gpu_transport"
        }
        if (symbol ~ /^rx::(vk|RendererVk|ContextVk)/) {
            return "angle_vulkan"
        }
        if (symbol ~ /(__memcpy|__memset|malloc|operator new|operator delete|scudo::)/) {
            return "memory_allocation_copy"
        }
        if (symbol ~ /(try_to_wake_up|__wake_up|spin_lock|handle_softirqs|__schedule|local_daif_restore)/) {
            return "scheduler_synchronization"
        }
        if (symbol ~ /^libUnreal[.]so\[\+/) {
            return "unreal_stripped"
        }
        return "other"
    }
    { value[category($3)] += $1 }
    END { for (key in value) printf "%.6f\t%s\n", value[key], key }
' "$ROWS_PATH" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 > "$CATEGORIES_PATH"

readonly REPORT_SHA256="$(shasum -a 256 "$REPORT_PATH" | awk '{print $1}')"
readonly SAMPLE_COUNT="$(awk '/^Samples:/ { print $2; exit }' "$REPORT_PATH")"
readonly EVENT_COUNT="$(awk '/^Event count:/ { print $3; exit }' "$REPORT_PATH")"
readonly EVENT_NAME="$(sed -n 's/^Event: \([^ ]*\).*/\1/p' "$REPORT_PATH" | head -1)"
readonly ROW_COUNT="$(wc -l < "$ROWS_PATH" | tr -d ' ')"
readonly REPORTED_OVERHEAD_SUM="$(awk -F '\t' '{ total += $1 } END { printf "%.6f", total }' "$ROWS_PATH")"

tsv_to_json() {
    local input_path="$1"
    local limit="$2"
    head -n "$limit" "$input_path" | "$JQ" -Rn '
        [inputs
        | capture("^(?<overhead_percent>[^\\t]+)\\t(?<name>.*)$")
        | {name: .name, overhead_percent: (.overhead_percent | tonumber)}]
    '
}

readonly TOP_THREADS="$(tsv_to_json "$THREADS_PATH" 20)"
readonly TOP_SYMBOLS="$(tsv_to_json "$SYMBOLS_PATH" 30)"
readonly CATEGORIES="$(tsv_to_json "$CATEGORIES_PATH" 20)"

"$JQ" -n \
    --arg report_path "$REPORT_PATH" \
    --arg report_sha256 "$REPORT_SHA256" \
    --arg event "$EVENT_NAME" \
    --argjson samples "${SAMPLE_COUNT:-0}" \
    --argjson event_count "${EVENT_COUNT:-0}" \
    --argjson row_count "$ROW_COUNT" \
    --argjson reported_overhead_sum_percent "$REPORTED_OVERHEAD_SUM" \
    --argjson top_threads "$TOP_THREADS" \
    --argjson top_symbols "$TOP_SYMBOLS" \
    --argjson categories "$CATEGORIES" \
    '{
        schema_version: 1,
        source: {
            report_path: $report_path,
            report_sha256: $report_sha256,
            event: $event,
            samples: $samples,
            event_count: $event_count,
            exclusive_rows: $row_count
        },
        methodology: {
            aggregation: "exclusive overhead rows grouped by command, symbol, and mutually exclusive symbol category",
            caveat: "simpleperf percentages are rounded per row; their reported sum need not equal exactly 100 percent"
        },
        reported_overhead_sum_percent: $reported_overhead_sum_percent,
        top_threads: $top_threads,
        top_symbols: $top_symbols,
        symbol_categories: $categories
    }' > "$GENERATED_PATH"

if [[ -n "$OUTPUT_PATH" ]]; then
    mkdir -p "${OUTPUT_PATH:h}"
    cp "$GENERATED_PATH" "$OUTPUT_PATH"
else
    print -r -- "$(<"$GENERATED_PATH")"
fi
