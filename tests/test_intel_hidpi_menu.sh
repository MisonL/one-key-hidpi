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

    case "$haystack" in
    *"$expected"*)
        ;;
    *)
        fail "missing expected text: ${expected}"
        ;;
    esac
}

assert_not_contains() {
    local haystack="$1"
    local unexpected="$2"

    case "$haystack" in
    *"$unexpected"*)
        fail "unexpected text: ${unexpected}"
        ;;
    *)
        ;;
    esac
}

first_edid="$(/usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p' "${fixture_dir}/ioreg-displays.txt" | /usr/bin/sed -n '1p')"
[[ -n "$first_edid" ]] || fail "could not load an EDID fixture"

menu_preview_output="$(
    langInputChoice="Enter your choice" \
    langEnterError="Enter error" \
    langIntelSafeTitle="Intel safe HiDPI" \
    langIntelSafeModePreset="(1) Compatibility preset modes" \
    langIntelSafeModeSmooth="(2) Smooth HiDPI modes" \
    langIntelSafeNearNative="Add a near-native compatibility mode?" \
    langIntelSafeNearNativeNo="(1) No" \
    langIntelSafeNearNativeYes="(2) Yes" \
    langIntelSafeSimilarResolutions="Add BetterDisplay-compatible similar resolutions?" \
    langIntelSafeSimilarResolutionsNo="(1) No" \
    langIntelSafeSimilarResolutionsYes="(2) Yes" \
    langIntelSafeApply="(1) Apply generated modes" \
    langIntelSafeRevert="(2) Revert generated modes" \
    langIntelSafeCancel="(3) Cancel" \
    langIntelSafeRoot="Run this script as root" \
    langIntelSafeApplyConfirm="Type APPLY" \
    langIntelSafeRevertConfirm="Type REVERT" \
    langIntelSafeCancelled="Cancelled" \
    langIntelSafeToolMissing="Tool is missing" \
    /bin/bash -c 'source "$1"; printf "1\\n3\\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
        "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
)" || fail "preview and cancel flow should succeed"
assert_contains "$menu_preview_output" "Intel safe HiDPI: 1920x1080"
assert_contains "$menu_preview_output" "compact: 960x540 framebuffer=1920x1080 payload="
assert_contains "$menu_preview_output" "Cancelled"

menu_smooth_preview_output="$(
    langInputChoice="Enter your choice" \
    langEnterError="Enter error" \
    langIntelSafeTitle="Intel safe HiDPI" \
    langIntelSafeModePreset="(1) Compatibility preset modes" \
    langIntelSafeModeSmooth="(2) Smooth HiDPI modes" \
    langIntelSafeNearNative="Add a near-native compatibility mode?" \
    langIntelSafeNearNativeNo="(1) No" \
    langIntelSafeNearNativeYes="(2) Yes" \
    langIntelSafeSimilarResolutions="Add BetterDisplay-compatible similar resolutions?" \
    langIntelSafeSimilarResolutionsNo="(1) No" \
    langIntelSafeSimilarResolutionsYes="(2) Yes" \
    langIntelSafeApply="(1) Apply generated modes" \
    langIntelSafeRevert="(2) Revert generated modes" \
    langIntelSafeCancel="(3) Cancel" \
    langIntelSafeRoot="Run this script as root" \
    langIntelSafeApplyConfirm="Type APPLY" \
    langIntelSafeRevertConfirm="Type REVERT" \
    langIntelSafeCancelled="Cancelled" \
    langIntelSafeToolMissing="Tool is missing" \
    /bin/bash -c 'source "$1"; printf "2\\n2\\n2\\n3\\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
        "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
)" || fail "smooth preview and cancel flow should succeed"
assert_contains "$menu_smooth_preview_output" "smooth-01: 1280x720 framebuffer=2560x1440 payload="
assert_contains "$menu_smooth_preview_output" "near-native: 1920x1079 framebuffer=3840x2158 payload="
assert_contains "$menu_smooth_preview_output" "Cancelled"

menu_definition="$(/bin/bash -c 'source "$1"; declare -f intel_safe_hidpi' bash "$menu_library")"
assert_not_contains "$menu_definition" "sudo"

menu_tool_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-menu-tool.XXXXXX")" || fail "could not create menu tool fixture"
menu_tool_path="${menu_tool_dir}/intel-hidpi.sh"
menu_tool_trace="${menu_tool_dir}/trace"

cleanup() {
    /bin/rm -rf "$menu_tool_dir"
}
trap cleanup EXIT

