#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="${repo_dir}/tests/fixtures"

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

assert_file_contents() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$(/bin/cat "$path")" || fail "could not read ${path}"
    [[ "$actual" == "$expected" ]] || fail "expected ${path} contents to remain unchanged"
}

assert_file_exists() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_plist_key_present() {
    local path="$1"
    local key_path="$2"

    /usr/bin/plutil -extract "$key_path" raw -o - "$path" >/dev/null 2>&1 || fail "expected plist key: ${key_path}"
}

assert_plist_key_absent() {
    local path="$1"
    local key_path="$2"

    if /usr/bin/plutil -extract "$key_path" raw -o - "$path" >/dev/null 2>&1; then
        fail "unexpected plist key: ${key_path}"
    fi
}

assert_directory_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected directory: $1"
}

assert_directory_empty() {
    local path="$1"
    local first_entry

    [[ -d "$path" && ! -L "$path" ]] || fail "expected directory: $path"
    first_entry="$(/usr/bin/find "$path" -mindepth 1 -maxdepth 1 -print -quit)" || fail "could not inspect directory: ${path}"
    [[ -z "$first_entry" ]] || fail "expected an empty directory: ${path}"
}

assert_executable_file() {
    [[ -f "$1" && -x "$1" ]] || fail "expected executable file: $1"
}

create_icons_plist_fixture() {
    local path="$1"

    /usr/bin/plutil -create xml1 "$path" || fail "could not create Icons.plist fixture"
    /usr/libexec/PlistBuddy -c 'Add :vendors dict' "$path" || fail "could not add Icons.plist vendors"
    /usr/libexec/PlistBuddy -c 'Add :vendors:30ae dict' "$path" || fail "could not add Icons.plist vendor"
    /usr/libexec/PlistBuddy -c 'Add :vendors:30ae:products dict' "$path" || fail "could not add Icons.plist products"
    /usr/libexec/PlistBuddy -c 'Add :vendors:30ae:products:62a5 dict' "$path" || fail "could not add current Icons.plist product"
    /usr/libexec/PlistBuddy -c 'Add :vendors:30ae:products:7777 string sibling' "$path" || fail "could not add sibling Icons.plist product"
}

run_direct_disable() {
    local target_dir="$1"

    /bin/bash -c '
        source "$1" >/dev/null
        targetDir="$2"
        Vid=30ae
        Pid=62a5
        langDisableOpt1="(1) Disable HIDPI on this monitor"
        langDisableOpt2="(2) Reset all settings to macOS default"
        langInputChoice="Enter your choice"
        langDisabled="HIDPI Disabled"
        langUnsafeVendorPath="Unsafe vendor path"
        sudo() {
            "$@"
        }
        printf "1\\n" | disable
    ' bash "$repo_dir/hidpi.sh" "$target_dir"
}

generate_restore_script() {
    local home_dir="$1"

    HOME="$home_dir" /bin/bash -c '
        source "$1" >/dev/null
        is_applesilicon=false
        generate_restore_cmd
    ' bash "$repo_dir/hidpi.sh"
}

run_restore_script() {
    local restore_script="$1"
    local run_dir="$2"
    local edid="$3"

    (
        cd "$run_dir" || exit 1
        printf "1\n" | /bin/bash -c '
            selected_edid="$2"
            ioreg() {
                printf "    | | \\\"IODisplayEDID\\\" = <%s>\\n" "$selected_edid"
            }
            source "$1"
        ' bash "$restore_script" "$edid"
    )
}

first_edid="$(/usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p' "${fixture_dir}/ioreg-displays.txt" | /usr/bin/sed -n '1p')"
[[ -n "$first_edid" ]] || fail "could not load an EDID fixture"

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-legacy-cleanup.XXXXXX")" || fail "could not create scratch directory"

cleanup() {
    /bin/rm -rf "$scratch_dir"
}
trap cleanup EXIT

direct_root="${scratch_dir}/direct"
direct_target="${direct_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
direct_sibling="${direct_root}/DisplayVendorID-30ae/DisplayProductID-7777"
direct_icon="${direct_target}.icns"
direct_tiff="${direct_target}.tiff"
/bin/mkdir -p "$(/usr/bin/dirname "$direct_target")" || fail "could not create direct cleanup fixture"
printf 'current override\n' > "$direct_target"
printf 'sibling override\n' > "$direct_sibling"
printf 'current icon\n' > "$direct_icon"
printf 'current tiff\n' > "$direct_tiff"
run_direct_disable "$direct_root" >/dev/null || fail "legacy single-display disable should succeed"
assert_file_absent "$direct_target"
assert_file_absent "$direct_icon"
assert_file_absent "$direct_tiff"
assert_file_exists "$direct_sibling"

