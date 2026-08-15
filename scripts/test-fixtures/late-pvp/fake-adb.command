#!/bin/zsh
set -euo pipefail

print -r -- "$*" >> "${TFT_FAKE_ADB_LOG:?}"
typeset joined="$*"
case "$joined" in
    *" start-server") exit 0 ;;
    *" get-state") print device ;;
    *" exec-out screencap -p") print -n 'fixture-png' ;;
    *" shell dumpsys activity activities"*)
        print 'topResumedActivity=ActivityRecord{fixture com.riotgames.league.teamfighttactics.pbe/com.epicgames.unreal.GameActivity}'
        ;;
    *" shell pidof com.riotgames.league.teamfighttactics.pbe") print 4242 ;;
    *" shell sha256sum /data/user/0/com.riotgames.league.teamfighttactics.pbe/files/UnrealGame/TFT/TFT/Saved/Config/Android/DeviceProfiles.ini")
        readonly profile_sha_counter_path="${TFT_FAKE_ADB_LOG}.profile-sha-count"
        integer profile_sha_count=0
        [[ -f "$profile_sha_counter_path" ]] \
            && IFS= read -r profile_sha_count < "$profile_sha_counter_path"
        (( profile_sha_count += 1 ))
        print "$profile_sha_count" > "$profile_sha_counter_path"
        typeset profile_sha256="${TFT_FAKE_ACTIVE_PROFILE_SHA256:?}"
        integer profile_sha_after_count="${TFT_FAKE_ACTIVE_PROFILE_SHA256_AFTER_COUNT:-1}"
        if (( profile_sha_count > profile_sha_after_count )) \
                && [[ -n "${TFT_FAKE_ACTIVE_PROFILE_SHA256_AFTER_FIRST:-}" ]]; then
            profile_sha256="$TFT_FAKE_ACTIVE_PROFILE_SHA256_AFTER_FIRST"
        fi
        print "$profile_sha256  /data/user/0/com.riotgames.league.teamfighttactics.pbe/files/UnrealGame/TFT/TFT/Saved/Config/Android/DeviceProfiles.ini"
        ;;
    *" shell cat /proc/4242/mountinfo")
        print '100 99 0:1 / /data/user/0/com.riotgames.league.teamfighttactics.pbe/files/UnrealGame/TFT/TFT/Saved/Config/Android/DeviceProfiles.ini rw - tmpfs tmpfs rw'
        ;;
    *" shell simpleperf list sw") print 'cpu-clock' ;;
    *" shell getconf CLK_TCK") print 100 ;;
    *"for task_dir in /proc/"*)
        readonly counter_path="${TFT_FAKE_ADB_LOG}.thread-snapshot-count"
        integer snapshot_count=0
        [[ -f "$counter_path" ]] && IFS= read -r snapshot_count < "$counter_path"
        (( snapshot_count += 1 ))
        print "$snapshot_count" > "$counter_path"
        if (( snapshot_count == 1 )); then
            cat "${0:A:h:h}/thread-snapshot/before.tsv"
        else
            cat "${0:A:h:h}/thread-snapshot/after.tsv"
        fi
        ;;
    *" shell simpleperf record"*) exit 0 ;;
    *" shell simpleperf report"*)
        if [[ "$joined" == *" --children "* \
                && "${TFT_FAKE_SIMPLEPERF_CHILDREN_REPORT_FAIL:-0}" == 1 ]]; then
            print -u2 'fixture simpleperf children report failure'
            exit 74
        fi
        print '12.00%  com.riotgames.league.teamfighttactics.pbe  4242  4243  writew'
        ;;
    *" pull /data/local/tmp/mactician-late-pvp-4242.data "*)
        if [[ "${TFT_FAKE_SIMPLEPERF_PULL_FAIL:-0}" == 1 ]]; then
            print -n 'partial-fixture-perf-data' > "${@[-1]}"
            print -u2 'fixture simpleperf pull failure'
            exit 73
        fi
        if [[ "${TFT_FAKE_SIMPLEPERF_PULL_EMPTY:-0}" == 1 ]]; then
            : > "${@[-1]}"
            exit 0
        fi
        cp "${0:A:h}/simpleperf.data.fixture" "${@[-1]}"
        ;;
    *" shell rm -f /data/local/tmp/mactician-late-pvp-4242.data") exit 0 ;;
    *) exit 0 ;;
esac