# shellcheck disable=SC2016
# This fixture validates menu command construction without exercising apply or revert.
printf '%s\n' \
    '#!/bin/bash' \
    'printf "%s\n" "$*" >> "$MENU_TOOL_TRACE"' \
    'case "$1" in' \
    'native-resolution)' \
    '    printf "1920x1080\n"' \
    '    ;;' \
    'preview)' \
    '    printf "preview fixture\n"' \
    '    ;;' \
    'apply)' \
    '    printf "apply fixture\n"' \
    '    ;;' \
    'revert)' \
    '    printf "revert fixture\n"' \
    '    ;;' \
    '*)' \
    '    exit 1' \
    '    ;;' \
    'esac' > "$menu_tool_path" || fail "could not write menu tool fixture"
/bin/chmod +x "$menu_tool_path" || fail "could not make menu tool fixture executable"

menu_apply_output="$(
    MENU_TOOL_TRACE="$menu_tool_trace" \
    langInputChoice="Enter your choice" \
    langEnterError="Enter error" \
    langIntelSafeTitle="Intel safe HiDPI" \
    langIntelSafeModePreset="(1) Compatibility preset modes" \
    langIntelSafeModeSmooth="(2) Smooth HiDPI modes" \
    langIntelSafeNearNative="Add a near-native compatibility mode?" \
    langIntelSafeNearNativeNo="(1) No" \
    langIntelSafeNearNativeYes="(2) Yes" \
    langIntelSafeSimilarResolutions="Add BetterDisplay-compatible similar resolutions?" \
    langIntelSafeSimilarResolutionsNo="(1) No" \
    langIntelSafeSimilarResolutionsYes="(2) Yes" \
    langIntelSafeApply="(1) Apply generated modes" \
    langIntelSafeRevert="(2) Revert generated modes" \
    langIntelSafeCancel="(3) Cancel" \
    langIntelSafeRoot="Run this script as root" \
    langIntelSafeApplyConfirm="Type APPLY" \
    langIntelSafeRevertConfirm="Type REVERT" \
    langIntelSafeCancelled="Cancelled" \
    langIntelSafeToolMissing="Tool is missing" \
    /bin/bash -c 'source "$1"; intel_safe_hidpi_has_root_privilege() { return 0; }; printf "2\\n2\\n2\\n1\\nAPPLY\\n" | intel_safe_hidpi "$2" test-edid 30ae 62a5' bash \
        "$menu_library" "$menu_tool_path"
)" || fail "smooth apply forwarding fixture should succeed"
assert_contains "$menu_apply_output" "apply fixture"
menu_tool_calls="$(/bin/cat "$menu_tool_trace")" || fail "could not read menu tool trace"
assert_contains "$menu_tool_calls" "preview --native-resolution 1920x1080 --mode-set smooth --include-near-native --include-similar-resolutions"
assert_contains "$menu_tool_calls" "apply --vendor-id 30ae --product-id 62a5 --native-resolution 1920x1080 --mode-set smooth --include-near-native --include-similar-resolutions --confirm"

: > "$menu_tool_trace"
menu_revert_output="$(
    MENU_TOOL_TRACE="$menu_tool_trace" \
    langInputChoice="Enter your choice" \
    langEnterError="Enter error" \
    langIntelSafeTitle="Intel safe HiDPI" \
    langIntelSafeModePreset="(1) Compatibility preset modes" \
    langIntelSafeModeSmooth="(2) Smooth HiDPI modes" \
    langIntelSafeNearNative="Add a near-native compatibility mode?" \
    langIntelSafeNearNativeNo="(1) No" \
    langIntelSafeNearNativeYes="(2) Yes" \
    langIntelSafeSimilarResolutions="Add BetterDisplay-compatible similar resolutions?" \
    langIntelSafeSimilarResolutionsNo="(1) No" \
    langIntelSafeSimilarResolutionsYes="(2) Yes" \
    langIntelSafeApply="(1) Apply generated modes" \
    langIntelSafeRevert="(2) Revert generated modes" \
    langIntelSafeCancel="(3) Cancel" \
    langIntelSafeRoot="Run this script as root" \
    langIntelSafeApplyConfirm="Type APPLY" \
    langIntelSafeRevertConfirm="Type REVERT" \
    langIntelSafeCancelled="Cancelled" \
    langIntelSafeToolMissing="Tool is missing" \
    /bin/bash -c 'source "$1"; intel_safe_hidpi_has_root_privilege() { return 0; }; printf "1\\n2\\nREVERT\\n" | intel_safe_hidpi "$2" test-edid 30ae 62a5' bash \
        "$menu_library" "$menu_tool_path"
)" || fail "revert forwarding fixture should succeed"
assert_contains "$menu_revert_output" "revert fixture"
menu_tool_calls="$(/bin/cat "$menu_tool_trace")" || fail "could not read revert tool trace"
assert_contains "$menu_tool_calls" "preview --native-resolution 1920x1080 --mode-set preset"
assert_contains "$menu_tool_calls" "revert --vendor-id 30ae --product-id 62a5 --confirm"
assert_not_contains "$menu_tool_calls" "apply --"