printf 'orphan icon\n' > "$direct_icon"
printf 'orphan tiff\n' > "$direct_tiff"
run_direct_disable "$direct_root" >/dev/null || fail "legacy disable should remove orphan attachments"
assert_file_absent "$direct_icon"
assert_file_absent "$direct_tiff"

direct_external_attachment="${direct_root}/outside-attachment"
printf 'outside attachment\n' > "$direct_external_attachment"
/bin/ln -s "$direct_external_attachment" "$direct_icon" || fail "could not create attachment link"
run_direct_disable "$direct_root" >/dev/null || fail "legacy disable should remove an attachment link"
assert_file_absent "$direct_icon"
assert_file_exists "$direct_external_attachment"

direct_icons_root="${scratch_dir}/direct-icons"
direct_icons_path="${direct_icons_root}/Icons.plist"
/bin/mkdir -p "$direct_icons_root" || fail "could not create direct Icons.plist root"
create_icons_plist_fixture "$direct_icons_path"
run_direct_disable "$direct_icons_root" >/dev/null || fail "legacy disable should remove its Icons.plist product entry"
assert_plist_key_absent "$direct_icons_path" vendors.30ae.products.62a5
assert_plist_key_present "$direct_icons_path" vendors.30ae.products.7777

direct_icons_missing_root="${scratch_dir}/direct-icons-missing"
direct_icons_missing_path="${direct_icons_missing_root}/Icons.plist"
/bin/mkdir -p "$direct_icons_missing_root" || fail "could not create missing-key Icons.plist root"
create_icons_plist_fixture "$direct_icons_missing_path"
/usr/bin/plutil -remove vendors.30ae.products.62a5 "$direct_icons_missing_path" || fail "could not remove missing-key fixture entry"
run_direct_disable "$direct_icons_missing_root" >/dev/null || fail "legacy disable should accept a valid Icons.plist with no matching entry"
assert_plist_key_present "$direct_icons_missing_path" vendors.30ae.products.7777

direct_icons_invalid_root="${scratch_dir}/direct-icons-invalid"
direct_icons_invalid_path="${direct_icons_invalid_root}/Icons.plist"
/bin/mkdir -p "$direct_icons_invalid_root" || fail "could not create invalid Icons.plist root"
printf 'not a plist\n' > "$direct_icons_invalid_path"
direct_icons_invalid_output=""
if direct_icons_invalid_output="$(run_direct_disable "$direct_icons_invalid_root" 2>&1)"; then
    fail "legacy disable must reject an invalid Icons.plist"
fi
assert_contains "$direct_icons_invalid_output" "Unsafe vendor path"
assert_file_contents "$direct_icons_invalid_path" "not a plist"

direct_icons_link_root="${scratch_dir}/direct-icons-link"
direct_icons_link_path="${direct_icons_link_root}/Icons.plist"
direct_icons_link_outside="${direct_icons_link_root}/outside.plist"
/bin/mkdir -p "$direct_icons_link_root" || fail "could not create linked Icons.plist root"
create_icons_plist_fixture "$direct_icons_link_outside"
/bin/ln -s "$direct_icons_link_outside" "$direct_icons_link_path" || fail "could not create linked Icons.plist"
direct_icons_link_output=""
if direct_icons_link_output="$(run_direct_disable "$direct_icons_link_root" 2>&1)"; then
    fail "legacy disable must reject a symbolic-link Icons.plist"
fi
assert_contains "$direct_icons_link_output" "Unsafe vendor path"
assert_plist_key_present "$direct_icons_link_outside" vendors.30ae.products.62a5
[[ -L "$direct_icons_link_path" ]] || fail "legacy disable must preserve the Icons.plist link"

direct_icons_hardlink_root="${scratch_dir}/direct-icons-hardlink"
direct_icons_hardlink_path="${direct_icons_hardlink_root}/Icons.plist"
direct_icons_hardlink_outside="${direct_icons_hardlink_root}/outside.plist"
/bin/mkdir -p "$direct_icons_hardlink_root" || fail "could not create hard-linked Icons.plist root"
create_icons_plist_fixture "$direct_icons_hardlink_path"
/bin/ln "$direct_icons_hardlink_path" "$direct_icons_hardlink_outside" || fail "could not create hard-linked Icons.plist alias"
direct_icons_hardlink_output=""
if direct_icons_hardlink_output="$(run_direct_disable "$direct_icons_hardlink_root" 2>&1)"; then
    fail "legacy disable must reject a hard-linked Icons.plist"
