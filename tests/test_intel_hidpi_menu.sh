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

assert_file_exists() {
    [[ -f "$1" ]] || fail "expected file: $1"
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
standalone_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-standalone.XXXXXX")"
standalone_script="${standalone_dir}/hidpi.sh"
remote_source_marker="${standalone_dir}/remote-source-marker"
legacy_disable_root="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-legacy-disable.XXXXXX")"
legacy_restore_home="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-legacy-restore.XXXXXX")"

cleanup() {
    /bin/rm -f "$entrypoint_trace"
    /bin/rm -rf "$standalone_dir"
    /bin/rm -rf "$legacy_disable_root"
    /bin/rm -rf "$legacy_restore_home"
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

legacy_current_target="${legacy_disable_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
legacy_sibling_target="${legacy_disable_root}/DisplayVendorID-30ae/DisplayProductID-7777"
legacy_current_icon="${legacy_current_target}.icns"
legacy_current_tiff="${legacy_current_target}.tiff"
legacy_sibling_icon="${legacy_sibling_target}.icns"
/bin/mkdir -p "$(/usr/bin/dirname "$legacy_current_target")" || fail "could not create legacy override fixture"
printf 'current override\n' > "$legacy_current_target"
printf 'sibling override\n' > "$legacy_sibling_target"
printf 'current icon\n' > "$legacy_current_icon"
printf 'current tiff\n' > "$legacy_current_tiff"
printf 'sibling icon\n' > "$legacy_sibling_icon"

if ! /bin/bash -c '
    source "$1"
    targetDir="$2"
    Vid=30ae
    Pid=62a5
    langDisableOpt1="(1) Disable HIDPI on this monitor"
    langDisableOpt2="(2) Reset all settings to macOS default"
    langInputChoice="Enter your choice"
    langDisabled="HIDPI Disabled"
    sudo() {
        "$@"
    }
    printf "1\n" | disable
' bash "$repo_dir/hidpi.sh" "$legacy_disable_root" >/dev/null; then
    fail "legacy single-display disable should succeed in the fixture root"
fi

assert_file_absent "$legacy_current_target"
assert_file_absent "$legacy_current_icon"
assert_file_absent "$legacy_current_tiff"
assert_file_exists "$legacy_sibling_target"
assert_file_exists "$legacy_sibling_icon"

printf 'orphan icon\n' > "$legacy_current_icon"
printf 'orphan tiff\n' > "$legacy_current_tiff"
if ! /bin/bash -c '
    source "$1"
    targetDir="$2"
    Vid=30ae
    Pid=62a5
    langDisableOpt1="(1) Disable HIDPI on this monitor"
    langDisableOpt2="(2) Reset all settings to macOS default"
    langInputChoice="Enter your choice"
    langDisabled="HIDPI Disabled"
    sudo() {
        "$@"
    }
    printf "1\n" | disable
' bash "$repo_dir/hidpi.sh" "$legacy_disable_root" >/dev/null; then
    fail "legacy single-display disable should remove orphan attachments"
fi
assert_file_absent "$legacy_current_icon"
assert_file_absent "$legacy_current_tiff"

legacy_external_attachment="${legacy_disable_root}/outside-attachment"
printf 'outside attachment\n' > "$legacy_external_attachment"
/bin/ln -s "$legacy_external_attachment" "$legacy_current_icon" || fail "could not create direct-disable attachment link"
if ! /bin/bash -c '
    source "$1"
    targetDir="$2"
    Vid=30ae
    Pid=62a5
    langDisableOpt1="(1) Disable HIDPI on this monitor"
    langDisableOpt2="(2) Reset all settings to macOS default"
    langInputChoice="Enter your choice"
    langDisabled="HIDPI Disabled"
    sudo() {
        "$@"
    }
    printf "1\n" | disable
' bash "$repo_dir/hidpi.sh" "$legacy_disable_root" >/dev/null; then
    fail "legacy single-display disable should remove an attachment symbolic link"
fi
assert_file_absent "$legacy_current_icon"
assert_file_exists "$legacy_external_attachment"

if ! HOME="$legacy_restore_home" /bin/bash -c '
    source "$1"
    is_applesilicon=false
    generate_restore_cmd
' bash "$repo_dir/hidpi.sh"; then
    fail "legacy restore-script generation should succeed"
fi

legacy_restore_script="${legacy_restore_home}/.hidpi-disable"
assert_file_exists "$legacy_restore_script"
legacy_restore_contents="$(/bin/cat "$legacy_restore_script")" || fail "could not read legacy restore script"
assert_contains "$legacy_restore_contents" "rm -f \"\${restorePath}/DisplayVendorID-\${Vid}/DisplayProductID-\${Pid}\""
assert_contains "$legacy_restore_contents" "\"\${restorePath}/DisplayVendorID-\${Vid}/DisplayProductID-\${Pid}.icns\""
assert_contains "$legacy_restore_contents" "\"\${restorePath}/DisplayVendorID-\${Vid}/DisplayProductID-\${Pid}.tiff\""
assert_not_contains "$legacy_restore_contents" "rm -rf \"\${restorePath}/DisplayVendorID-\${Vid}\""

legacy_restore_run_dir="${legacy_restore_home}/Users/tester"
legacy_restore_target_dir="${legacy_restore_home}/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-30ae"
legacy_restore_target="${legacy_restore_target_dir}/DisplayProductID-62a5"
legacy_restore_icon="${legacy_restore_target}.icns"
legacy_restore_tiff="${legacy_restore_target}.tiff"
legacy_restore_sibling="${legacy_restore_target_dir}/DisplayProductID-7777"
/bin/mkdir -p "$legacy_restore_run_dir" "$legacy_restore_target_dir" || fail "could not create restore-script fixture"
printf 'restore target\n' > "$legacy_restore_target"
printf 'restore icon\n' > "$legacy_restore_icon"
printf 'restore tiff\n' > "$legacy_restore_tiff"
printf 'restore sibling\n' > "$legacy_restore_sibling"
if ! (
    cd "$legacy_restore_run_dir" || exit 1
    printf "1\n" | /bin/bash -c '
        selected_edid="$2"
        ioreg() {
            printf "    | | \\"IODisplayEDID\\" = <%s>\\n" "$selected_edid"
        }
        source "$1"
    ' bash "$legacy_restore_script" "$first_edid"
); then
    fail "generated legacy restore script should remove the selected display"
fi
assert_file_absent "$legacy_restore_target"
assert_file_absent "$legacy_restore_icon"
assert_file_absent "$legacy_restore_tiff"
assert_file_exists "$legacy_restore_sibling"

printf 'orphan restore icon\n' > "$legacy_restore_icon"
printf 'orphan restore tiff\n' > "$legacy_restore_tiff"
if ! (
    cd "$legacy_restore_run_dir" || exit 1
    printf "1\n" | /bin/bash -c '
        selected_edid="$2"
        ioreg() {
            printf "    | | \\"IODisplayEDID\\" = <%s>\\n" "$selected_edid"
        }
        source "$1"
    ' bash "$legacy_restore_script" "$first_edid"
); then
    fail "generated legacy restore script should remove orphan attachments"
fi
assert_file_absent "$legacy_restore_icon"
assert_file_absent "$legacy_restore_tiff"
assert_file_exists "$legacy_restore_sibling"

legacy_restore_external_attachment="${legacy_restore_home}/outside-attachment"
printf 'restore outside attachment\n' > "$legacy_restore_external_attachment"
/bin/ln -s "$legacy_restore_external_attachment" "$legacy_restore_icon" || fail "could not create restore attachment link"
if ! (
    cd "$legacy_restore_run_dir" || exit 1
    printf "1\n" | /bin/bash -c '
        selected_edid="$2"
        ioreg() {
            printf "    | | \\"IODisplayEDID\\" = <%s>\\n" "$selected_edid"
        }
        source "$1"
    ' bash "$legacy_restore_script" "$first_edid"
); then
    fail "generated legacy restore script should remove an attachment symbolic link"
fi
assert_file_absent "$legacy_restore_icon"
assert_file_exists "$legacy_restore_external_attachment"

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
        printf "%s\n" "$4" | start
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
            printf "    | | \\"IODisplayEDID\\" = <%s>\\n" "$remote_edid"
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
        /bin/bash -c 'source "$1"; printf "1\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
            "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
    )"; then
        fail "non-root apply selection must fail explicitly"
    fi
    assert_contains "$nonroot_output" "Run this script as root"
fi

printf 'PASS: Intel HiDPI menu\n'
