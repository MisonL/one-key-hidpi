#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-smooth-apply-verify.XXXXXX")"
overrides_root="${scratch_dir}/overrides"
state_root="${scratch_dir}/state"
target_path="${overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
manifest_path="${state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/manifest.plist"
original_path="${scratch_dir}/original.plist"
full_modes_path="${scratch_dir}/full-modes.txt"
partial_modes_path="${scratch_dir}/partial-modes.txt"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local expected="$2"

    if ! printf '%s\n' "$haystack" | /usr/bin/grep -Fqx "$expected"; then
        fail "missing expected line: ${expected}"
    fi
}

assert_plist_value() {
    local plist_path="$1"
    local key_path="$2"
    local expected="$3"
    local actual

    actual="$(/usr/bin/plutil -extract "$key_path" raw -o - "$plist_path")" || fail "missing ${key_path} in ${plist_path}"
    [[ "$actual" == "$expected" ]] || fail "expected ${key_path}=${expected}, got ${actual}"
}

assert_file_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected file: $1"
}

cleanup() {
    /bin/rm -rf "$scratch_dir"
}

trap cleanup EXIT

/bin/mkdir -p "$(/usr/bin/dirname "$target_path")" || fail "could not create smooth override fixture"
/usr/bin/plutil -create xml1 "$target_path" || fail "could not create smooth override fixture"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$target_path" || fail "could not write fixture vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$target_path" || fail "could not write fixture product id"
/usr/bin/plutil -insert custom-metadata -string preserve-me "$target_path" || fail "could not write fixture metadata"
/usr/bin/plutil -insert scale-resolutions -array "$target_path" || fail "could not initialize fixture mode array"
/usr/bin/plutil -insert scale-resolutions.0 -data AAAKAAAABaAAAAABACAAAA== "$target_path" || fail "could not write existing smooth payload"
/bin/cp "$target_path" "$original_path" || fail "could not preserve smooth fixture"

invalid_overrides_root="${scratch_dir}/invalid-overrides"
invalid_state_root="${scratch_dir}/invalid-state"
invalid_target_path="${invalid_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
invalid_apply_output=""
if invalid_apply_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set preset \
    --include-near-native \
    --overrides-root "$invalid_overrides_root" \
    --state-root "$invalid_state_root" \
    --confirm 2>&1)"; then
    fail "apply must reject near-native outside the smooth mode set"
fi
assert_contains "$invalid_apply_output" "error: mode set or near-native configuration is invalid"
assert_file_absent "$invalid_target_path"
assert_file_absent "$invalid_state_root"

low_divisor_overrides_root="${scratch_dir}/low-divisor-overrides"
low_divisor_state_root="${scratch_dir}/low-divisor-state"
low_divisor_apply_output=""
if low_divisor_apply_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1366x768 \
    --mode-set smooth \
    --overrides-root "$low_divisor_overrides_root" \
    --state-root "$low_divisor_state_root" \
    --confirm 2>&1)"; then
    fail "apply must reject a smooth mode set without enough exact-aspect-ratio candidates"
fi
assert_contains "$low_divisor_apply_output" "error: smooth mode set requires at least two exact-aspect-ratio candidates from 2/3 through native"
assert_file_absent "$low_divisor_overrides_root"
assert_file_absent "$low_divisor_state_root"

duplicate_apply_option_overrides_root="${scratch_dir}/duplicate-apply-overrides"
duplicate_apply_option_state_root="${scratch_dir}/duplicate-apply-state"
duplicate_apply_option_output=""
if duplicate_apply_option_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-near-native \
    --overrides-root "$duplicate_apply_option_overrides_root" \
    --state-root "$duplicate_apply_option_state_root" \
    --confirm 2>&1)"; then
    fail "apply must reject a repeated near-native option"
fi
assert_contains "$duplicate_apply_option_output" "error: --include-near-native may only be provided once"
assert_file_absent "$duplicate_apply_option_overrides_root"
assert_file_absent "$duplicate_apply_option_state_root"