fi
assert_contains "$direct_icons_hardlink_output" "Unsafe vendor path"
assert_plist_key_present "$direct_icons_hardlink_path" vendors.30ae.products.62a5
assert_plist_key_present "$direct_icons_hardlink_outside" vendors.30ae.products.62a5

direct_icons_race_root="${scratch_dir}/direct-icons-race"
direct_icons_race_path="${direct_icons_race_root}/Icons.plist"
direct_icons_race_outside="${direct_icons_race_root}/outside.plist"
/bin/mkdir -p "$direct_icons_race_root" || fail "could not create raced Icons.plist root"
create_icons_plist_fixture "$direct_icons_race_path"
create_icons_plist_fixture "$direct_icons_race_outside"
if /bin/bash -c '
    source "$1" >/dev/null
    targetDir="$2"
    race_icons_path="$3"
    race_outside_path="$4"
    Vid=30ae
    Pid=62a5
    langDisableOpt1="(1) Disable HIDPI on this monitor"
    langDisableOpt2="(2) Reset all settings to macOS default"
    langInputChoice="Enter your choice"
    langDisabled="HIDPI Disabled"
    langUnsafeVendorPath="Unsafe vendor path"
    sudo() {
        "$@"
    }
    race_armed=true
    set -o functrace
    race_before_icon_cleanup() {
        case "$BASH_COMMAND" in
        "legacy_remove_icon_product_entry true "*)
            if [[ "$race_armed" == true ]]; then
                race_armed=false
                trap - DEBUG
                /bin/rm -f "$race_icons_path" || return 1
                /bin/ln -s "$race_outside_path" "$race_icons_path" || return 1
            fi
            ;;
        esac
    }
    trap race_before_icon_cleanup DEBUG
    printf "1\\n" | disable
' bash "$repo_dir/hidpi.sh" "$direct_icons_race_root" "$direct_icons_race_path" "$direct_icons_race_outside" >/dev/null 2>&1; then
    fail "legacy disable must reject a concurrently replaced Icons.plist"
fi
assert_plist_key_present "$direct_icons_race_outside" vendors.30ae.products.62a5
[[ -L "$direct_icons_race_path" ]] || fail "legacy disable must preserve the raced Icons.plist link"

direct_empty_root="${scratch_dir}/direct-empty"
direct_empty_vendor="${direct_empty_root}/DisplayVendorID-30ae"
/bin/mkdir -p "$direct_empty_vendor" || fail "could not create empty vendor fixture"
printf 'empty vendor target\n' > "${direct_empty_vendor}/DisplayProductID-62a5"
run_direct_disable "$direct_empty_root" >/dev/null || fail "legacy disable should clean a selected entry from an empty vendor directory"
assert_directory_empty "$direct_empty_vendor"

direct_unsafe_root="${scratch_dir}/direct-unsafe"
direct_unsafe_vendor="${direct_unsafe_root}/DisplayVendorID-30ae"
direct_unsafe_outside="${direct_unsafe_root}/outside"
direct_unsafe_target="${direct_unsafe_outside}/DisplayProductID-62a5"
/bin/mkdir -p "$direct_unsafe_outside" || fail "could not create unsafe vendor fixture"
printf 'external vendor target\n' > "$direct_unsafe_target"
/bin/ln -s "$direct_unsafe_outside" "$direct_unsafe_vendor" || fail "could not create unsafe vendor link"
direct_unsafe_output=""
if direct_unsafe_output="$(run_direct_disable "$direct_unsafe_root" 2>&1)"; then
    fail "legacy disable must reject a symbolic-link vendor directory"
fi
assert_contains "$direct_unsafe_output" "Unsafe vendor path"
assert_file_contents "$direct_unsafe_target" "external vendor target"
[[ -L "$direct_unsafe_vendor" ]] || fail "legacy disable must preserve the unsafe vendor link"