: > "$menu_tool_trace"
confirmation_cancel_output="$(
    MENU_TOOL_TRACE="$menu_tool_trace" \
    langInputChoice="Enter your choice" \
    langEnterError="Enter error" \
    langIntelSafeTitle="Intel safe HiDPI" \
    langIntelSafeModePreset="(1) Compatibility preset modes" \
    langIntelSafeModeSmooth="(2) Smooth HiDPI modes" \
    langIntelSafeNearNative="Add a near-native compatibility mode?" \
    langIntelSafeNearNativeNo="(1) No" \
    langIntelSafeNearNativeYes="(2) Yes" \
    langIntelSafeSimilarResolutions="Add BetterDisplay-compatible similar resolutions?" \
    langIntelSafeSimilarResolutionsNo="(1) No" \
    langIntelSafeSimilarResolutionsYes="(2) Yes" \
    langIntelSafeApply="(1) Apply generated modes" \
    langIntelSafeRevert="(2) Revert generated modes" \
    langIntelSafeCancel="(3) Cancel" \
    langIntelSafeRoot="Run this script as root" \
    langIntelSafeApplyConfirm="Type APPLY" \
    langIntelSafeRevertConfirm="Type REVERT" \
    langIntelSafeCancelled="Cancelled" \
    langIntelSafeToolMissing="Tool is missing" \
    /bin/bash -c 'source "$1"; intel_safe_hidpi_has_root_privilege() { return 0; }; printf "1\\n1\\nno\\n" | intel_safe_hidpi "$2" test-edid 30ae 62a5' bash \
        "$menu_library" "$menu_tool_path"
)" || fail "typed confirmation cancellation should succeed"
assert_contains "$confirmation_cancel_output" "Cancelled"
menu_tool_calls="$(/bin/cat "$menu_tool_trace")" || fail "could not read cancellation tool trace"
assert_contains "$menu_tool_calls" "preview --native-resolution 1920x1080 --mode-set preset"
assert_not_contains "$menu_tool_calls" "apply --"

if ((EUID != 0)); then
    nonroot_output=""
    if nonroot_output="$(
        langInputChoice="Enter your choice" \
        langEnterError="Enter error" \
        langIntelSafeTitle="Intel safe HiDPI" \
        langIntelSafeModePreset="(1) Compatibility preset modes" \
        langIntelSafeModeSmooth="(2) Smooth HiDPI modes" \
    langIntelSafeNearNative="Add a near-native compatibility mode?" \
    langIntelSafeNearNativeNo="(1) No" \
    langIntelSafeNearNativeYes="(2) Yes" \
    langIntelSafeSimilarResolutions="Add BetterDisplay-compatible similar resolutions?" \
    langIntelSafeSimilarResolutionsNo="(1) No" \
    langIntelSafeSimilarResolutionsYes="(2) Yes" \
        langIntelSafeApply="(1) Apply generated modes" \
        langIntelSafeRevert="(2) Revert generated modes" \
        langIntelSafeCancel="(3) Cancel" \
        langIntelSafeRoot="Run this script as root" \
        langIntelSafeApplyConfirm="Type APPLY" \
        langIntelSafeRevertConfirm="Type REVERT" \
        langIntelSafeCancelled="Cancelled" \
        langIntelSafeToolMissing="Tool is missing" \
        /bin/bash -c 'source "$1"; printf "1\\n1\\n" | intel_safe_hidpi "$2" "$3" "$4" "$5"' bash \
            "$menu_library" "$tool_path" "$first_edid" 30ae 62a5
    )"; then
        fail "non-root apply selection must fail explicitly"
    fi
    assert_contains "$nonroot_output" "Run this script as root"
fi

printf 'PASS: Intel HiDPI menu\n'
