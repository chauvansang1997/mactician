#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "-s" ]]; then
    shift 2
fi
if [[ "${1:-}" != "shell" ]]; then
    print -u2 "Unexpected fake adb command: $*"
    exit 2
fi
shift
readonly shell_command="$*"

case "$shell_command" in
    'pidof com.riotgames.league.teamfighttactics.pbe')
        print 4242
        ;;
    'su 0 cat /proc/4242/maps')
        print '1000000000-1002dd3000 r--p 00000000 fe:35 1 /data/app/fixture/lib/arm64/libUnreal.so'
        print '1002dd7000-100a22f000 r-xp 02dd3000 fe:35 1 /data/app/fixture/lib/arm64/libUnreal.so'
        print '100ba34b000-100bdef2000 rw-p 00000000 00:00 0 [anon:.bss]'
        ;;
    "su 0 sha256sum '/data/app/fixture/lib/arm64/libUnreal.so'")
        print '4edeb935c1e800c6846aac77d066d9895435d0e68e2d585937601484e7589822  /data/app/fixture/lib/arm64/libUnreal.so'
        ;;
    *'100bc7ccdc -l 4 /proc/4242/mem'*) print '00000000' ;;
    *'100b9f9e8c -l 4 /proc/4242/mem'*) print '01000000' ;;
    *'100bc7cce4 -l 4 /proc/4242/mem'*) print '00000000' ;;
    *'100bc7cce8 -l 4 /proc/4242/mem'*) print '00000000' ;;
    *'100b9f9e90 -l 4 /proc/4242/mem'*) print '01000000' ;;
    *'100b9f9e94 -l 4 /proc/4242/mem'*) print '01000000' ;;
    *'100b9f9e88 -l 4 /proc/4242/mem'*) print '01000000' ;;
    *'100bc7dbf4 -l 4 /proc/4242/mem'*) print '00000001' ;;
    *'100bc7dbf8 -l 4 /proc/4242/mem'*) print '00000000' ;;
    *)
        print -u2 "Unexpected fake adb shell command: $shell_command"
        exit 2
        ;;
esac