direct_preflight_root="${scratch_dir}/direct-preflight"
direct_preflight_vendor="${direct_preflight_root}/DisplayVendorID-30ae"
direct_preflight_outside="${direct_preflight_root}/outside"
direct_preflight_target="${direct_preflight_outside}/DisplayProductID-62a5"
direct_preflight_icons="${direct_preflight_root}/Icons.plist"
/bin/mkdir -p "$direct_preflight_outside" || fail "could not create direct preflight fixture"
printf 'direct preflight external target\n' > "$direct_preflight_target"
create_icons_plist_fixture "$direct_preflight_icons"
/bin/ln -s "$direct_preflight_outside" "$direct_preflight_vendor" || fail "could not create direct preflight vendor link"
direct_preflight_output=""
if direct_preflight_output="$(run_direct_disable "$direct_preflight_root" 2>&1)"; then
    fail "legacy disable must preflight a symbolic-link vendor before changing Icons.plist"
fi
assert_contains "$direct_preflight_output" "Unsafe vendor path"
assert_plist_key_present "$direct_preflight_icons" vendors.30ae.products.62a5
assert_plist_key_present "$direct_preflight_icons" vendors.30ae.products.7777
assert_file_contents "$direct_preflight_target" "direct preflight external target"
[[ -L "$direct_preflight_vendor" ]] || fail "legacy disable must preserve a preflight-rejected vendor link"

direct_missing_root="${scratch_dir}/direct-missing"
run_direct_disable "$direct_missing_root" >/dev/null || fail "legacy disable should allow an absent override root as a no-op"
assert_directory_absent "$direct_missing_root"

direct_file_root="${scratch_dir}/direct-file"
direct_file_vendor="${direct_file_root}/DisplayVendorID-30ae"
/bin/mkdir -p "$direct_file_root" || fail "could not create non-directory vendor root"
printf 'not a directory\n' > "$direct_file_vendor"
direct_file_output=""
if direct_file_output="$(run_direct_disable "$direct_file_root" 2>&1)"; then
    fail "legacy disable must reject a non-directory vendor path"
fi
assert_contains "$direct_file_output" "Unsafe vendor path"
assert_file_contents "$direct_file_vendor" "not a directory"

direct_vendor_race_root="${scratch_dir}/direct-vendor-race"
direct_vendor_race_vendor="${direct_vendor_race_root}/DisplayVendorID-30ae"
direct_vendor_race_outside="${direct_vendor_race_root}/outside"
direct_vendor_race_target="${direct_vendor_race_outside}/DisplayProductID-62a5"
/bin/mkdir -p "$direct_vendor_race_vendor" "$direct_vendor_race_outside" || fail "could not create vendor race fixture"
printf 'direct race target\n' > "${direct_vendor_race_vendor}/DisplayProductID-62a5"
printf 'direct external target\n' > "$direct_vendor_race_target"
direct_vendor_race_output=""
if direct_vendor_race_output="$(/bin/bash -c '
    source "$1" >/dev/null
    targetDir="$2"
    race_vendor="$3"
    race_outside="$4"
    Vid=30ae
    Pid=62a5
    langDisableOpt1="(1) Disable HIDPI on this monitor"
    langDisableOpt2="(2) Reset all settings to macOS default"
    langInputChoice="Enter your choice"
    langDisabled="HIDPI Disabled"
    langUnsafeVendorPath="Unsafe vendor path"
    sudo() {
        "$@"
    }
    race_armed=true
    set -o functrace
    race_before_vendor_cleanup() {
        case "$BASH_COMMAND" in
        "legacy_remove_vendor_entries true "*)
            if [[ "$race_armed" == true ]]; then
                race_armed=false
                trap - DEBUG
                /bin/rm -rf "$race_vendor" || return 1
                /bin/ln -s "$race_outside" "$race_vendor" || return 1
            fi
            ;;
        esac
    }
    trap race_before_vendor_cleanup DEBUG
    printf "1\\n" | disable
' bash "$repo_dir/hidpi.sh" "$direct_vendor_race_root" "$direct_vendor_race_vendor" "$direct_vendor_race_outside" 2>&1)"; then
    fail "legacy disable must reject a vendor path replaced after validation"
fi
assert_contains "$direct_vendor_race_output" "Unsafe vendor path"
assert_file_contents "$direct_vendor_race_target" "direct external target"
[[ -L "$direct_vendor_race_vendor" ]] || fail "legacy disable must preserve the raced vendor link"

if /bin/bash -c '
    source "$1" >/dev/null
    unsafe_root="$2"
    is_applesilicon=false
    select_display() {
        Vid=30ae
        Pid=62a5
    }
    init() {
        targetDir="$unsafe_root"
    }
    langDisableOpt1="(1) Disable HIDPI on this monitor"
    langDisableOpt2="(2) Reset all settings to macOS default"
    langInputChoice="Enter your choice"
    langDisabled="HIDPI Disabled"
    langUnsafeVendorPath="Unsafe vendor path"
    sudo() {
        "$@"
    }
    printf "3\\n1\\n" | start
