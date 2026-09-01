#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 "Usage: ${0:t} 0|1 GameUserSettings.ini"
    exit 2
fi

readonly PERFORMANCE_MODE="$1"
readonly INPUT_FILE="$2"
if [[ "$PERFORMANCE_MODE" != "0" && "$PERFORMANCE_MODE" != "1" ]]; then
    print -u2 "Performance Mode must be either 0 or 1."
    exit 2
fi
if [[ ! -f "$INPUT_FILE" || ! -r "$INPUT_FILE" ]]; then
    print -u2 "GameUserSettings.ini is not readable: $INPUT_FILE"
    exit 2
fi

readonly PERFORMANCE_VALUE="$([[ "$PERFORMANCE_MODE" == "1" ]] && print True || print False)"
LC_ALL=C /usr/bin/awk -v enabled="$PERFORMANCE_VALUE" '
    BEGIN {
        section = "[/Script/TFTSettings.TFTUserSettings]"
        found_section = 0
        in_section = 0
        found_graphics = 0
    }
    $0 == section {
        print
        found_section = 1
        in_section = 1
        next
    }
    /^\[/ {
        if (in_section && !found_graphics) {
            print "GraphicsSettings=(bPerformanceMode=" enabled ")"
            found_graphics = 1
        }
        in_section = 0
        print
        next
    }
    in_section && /^[[:space:]]*GraphicsSettings[[:space:]]*=/ {
        line = $0
        if (line ~ /bPerformanceMode=(True|False)/) {
            sub(/bPerformanceMode=(True|False)/, "bPerformanceMode=" enabled, line)
        } else if (line ~ /bPerformanceMode=/) {
            print "Unsupported bPerformanceMode value in GraphicsSettings." > "/dev/stderr"
            exit 1
        } else if (line ~ /\)[[:space:]]*$/) {
            sub(/\)[[:space:]]*$/, ",bPerformanceMode=" enabled ")", line)
        } else {
            print "Malformed GraphicsSettings in GameUserSettings.ini." > "/dev/stderr"
            exit 1
        }
        print line
        found_graphics = 1
        next
    }
    { print }
    END {
        if (!found_section) {
            if (NR > 0) {
                print ""
            }
            print section
            print "GraphicsSettings=(bPerformanceMode=" enabled ")"
        } else if (in_section && !found_graphics) {
            print "GraphicsSettings=(bPerformanceMode=" enabled ")"
        }
    }
' "$INPUT_FILE"
