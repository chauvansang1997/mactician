#!/bin/zsh
set -euo pipefail

readonly LIB_UNREAL="${1:-}"
readonly FILTER="${2:-}"

if [[ -z "$LIB_UNREAL" || ! -f "$LIB_UNREAL" ]]; then
    print -u2 "Usage: ${0:t} /path/to/libUnreal.so [case-insensitive-regex]"
    exit 2
fi
if [[ ! -r "$LIB_UNREAL" ]]; then
    print -u2 "Unreal library is not readable: $LIB_UNREAL"
    exit 1
fi

# Android Unreal stores many console-variable names as UTF-16LE. Apple's
# strings(1) only extracts byte strings, so decode bounded printable UTF-16LE
# runs and keep identifier-shaped dotted names. This is a static capability
# inventory: presence does not establish the runtime default or that a given
# game asset participates in the feature.
extract_names() {
    perl -0777 -ne '
        while (/((?:[\x20-\x7e]\x00){4,})/g) {
            $name = $1;
            $name =~ s/\x00//g;
            print "$name\n";
        }
    ' "$LIB_UNREAL" \
        | LC_ALL=C grep -E '^([A-Za-z][A-Za-z0-9]*[.])+[A-Za-z0-9_.]+$' \
        | LC_ALL=C sort -fu
}

if [[ -n "$FILTER" ]]; then
    extract_names | rg -i -- "$FILTER"
else
    extract_names
fi
