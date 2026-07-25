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

assert_not_contains() {
    local haystack="$1"
    local unexpected="$2"

    if printf '%s\n' "$haystack" | /usr/bin/grep -Fq "$unexpected"; then
        fail "unexpected text: ${unexpected}"
    fi
}

assert_file_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected file: $1"
}

first_edid="$(/usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p' "${fixture_dir}/ioreg-displays.txt" | /usr/bin/sed -n '1p')"
[[ -n "$first_edid" ]] || fail "could not load an EDID fixture"

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
    /bin/bash -c 'source "$1"; printf "3\\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
        "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
)" || fail "preview and cancel flow should succeed"
assert_contains "$menu_preview_output" "Intel safe HiDPI: 1920x1080"
assert_contains "$menu_preview_output" "compact: 960x540 framebuffer=1920x1080 payload="
assert_contains "$menu_preview_output" "Cancelled"

menu_definition="$(/bin/bash -c 'source "$1"; declare -f intel_safe_hidpi' bash "$menu_library")"
if printf '%s\n' "$menu_definition" | /usr/bin/grep -Fq "sudo"; then
    fail "safe menu must not invoke sudo"
fi

entrypoint_trace="$(mktemp "${TMPDIR:-/tmp}/one-key-hidpi-menu.XXXXXX")" || fail "could not create menu trace"
standalone_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-standalone.XXXXXX")" || fail "could not create standalone fixture"
standalone_script="${standalone_dir}/hidpi.sh"
remote_source_marker="${standalone_dir}/remote-source-marker"

cleanup() {
    /bin/rm -f "$entrypoint_trace"
    /bin/rm -rf "$standalone_dir"
}
trap cleanup EXIT

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
        printf "legacy-init\\n" >> "$trace_path"
    }
    intel_safe_hidpi() {
        printf "%s|%s|%s|%s\\n" "$1" "$2" "$3" "$4" >> "$trace_path"
    }
    printf "4\\n" | start
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
            printf "init\\n" >> "$trace_path"
        }
        enable_hidpi() {
            printf "enable\\n" >> "$trace_path"
        }
        enable_hidpi_with_patch() {
            printf "patch\\n" >> "$trace_path"
        }
        disable() {
            printf "disable\\n" >> "$trace_path"
        }
        printf "%s\\n" "$3" | start
    ' bash "$repo_dir/hidpi.sh" "$entrypoint_trace" "$choice" >/dev/null; then
        fail "legacy menu option ${choice} should succeed"
    fi

    actual="$(/bin/cat "$entrypoint_trace")" || fail "legacy menu trace should be readable"
    [[ "$actual" == "$expected" ]] || fail "legacy menu option ${choice} dispatch changed"
}

assert_legacy_dispatch 1 $'init\nenable'
assert_legacy_dispatch 2 $'init\npatch'
assert_legacy_dispatch 3 $'init\ndisable'

assert_legacy_init_failure_stops_dispatch() {
    local choice="$1"
    local actual

    : > "$entrypoint_trace"
    if /bin/bash -c '
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
            return 1
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
    ' bash "$repo_dir/hidpi.sh" "$entrypoint_trace" "$choice" >/dev/null 2>&1; then
        fail "legacy menu option ${choice} must stop when initialization fails"
    fi

    actual="$(/bin/cat "$entrypoint_trace")" || fail "legacy initialization trace should be readable"
    [[ "$actual" == "init" ]] || fail "legacy menu option ${choice} continued after initialization failed"
}

assert_legacy_init_failure_stops_dispatch 1
assert_legacy_init_failure_stops_dispatch 2
assert_legacy_init_failure_stops_dispatch 3

readme_zh_contents="$(/bin/cat "${repo_dir}/README-zh.md")" || fail "could not read Chinese README"
assert_contains "$readme_zh_contents" "sudo ./intel-hidpi.sh revert"
assert_not_contains "$readme_zh_contents" "rm -rf /Volumes/你的系统盘/Library/Displays/Contents/Resources/Overrides"

readme_en_contents="$(/bin/cat "${repo_dir}/README.md")" || fail "could not read English README"
assert_contains "$readme_en_contents" "sudo ./intel-hidpi.sh revert"
assert_not_contains "$readme_en_contents" 'rm -rf /Volumes/"Your System Disk Part"/Library/Displays/Contents/Resources/Overrides'

/bin/cp "$repo_dir/hidpi.sh" "$standalone_script" || fail "could not create standalone hidpi script"
/bin/chmod +x "$standalone_script" || fail "could not mark standalone hidpi script executable"

assert_standalone_legacy_dispatch() {
    local choice="$1"
    local expected="$2"
    local actual

    : > "$entrypoint_trace"
    if ! /bin/bash -c '
        cd "$2"
        source "$1"
        trace_path="$3"
        is_applesilicon=false
        select_display() {
            EDID=test
            Vid=30ae
            Pid=62a5
        }
        init() {
            printf "init\\n" >> "$trace_path"
        }
        enable_hidpi() {
            printf "enable\\n" >> "$trace_path"
        }
        enable_hidpi_with_patch() {
            printf "patch\\n" >> "$trace_path"
        }
        disable() {
            printf "disable\\n" >> "$trace_path"
        }
        printf "%s\\n" "$4" | start
    ' bash "$standalone_script" "$standalone_dir" "$entrypoint_trace" "$choice" >/dev/null; then
        fail "standalone legacy menu option ${choice} should succeed"
    fi

    actual="$(/bin/cat "$entrypoint_trace")" || fail "standalone legacy trace should be readable"
    [[ "$actual" == "$expected" ]] || fail "standalone legacy menu option ${choice} dispatch changed"
}

assert_standalone_legacy_dispatch 1 $'init\nenable'
assert_standalone_legacy_dispatch 2 $'init\npatch'
assert_standalone_legacy_dispatch 3 $'init\ndisable'

remote_script="$(/bin/cat "$standalone_script")" || fail "could not read standalone hidpi script"
/bin/mkdir -p "${standalone_dir}/lib" || fail "could not create remote helper fixture"
# shellcheck disable=SC2016
printf 'printf "unexpected helper source\\n" >> "$REMOTE_SOURCE_MARKER"\n' > "${standalone_dir}/lib/intel_hidpi_menu.sh"
printf ':\n' > "${standalone_dir}/intel-hidpi.sh"
remote_output=""
if remote_output="$(
    cd "$standalone_dir" || exit 1
    printf "4\n" | LANG=C LC_ALL=C REMOTE_SOURCE_MARKER="$remote_source_marker" /bin/bash -c '
        remote_script="$1"
        remote_edid="$2"
        ioreg() {
            printf "    | | \\\"IODisplayEDID\\\" = <%s>\\n" "$remote_edid"
        }
        eval "$remote_script"
    ' bash "$remote_script" "$first_edid" 2>&1
)"; then
    fail "remote single-file script should reject an unavailable safe-menu selection"
fi
assert_contains "$remote_output" "(1) Enable HIDPI"
assert_contains "$remote_output" "(3) Disable HIDPI"
assert_contains "$remote_output" "Enter error, bye"
assert_not_contains "$remote_output" "Intel safe HiDPI"
assert_file_absent "$remote_source_marker"

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
        /bin/bash -c 'source "$1"; printf "1\\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
            "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
    )"; then
        fail "non-root apply selection must fail explicitly"
    fi
    assert_contains "$nonroot_output" "Run this script as root"
fi

printf 'PASS: Intel HiDPI menu\n'