' bash "$repo_dir/hidpi.sh" "$direct_unsafe_root" >/dev/null 2>&1; then
    fail "legacy menu must propagate an unsafe vendor failure"
fi
assert_file_contents "$direct_unsafe_target" "external vendor target"

restore_home="${scratch_dir}/restore"
/bin/mkdir -p "$restore_home" || fail "could not create restore home"
generate_restore_script "$restore_home" || fail "legacy restore-script generation should succeed"
restore_script="${restore_home}/.hidpi-disable"
assert_executable_file "$restore_script"
restore_contents="$(/bin/cat "$restore_script")" || fail "could not read restore script"
assert_contains "$restore_contents" "#!/bin/bash"
assert_contains "$restore_contents" "legacy_remove_icon_product_entry ()"
assert_contains "$restore_contents" "legacy_remove_vendor_entries ()"
assert_contains "$restore_contents" "O_NOFOLLOW"
assert_contains "$restore_contents" "\"/dev/fd/\$icons_fd\""
assert_contains "$restore_contents" "plutil\", \"-lint\""
assert_not_contains "$restore_contents" "\$(declare -f"

missing_restore_home="${scratch_dir}/missing-restore-home"
missing_restore_home_output=""
if missing_restore_home_output="$(HOME="$missing_restore_home" /bin/bash -c '
    source "$1" >/dev/null
    is_applesilicon=false
    generate_restore_cmd
' bash "$repo_dir/hidpi.sh" 2>&1)"; then
    fail "restore-script generation must reject a missing home directory"
fi
assert_contains "$missing_restore_home_output" "Cannot create the restore script in the home directory."
assert_file_absent "${missing_restore_home}/.hidpi-disable"

unset_restore_home_output=""
# shellcheck disable=SC2016
if unset_restore_home_output="$(env -u HOME /bin/bash -c '
    source "$1" >/dev/null
    is_applesilicon=false
    generate_restore_cmd
' bash "$repo_dir/hidpi.sh" 2>&1)"; then
    fail "restore-script generation must reject an unset home directory"
fi
assert_contains "$unset_restore_home_output" "Cannot create the restore script in the home directory."

init_failure_trace="${scratch_dir}/init-failure-trace"
missing_init_home="${scratch_dir}/missing-init-home"
init_failure_output=""
if init_failure_output="$(HOME="$missing_init_home" /bin/bash -c '
    source "$1" >/dev/null
    trace_path="$2"
    rm() {
        printf "rm\n" >> "$trace_path"
    }
    mkdir() {
        printf "mkdir\n" >> "$trace_path"
    }
    sudo() {
        printf "sudo\n" >> "$trace_path"
    }
    init
' bash "$repo_dir/hidpi.sh" "$init_failure_trace" 2>&1)"; then
    fail "initialization must reject a missing home directory"
fi
assert_contains "$init_failure_output" "Cannot create the restore script in the home directory."
assert_file_absent "$init_failure_trace"

restore_run_dir="${restore_home}/Users/tester"
restore_target_dir="${restore_home}/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-30ae"
restore_target="${restore_target_dir}/DisplayProductID-62a5"
restore_icon="${restore_target}.icns"
restore_tiff="${restore_target}.tiff"
restore_sibling="${restore_target_dir}/DisplayProductID-7777"
/bin/mkdir -p "$restore_run_dir" "$restore_target_dir" || fail "could not create restore fixture"
printf 'restore target\n' > "$restore_target"
printf 'restore icon\n' > "$restore_icon"
printf 'restore tiff\n' > "$restore_tiff"
printf 'restore sibling\n' > "$restore_sibling"
run_restore_script "$restore_script" "$restore_run_dir" "$first_edid" >/dev/null || fail "generated restore script should remove the selected display"
assert_file_absent "$restore_target"
assert_file_absent "$restore_icon"
assert_file_absent "$restore_tiff"
assert_file_exists "$restore_sibling"

printf 'orphan restore icon\n' > "$restore_icon"
printf 'orphan restore tiff\n' > "$restore_tiff"
run_restore_script "$restore_script" "$restore_run_dir" "$first_edid" >/dev/null || fail "generated restore script should remove orphan attachments"
assert_file_absent "$restore_icon"
assert_file_absent "$restore_tiff"

