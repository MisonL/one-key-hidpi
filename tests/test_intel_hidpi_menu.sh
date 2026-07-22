#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="${repo_dir}/tests/fixtures"
menu_library="${repo_dir}/lib/intel_hidpi_menu.sh"
tool_path="${repo_dir}/intel-hidpi.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local expected="$2"

    printf '%s\n' "$haystack" | /usr/bin/grep -Fq "$expected" || fail "missing expected text: ${expected}"
}

first_edid="$(/usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p' "${fixture_dir}/ioreg-displays.txt" | /usr/bin/sed -n '1p')"

menu_preview_output="$(\
    langInputChoice="Enter your choice" \
    langEnterError="Enter error" \
    langIntelSafeTitle="Intel safe HiDPI" \
    langIntelSafeApply="(1) Apply generated modes" \
    langIntelSafeRevert="(2) Revert generated modes" \
    langIntelSafeCancel="(3) Cancel" \
    langIntelSafeRoot="Run this script as root" \
    langIntelSafeApplyConfirm="Type APPLY" \
    langIntelSafeRevertConfirm="Type REVERT" \
    langIntelSafeCancelled="Cancelled" \
    langIntelSafeToolMissing="Tool is missing" \
    /bin/bash -c 'source "$1"; printf "3\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
        "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
)" || fail "preview and cancel flow should succeed"

assert_contains "$menu_preview_output" "Intel safe HiDPI: 1920x1080"
assert_contains "$menu_preview_output" "compact: 960x540 framebuffer=1920x1080 payload="
assert_contains "$menu_preview_output" "Cancelled"

menu_definition="$(/bin/bash -c 'source "$1"; declare -f intel_safe_hidpi' bash "$menu_library")"
if printf '%s\n' "$menu_definition" | /usr/bin/grep -Fq "sudo"; then
    fail "safe menu must not invoke sudo"
fi

entrypoint_trace="$(mktemp "${TMPDIR:-/tmp}/one-key-hidpi-menu.XXXXXX")"
trap '/bin/rm -f "$entrypoint_trace"' EXIT

if ! /bin/bash -c '
    source "$1"
    selected_edid="$2"
    trace_path="$3"
    is_applesilicon=false
    select_display() {
        EDID="$selected_edid"
        Vid=30ae
        Pid=62a5
    }
    init() {
        printf "legacy-init\n" >> "$trace_path"
    }
    intel_safe_hidpi() {
        printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$trace_path"
    }
    printf "4\n" | start
' bash "$repo_dir/hidpi.sh" "$first_edid" "$entrypoint_trace" >/dev/null; then
    fail "safe entrypoint selection should succeed"
fi

entrypoint_output="$(/bin/cat "$entrypoint_trace")" || fail "safe entrypoint trace should be readable"

[[ "$entrypoint_output" == "${repo_dir}/intel-hidpi.sh|${first_edid}|30ae|62a5" ]] || fail "safe entrypoint must call the safe menu with the selected display"

assert_legacy_dispatch() {
    local choice="$1"
    local expected="$2"
    local actual

    : > "$entrypoint_trace"
    if ! /bin/bash -c '
        source "$1"
        trace_path="$2"
        is_applesilicon=false
        select_display() {
            EDID=test
            Vid=30ae
            Pid=62a5
        }
        init() {
            printf "init\n" >> "$trace_path"
        }
        enable_hidpi() {
            printf "enable\n" >> "$trace_path"
        }
        enable_hidpi_with_patch() {
            printf "patch\n" >> "$trace_path"
        }
        disable() {
            printf "disable\n" >> "$trace_path"
        }
        printf "%s\n" "$3" | start
    ' bash "$repo_dir/hidpi.sh" "$entrypoint_trace" "$choice" >/dev/null; then
        fail "legacy menu option ${choice} should succeed"
    fi

    actual="$(/bin/cat "$entrypoint_trace")" || fail "legacy menu trace should be readable"
    [[ "$actual" == "$expected" ]] || fail "legacy menu option ${choice} dispatch changed"
}

assert_legacy_dispatch 1 $'init\nenable'
assert_legacy_dispatch 2 $'init\npatch'
assert_legacy_dispatch 3 $'init\ndisable'

if ((EUID != 0)); then
    if nonroot_output="$(\
        langInputChoice="Enter your choice" \
        langEnterError="Enter error" \
        langIntelSafeTitle="Intel safe HiDPI" \
        langIntelSafeApply="(1) Apply generated modes" \
        langIntelSafeRevert="(2) Revert generated modes" \
        langIntelSafeCancel="(3) Cancel" \
        langIntelSafeRoot="Run this script as root" \
        langIntelSafeApplyConfirm="Type APPLY" \
        langIntelSafeRevertConfirm="Type REVERT" \
        langIntelSafeCancelled="Cancelled" \
        langIntelSafeToolMissing="Tool is missing" \
        /bin/bash -c 'source "$1"; printf "1\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
            "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
    )"; then
        fail "non-root apply selection must fail explicitly"
    fi
    assert_contains "$nonroot_output" "Run this script as root"
fi

printf 'PASS: Intel HiDPI menu\n'
