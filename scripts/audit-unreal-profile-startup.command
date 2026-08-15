#!/bin/zsh
set -euo pipefail

readonly BASE_PROFILE="${1:-}"
readonly CANDIDATE_PROFILE="${2:-}"
readonly STARTUP_LOG="${3:-}"
readonly OUTPUT_PATH="${4:-}"
readonly JQ="${TFT_JQ:-$(command -v jq 2>/dev/null || true)}"

if [[ -z "$BASE_PROFILE" || -z "$CANDIDATE_PROFILE" || -z "$STARTUP_LOG" ]]; then
    print -u2 "Usage: ${0:t} base-profile.ini candidate-profile.ini TFT.log [output.json]"
    exit 2
fi
for input_file in "$BASE_PROFILE" "$CANDIDATE_PROFILE" "$STARTUP_LOG"; do
    if [[ ! -f "$input_file" || ! -r "$input_file" ]]; then
        print -u2 "Required input is missing or unreadable: $input_file"
        exit 1
    fi
done
if [[ ! -x "$JQ" ]]; then
    print -u2 "jq is required to audit Unreal startup CVars."
    exit 1
fi

readonly WORK_ROOT="$(mktemp -d -t mactician-unreal-startup-audit)"
cleanup() {
    local exit_code=$?
    rm -rf "$WORK_ROOT"
    return "$exit_code"
}
trap cleanup EXIT

extract_profile_cvars() {
    local profile_path="$1"
    perl -ne '
        if (/^\s*\+?CVars=([^=\s]+)=(.*?)\s*$/) {
            $values{$1} = $2;
        }
        END {
            for $key (sort keys %values) {
                print "$key\t$values{$key}\n";
            }
        }
    ' "$profile_path"
}

readonly BASE_CVARS="$WORK_ROOT/base.tsv"
readonly CANDIDATE_CVARS="$WORK_ROOT/candidate.tsv"
readonly DELTAS="$WORK_ROOT/deltas.tsv"
readonly EVIDENCE="$WORK_ROOT/evidence.tsv"
readonly GENERATED_PATH="$WORK_ROOT/audit.json"
extract_profile_cvars "$BASE_PROFILE" > "$BASE_CVARS"
extract_profile_cvars "$CANDIDATE_PROFILE" > "$CANDIDATE_CVARS"

awk -F '\t' '
    NR == FNR { base[$1] = $2; next }
    !($1 in base) || base[$1] != $2 {
        previous = (($1 in base) ? base[$1] : "")
        print $1 "\t" previous "\t" $2
    }
' "$BASE_CVARS" "$CANDIDATE_CVARS" > "$DELTAS"

readonly REMOVED_KEYS="$(comm -23 \
    <(cut -f1 "$BASE_CVARS") \
    <(cut -f1 "$CANDIDATE_CVARS"))"
if [[ -n "$REMOVED_KEYS" ]]; then
    print -u2 "Candidate profiles may add or change CVars but must not remove base CVars."
    print -u2 -r -- "$REMOVED_KEYS"
    exit 1
fi
if [[ ! -s "$DELTAS" ]]; then
    print -u2 "The candidate profile has no CVar delta from the base profile."
    exit 2
fi

# Match only structured DeviceProfile and priority-protection log records. The
# full TFT.log is hashed but never copied to the evidence file. This prevents a
# coincidental game string from attesting a CVar and avoids publishing unrelated
# log content.
DELTA_PATH="$DELTAS" perl -F'\t' -lane '
    if ($ARGV eq $ENV{DELTA_PATH}) {
        push @order, $F[0];
        $base{$F[0]} = $F[1];
        $expected{$F[0]} = $F[2];
        next;
    }
    for $key (@order) {
        next unless index($_, $key) >= 0;
        if (index($_, "Pushing Device Profile CVar") >= 0
                && index($_, $expected{$key}) >= 0) {
            $push{$key}++;
        }
        if (index($_, "ignored") >= 0
                && index($_, "SetByDeviceProfile") >= 0
                && index($_, "Value remains") >= 0
                && index($_, $expected{$key}) >= 0) {
            $protected{$key}++;
        }
    }
    END {
        for $key (@order) {
            print join("\t", $key, $base{$key}, $expected{$key},
                0 + $push{$key}, 0 + $protected{$key});
        }
    }
' "$DELTAS" "$STARTUP_LOG" > "$EVIDENCE"

readonly DELTA_COUNT="$(wc -l < "$EVIDENCE" | tr -d ' ')"
readonly ATTESTED_COUNT="$(awk -F '\t' '$4 > 0 { count++ } END { print 0 + count }' "$EVIDENCE")"
readonly PROTECTED_COUNT="$(awk -F '\t' '$5 > 0 { count++ } END { print 0 + count }' "$EVIDENCE")"
readonly BASE_SHA256="$(shasum -a 256 "$BASE_PROFILE" | awk '{print $1}')"
readonly CANDIDATE_SHA256="$(shasum -a 256 "$CANDIDATE_PROFILE" | awk '{print $1}')"
readonly LOG_SHA256="$(shasum -a 256 "$STARTUP_LOG" | awk '{print $1}')"

readonly DELTA_JSON="$("$JQ" -Rn '
    [inputs
    | split("\t")
    | {
        key: .[0],
        base_value: (if .[1] == "" then null else .[1] end),
        candidate_value: .[2],
        device_profile_push_records: (.[3] | tonumber),
        protected_override_records: (.[4] | tonumber),
        startup_attested: ((.[3] | tonumber) > 0)
    }]
' < "$EVIDENCE")"

"$JQ" -n \
    --arg base_profile "$BASE_PROFILE" \
    --arg base_profile_sha256 "$BASE_SHA256" \
    --arg candidate_profile "$CANDIDATE_PROFILE" \
    --arg candidate_profile_sha256 "$CANDIDATE_SHA256" \
    --arg startup_log_sha256 "$LOG_SHA256" \
    --argjson delta_count "$DELTA_COUNT" \
    --argjson attested_count "$ATTESTED_COUNT" \
    --argjson protected_count "$PROTECTED_COUNT" \
    --argjson deltas "$DELTA_JSON" \
    '{
        schema_version: 1,
        source: {
            base_profile: $base_profile,
            base_profile_sha256: $base_profile_sha256,
            candidate_profile: $candidate_profile,
            candidate_profile_sha256: $candidate_profile_sha256,
            startup_log_sha256: $startup_log_sha256,
            startup_log_embedded: false
        },
        methodology: {
            attestation: "exact candidate-only CVar deltas observed in DeviceProfile push records",
            protected_override: "lower-priority write was logged as ignored and retained the candidate value",
            scope: "startup application and priority only; this is not a runtime FPS result"
        },
        result: {
            delta_count: $delta_count,
            startup_attested_count: $attested_count,
            protected_override_count: $protected_count,
            all_deltas_startup_attested: ($attested_count == $delta_count)
        },
        deltas: $deltas
    }' > "$GENERATED_PATH"

if [[ -n "$OUTPUT_PATH" ]]; then
    mkdir -p "${OUTPUT_PATH:h}"
    cp "$GENERATED_PATH" "$OUTPUT_PATH"
else
    print -r -- "$(<"$GENERATED_PATH")"
fi

if (( ATTESTED_COUNT != DELTA_COUNT )); then
    print -u2 "Only $ATTESTED_COUNT of $DELTA_COUNT candidate CVars were attested in the startup log."
    exit 3
fi