restore_external_attachment="${restore_home}/outside-attachment"
printf 'restore outside attachment\n' > "$restore_external_attachment"
/bin/ln -s "$restore_external_attachment" "$restore_icon" || fail "could not create restore attachment link"
run_restore_script "$restore_script" "$restore_run_dir" "$first_edid" >/dev/null || fail "generated restore script should remove an attachment link"
assert_file_absent "$restore_icon"
assert_file_exists "$restore_external_attachment"

restore_icons_path="${restore_home}/Library/Displays/Contents/Resources/Overrides/Icons.plist"
create_icons_plist_fixture "$restore_icons_path"
run_restore_script "$restore_script" "$restore_run_dir" "$first_edid" >/dev/null || fail "generated restore script should remove its Icons.plist product entry"
assert_plist_key_absent "$restore_icons_path" vendors.30ae.products.62a5
assert_plist_key_present "$restore_icons_path" vendors.30ae.products.7777

restore_icons_hardlink_home="${scratch_dir}/restore-icons-hardlink"
restore_icons_hardlink_run_dir="${restore_icons_hardlink_home}/Users/tester"
restore_icons_hardlink_path="${restore_icons_hardlink_home}/Library/Displays/Contents/Resources/Overrides/Icons.plist"
restore_icons_hardlink_outside="${restore_icons_hardlink_home}/outside.plist"
/bin/mkdir -p "$restore_icons_hardlink_run_dir" "$(/usr/bin/dirname "$restore_icons_hardlink_path")" || fail "could not create hard-linked restore Icons.plist root"
generate_restore_script "$restore_icons_hardlink_home" || fail "hard-linked restore-script generation should succeed"
create_icons_plist_fixture "$restore_icons_hardlink_path"
/bin/ln "$restore_icons_hardlink_path" "$restore_icons_hardlink_outside" || fail "could not create hard-linked restore Icons.plist alias"
restore_icons_hardlink_output=""
if restore_icons_hardlink_output="$(run_restore_script "${restore_icons_hardlink_home}/.hidpi-disable" "$restore_icons_hardlink_run_dir" "$first_edid" 2>&1)"; then
    fail "generated restore script must reject a hard-linked Icons.plist"
fi
assert_contains "$restore_icons_hardlink_output" "Unsafe vendor override path"
assert_plist_key_present "$restore_icons_hardlink_path" vendors.30ae.products.62a5
assert_plist_key_present "$restore_icons_hardlink_outside" vendors.30ae.products.62a5

restore_invalid_home="${scratch_dir}/restore-invalid"
restore_invalid_run_dir="${restore_invalid_home}/Users/tester"
restore_invalid_root="${restore_invalid_home}/Library/Displays/Contents/Resources/Overrides"
/bin/mkdir -p "$restore_invalid_run_dir" "$restore_invalid_root" || fail "could not create invalid restore fixture"
generate_restore_script "$restore_invalid_home" || fail "invalid restore-script generation should succeed"
printf 'not a plist\n' > "${restore_invalid_root}/Icons.plist"
restore_invalid_output=""
if restore_invalid_output="$(run_restore_script "${restore_invalid_home}/.hidpi-disable" "$restore_invalid_run_dir" "$first_edid" 2>&1)"; then
    fail "generated restore script must reject an invalid Icons.plist"
fi
assert_contains "$restore_invalid_output" "Unsafe vendor override path"
assert_file_contents "${restore_invalid_root}/Icons.plist" "not a plist"

restore_icons_link_home="${scratch_dir}/restore-icons-link"
restore_icons_link_run_dir="${restore_icons_link_home}/Users/tester"
restore_icons_link_root="${restore_icons_link_home}/Library/Displays/Contents/Resources/Overrides"
restore_icons_link_path="${restore_icons_link_root}/Icons.plist"
restore_icons_link_outside="${restore_icons_link_home}/outside.plist"
/bin/mkdir -p "$restore_icons_link_run_dir" "$restore_icons_link_root" || fail "could not create linked restore fixture"
generate_restore_script "$restore_icons_link_home" || fail "linked restore-script generation should succeed"
create_icons_plist_fixture "$restore_icons_link_outside"
/bin/ln -s "$restore_icons_link_outside" "$restore_icons_link_path" || fail "could not create linked restore Icons.plist"
restore_icons_link_output=""
if restore_icons_link_output="$(run_restore_script "${restore_icons_link_home}/.hidpi-disable" "$restore_icons_link_run_dir" "$first_edid" 2>&1)"; then
    fail "generated restore script must reject a symbolic-link Icons.plist"