duplicate_apply_mode_set_overrides_root="${scratch_dir}/duplicate-apply-mode-set-overrides"
duplicate_apply_mode_set_state_root="${scratch_dir}/duplicate-apply-mode-set-state"
duplicate_apply_mode_set_output=""
if duplicate_apply_mode_set_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --mode-set smooth \
    --overrides-root "$duplicate_apply_mode_set_overrides_root" \
    --state-root "$duplicate_apply_mode_set_state_root" \
    --confirm 2>&1)"; then
    fail "apply must reject a repeated mode-set option"
fi
assert_contains "$duplicate_apply_mode_set_output" "error: --mode-set may only be provided once"
assert_file_absent "$duplicate_apply_mode_set_overrides_root"
assert_file_absent "$duplicate_apply_mode_set_state_root"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "smooth apply should succeed in an isolated root"

assert_plist_value "$target_path" custom-metadata preserve-me
assert_plist_value "$target_path" scale-resolutions.0 AAAKAAAABaAAAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions.20 AAAMgAAABwgAAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions.40 AAAPAAAACHAAAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions.41 AAAPAAAACG4AAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions 42
assert_plist_value "$manifest_path" mode-set smooth
assert_plist_value "$manifest_path" include-near-native true

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 30ae \
    --product-id 62a5 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "smooth apply should retain exact rollback behavior"
/usr/bin/cmp -s "$original_path" "$target_path" || fail "smooth revert must restore the exact original override"

{
    printf 'target|vendor-id=30ae|product-id=62a5\n'
    for sample in {80..120}; do
        logical_width=$((sample * 16))
        logical_height=$((sample * 9))
        printf 'mode|logical=%sx%s|pixels=%sx%s|refresh=60.00|flags=1\n' \
            "$logical_width" "$logical_height" "$((logical_width * 2))" "$((logical_height * 2))"
    done
    printf 'mode|logical=1920x1079|pixels=3840x2158|refresh=60.00|flags=1\n'
} > "$full_modes_path" || fail "could not create complete smooth mode capture"

full_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --modes-file "$full_modes_path")" || fail "complete smooth capture should verify"
assert_contains "$full_output" "smooth-01: 1280x720 framebuffer=2560x1440 status=observed"
assert_contains "$full_output" "native: 1920x1080 framebuffer=3840x2160 status=observed"
assert_contains "$full_output" "near-native: 1920x1079 framebuffer=3840x2158 status=observed"
assert_contains "$full_output" "verification=complete observed=42 missing=0"

/usr/bin/sed '$d' "$full_modes_path" > "$partial_modes_path" || fail "could not create partial smooth mode capture"
partial_output=""
partial_status=0
partial_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --modes-file "$partial_modes_path" 2>&1)" || partial_status=$?
[[ "$partial_status" == 2 ]] || fail "missing near-native mode must return status 2, got ${partial_status}"
assert_contains "$partial_output" "near-native: 1920x1079 framebuffer=3840x2158 status=missing"
assert_contains "$partial_output" "verification=partial observed=41 missing=1"

duplicate_verify_mode_set_output=""
if duplicate_verify_mode_set_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --mode-set smooth \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "verify-modes must reject duplicate mode-set options"
fi
assert_contains "$duplicate_verify_mode_set_output" "error: --mode-set may only be provided once"

duplicate_verify_near_native_output=""
if duplicate_verify_near_native_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-near-native \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "verify-modes must reject duplicate near-native options"
fi
assert_contains "$duplicate_verify_near_native_output" "error: --include-near-native may only be provided once"

invalid_verify_mode_set_output=""
if invalid_verify_mode_set_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set unsupported \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "verify-modes must reject unsupported mode sets"
fi
assert_contains "$invalid_verify_mode_set_output" "error: mode set or near-native configuration is invalid"

invalid_verify_configuration_output=""
if invalid_verify_configuration_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set preset \
    --include-near-native \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "verify-modes must require the smooth mode set for near-native"
fi
assert_contains "$invalid_verify_configuration_output" "error: mode set or near-native configuration is invalid"

invalid_mode_set_output=""
if invalid_mode_set_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set preset \
    --include-near-native 2>&1)"; then
    fail "near-native mode must require the smooth mode set"
fi
assert_contains "$invalid_mode_set_output" "error: mode set or near-native configuration is invalid"

printf 'PASS: Intel HiDPI smooth apply and verify\n'