fi
assert_contains "$restore_icons_link_output" "Unsafe vendor override path"
assert_plist_key_present "$restore_icons_link_outside" vendors.30ae.products.62a5
[[ -L "$restore_icons_link_path" ]] || fail "generated restore script must preserve the Icons.plist link"

restore_icons_race_home="${scratch_dir}/restore-icons-race"
restore_icons_race_run_dir="${restore_icons_race_home}/Users/tester"
restore_icons_race_root="${restore_icons_race_home}/Library/Displays/Contents/Resources/Overrides"
restore_icons_race_path="${restore_icons_race_root}/Icons.plist"
restore_icons_race_outside="${restore_icons_race_home}/outside.plist"
/bin/mkdir -p "$restore_icons_race_run_dir" "$restore_icons_race_root" || fail "could not create raced restore fixture"
generate_restore_script "$restore_icons_race_home" || fail "raced restore-script generation should succeed"
create_icons_plist_fixture "$restore_icons_race_path"
create_icons_plist_fixture "$restore_icons_race_outside"
restore_icons_race_output=""
if restore_icons_race_output="$(
    cd "$restore_icons_race_run_dir" || exit 1
    printf "1\n" | /bin/bash -c '
        selected_edid="$2"
        race_icons_path="$3"
        race_outside_path="$4"
        ioreg() {
            printf "    | | \\\"IODisplayEDID\\\" = <%s>\\n" "$selected_edid"
        }
        race_armed=true
        set -o functrace
        race_before_icon_cleanup() {
            case "$BASH_COMMAND" in
            "legacy_remove_icon_product_entry false "*)
                if [[ "$race_armed" == true ]]; then
                    race_armed=false
                    trap - DEBUG
                    /bin/rm -f "$race_icons_path" || return 1
                    /bin/ln -s "$race_outside_path" "$race_icons_path" || return 1
                fi
                ;;
            esac
        }
        trap race_before_icon_cleanup DEBUG
        source "$1"
    ' bash "${restore_icons_race_home}/.hidpi-disable" "$first_edid" "$restore_icons_race_path" "$restore_icons_race_outside" 2>&1
)"; then
    fail "generated restore script must reject a concurrently replaced Icons.plist"
fi
assert_contains "$restore_icons_race_output" "Unsafe vendor override path"
assert_plist_key_present "$restore_icons_race_outside" vendors.30ae.products.62a5
[[ -L "$restore_icons_race_path" ]] || fail "generated restore script must preserve the raced Icons.plist link"

restore_empty_home="${scratch_dir}/restore-empty"
restore_empty_run_dir="${restore_empty_home}/Users/tester"
restore_empty_vendor="${restore_empty_home}/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-30ae"
/bin/mkdir -p "$restore_empty_run_dir" "$restore_empty_vendor" || fail "could not create empty restore fixture"
generate_restore_script "$restore_empty_home" || fail "empty restore-script generation should succeed"
printf 'empty restore target\n' > "${restore_empty_vendor}/DisplayProductID-62a5"
run_restore_script "${restore_empty_home}/.hidpi-disable" "$restore_empty_run_dir" "$first_edid" >/dev/null || fail "generated restore script should clean a selected entry from an empty vendor directory"
assert_directory_empty "$restore_empty_vendor"

restore_unsafe_home="${scratch_dir}/restore-unsafe"
restore_unsafe_run_dir="${restore_unsafe_home}/Users/tester"
restore_unsafe_parent="${restore_unsafe_home}/Library/Displays/Contents/Resources/Overrides"
restore_unsafe_vendor="${restore_unsafe_parent}/DisplayVendorID-30ae"
restore_unsafe_outside="${restore_unsafe_home}/outside"
restore_unsafe_target="${restore_unsafe_outside}/DisplayProductID-62a5"
/bin/mkdir -p "$restore_unsafe_run_dir" "$restore_unsafe_parent" "$restore_unsafe_outside" || fail "could not create unsafe restore fixture"
generate_restore_script "$restore_unsafe_home" || fail "unsafe restore-script generation should succeed"
printf 'external restore target\n' > "$restore_unsafe_target"
/bin/ln -s "$restore_unsafe_outside" "$restore_unsafe_vendor" || fail "could not create unsafe restore vendor link"
restore_unsafe_output=""
if restore_unsafe_output="$(run_restore_script "${restore_unsafe_home}/.hidpi-disable" "$restore_unsafe_run_dir" "$first_edid" 2>&1)"; then
    fail "generated restore script must reject a symbolic-link vendor directory"
fi
assert_contains "$restore_unsafe_output" "Unsafe vendor override path"
assert_file_contents "$restore_unsafe_target" "external restore target"
[[ -L "$restore_unsafe_vendor" ]] || fail "generated restore script must preserve the unsafe vendor link"

restore_preflight_home="${scratch_dir}/restore-preflight"
restore_preflight_run_dir="${restore_preflight_home}/Users/tester"
restore_preflight_root="${restore_preflight_home}/Library/Displays/Contents/Resources/Overrides"
restore_preflight_vendor="${restore_preflight_root}/DisplayVendorID-30ae"
restore_preflight_outside="${restore_preflight_home}/outside"
restore_preflight_target="${restore_preflight_outside}/DisplayProductID-62a5"
restore_preflight_icons="${restore_preflight_root}/Icons.plist"
/bin/mkdir -p "$restore_preflight_run_dir" "$restore_preflight_root" "$restore_preflight_outside" || fail "could not create restore preflight fixture"
generate_restore_script "$restore_preflight_home" || fail "restore preflight generation should succeed"
printf 'restore preflight external target\n' > "$restore_preflight_target"
create_icons_plist_fixture "$restore_preflight_icons"
/bin/ln -s "$restore_preflight_outside" "$restore_preflight_vendor" || fail "could not create restore preflight vendor link"
restore_preflight_output=""
if restore_preflight_output="$(run_restore_script "${restore_preflight_home}/.hidpi-disable" "$restore_preflight_run_dir" "$first_edid" 2>&1)"; then
    fail "generated restore script must preflight a symbolic-link vendor before changing Icons.plist"
fi
assert_contains "$restore_preflight_output" "Unsafe vendor override path"
assert_plist_key_present "$restore_preflight_icons" vendors.30ae.products.62a5
assert_plist_key_present "$restore_preflight_icons" vendors.30ae.products.7777
assert_file_contents "$restore_preflight_target" "restore preflight external target"
[[ -L "$restore_preflight_vendor" ]] || fail "generated restore script must preserve a preflight-rejected vendor link"

restore_vendor_race_home="${scratch_dir}/restore-vendor-race"
restore_vendor_race_run_dir="${restore_vendor_race_home}/Users/tester"
restore_vendor_race_vendor="${restore_vendor_race_home}/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-30ae"
restore_vendor_race_outside="${restore_vendor_race_home}/outside"
restore_vendor_race_target="${restore_vendor_race_outside}/DisplayProductID-62a5"
/bin/mkdir -p "$restore_vendor_race_run_dir" "$restore_vendor_race_vendor" "$restore_vendor_race_outside" || fail "could not create restore vendor race fixture"
generate_restore_script "$restore_vendor_race_home" || fail "restore vendor race generation should succeed"
printf 'restore race target\n' > "${restore_vendor_race_vendor}/DisplayProductID-62a5"
printf 'restore external target\n' > "$restore_vendor_race_target"
restore_vendor_race_output=""
if restore_vendor_race_output="$(
    cd "$restore_vendor_race_run_dir" || exit 1
    printf "1\n" | /bin/bash -c '
        selected_edid="$2"
        race_vendor="$3"
        race_outside="$4"
        ioreg() {
            printf "    | | \\\"IODisplayEDID\\\" = <%s>\\n" "$selected_edid"
        }
        race_armed=true
        set -o functrace
        race_before_vendor_cleanup() {
            case "$BASH_COMMAND" in
            "legacy_remove_vendor_entries false "*)
                if [[ "$race_armed" == true ]]; then
                    race_armed=false
                    trap - DEBUG
                    /bin/rm -rf "$race_vendor" || return 1
                    /bin/ln -s "$race_outside" "$race_vendor" || return 1
                fi
                ;;
            esac
        }
        trap race_before_vendor_cleanup DEBUG
        source "$1"
    ' bash "${restore_vendor_race_home}/.hidpi-disable" "$first_edid" "$restore_vendor_race_vendor" "$restore_vendor_race_outside" 2>&1
)"; then
    fail "generated restore script must reject a vendor path replaced after validation"
fi
assert_contains "$restore_vendor_race_output" "Unsafe vendor override path"
assert_file_contents "$restore_vendor_race_target" "restore external target"
[[ -L "$restore_vendor_race_vendor" ]] || fail "generated restore script must preserve the raced vendor link"

printf 'PASS: legacy HiDPI cleanup\n'
