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
assert_contains "$invalid_apply_output" "error: mode set or compatibility configuration is invalid"
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

empty_data_overrides_root="${scratch_dir}/empty-data-overrides"
empty_data_state_root="${scratch_dir}/empty-data-state"
empty_data_target_path="${empty_data_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
empty_data_manifest_path="${empty_data_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/manifest.plist"
empty_data_original_path="${empty_data_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/original.plist"
empty_data_fixture_path="${scratch_dir}/empty-data-original.plist"
/bin/mkdir -p "$(/usr/bin/dirname "$empty_data_target_path")" || fail "could not create empty-data override fixture"
/usr/bin/plutil -create xml1 "$empty_data_target_path" || fail "could not create empty-data override fixture"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$empty_data_target_path" || fail "could not write empty-data fixture vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$empty_data_target_path" || fail "could not write empty-data fixture product id"
/usr/bin/plutil -insert scale-resolutions -array "$empty_data_target_path" || fail "could not initialize empty-data fixture mode array"
/usr/bin/plutil -insert scale-resolutions.0 -xml '<data>%%%%</data>' "$empty_data_target_path" || fail "could not write empty-data fixture payload"
/bin/cp "$empty_data_target_path" "$empty_data_fixture_path" || fail "could not preserve empty-data fixture"
empty_data_apply_output=""
if empty_data_apply_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$empty_data_overrides_root" \
    --state-root "$empty_data_state_root" \
    --confirm 2>&1)"; then
    fail "apply must reject a malformed direct data payload"
fi
assert_contains "$empty_data_apply_output" "error: could not merge generated modes"
/usr/bin/cmp -s "$empty_data_fixture_path" "$empty_data_target_path" || fail "malformed direct data must leave the existing override unchanged"
assert_file_absent "$empty_data_manifest_path"
assert_file_absent "$empty_data_original_path"

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
assert_plist_value "$manifest_path" include-similar-resolutions false

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 30ae \
    --product-id 62a5 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "smooth apply should retain exact rollback behavior"
/usr/bin/cmp -s "$original_path" "$target_path" || fail "smooth revert must restore the exact original override"

similar_overrides_root="${scratch_dir}/similar-overrides"
similar_state_root="${scratch_dir}/similar-state"
similar_target_path="${similar_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
similar_manifest_path="${similar_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/manifest.plist"
similar_original_path="${scratch_dir}/similar-original.plist"
complete_overrides_root="${scratch_dir}/complete-overrides"
complete_state_root="${scratch_dir}/complete-state"
complete_target_path="${complete_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
complete_original_path="${scratch_dir}/complete-original.plist"
/bin/mkdir -p "$(/usr/bin/dirname "$similar_target_path")" || fail "could not create similar-resolution override fixture"
/usr/bin/plutil -create xml1 "$similar_target_path" || fail "could not create similar-resolution override fixture"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$similar_target_path" || fail "could not write similar-resolution fixture vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$similar_target_path" || fail "could not write similar-resolution fixture product id"
/usr/bin/plutil -insert custom-metadata -string preserve-me "$similar_target_path" || fail "could not write similar-resolution fixture metadata"
/usr/bin/plutil -insert scale-resolutions -array "$similar_target_path" || fail "could not initialize similar-resolution mode array"
/usr/bin/plutil -insert scale-resolutions.0 -data AAAKAAAABaAAAAABACAAAA== "$similar_target_path" || fail "could not write existing similar-resolution HiDPI payload"
/usr/bin/plutil -insert scale-resolutions.1 -string preserve-array-entry "$similar_target_path" || fail "could not write non-data scale-resolution fixture entry"
/usr/bin/plutil -insert scale-resolutions.2 -xml '<dict><key>nested-payload</key><data>AAAFAAAAAtA=</data></dict>' "$similar_target_path" || fail "could not write nested scale-resolution fixture entry"
/bin/cp "$similar_target_path" "$similar_original_path" || fail "could not preserve similar-resolution fixture"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$similar_overrides_root" \
    --state-root "$similar_state_root" \
    --confirm || fail "BetterDisplay-compatible similar-resolution apply should succeed in an isolated root"

assert_plist_value "$similar_target_path" custom-metadata preserve-me
assert_plist_value "$similar_target_path" scale-resolutions.0 AAAKAAAABaAAAAABACAAAA==
assert_plist_value "$similar_target_path" scale-resolutions.1 preserve-array-entry
assert_plist_value "$similar_target_path" scale-resolutions.2.nested-payload AAAFAAAAAtA=
assert_plist_value "$similar_target_path" scale-resolutions.43 AAAPAAAACG4AAAABACAAAA==
assert_plist_value "$similar_target_path" scale-resolutions.44 AAAFAAAAAtA=
assert_plist_value "$similar_target_path" scale-resolutions.85 AAAHgAAABDc=
assert_plist_value "$similar_target_path" scale-resolutions.86 AAAKAAAABaA=
assert_plist_value "$similar_target_path" scale-resolutions.127 AAAPAAAACG4=
assert_plist_value "$similar_target_path" scale-resolutions 128
assert_plist_value "$similar_manifest_path" mode-set smooth
assert_plist_value "$similar_manifest_path" include-near-native true
assert_plist_value "$similar_manifest_path" include-similar-resolutions true
assert_plist_value "$similar_manifest_path" payloads.0 AAAKAAAABaAAAAABACAAAA==
assert_plist_value "$similar_manifest_path" payloads.125 AAAPAAAACG4=
assert_plist_value "$similar_manifest_path" payloads 126

/bin/mkdir -p "$(/usr/bin/dirname "$complete_target_path")" || fail "could not create complete similar-resolution override fixture"
/bin/cp "$similar_target_path" "$complete_target_path" || fail "could not copy complete similar-resolution override fixture"
/bin/cp "$complete_target_path" "$complete_original_path" || fail "could not preserve complete similar-resolution override fixture"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$complete_overrides_root" \
    --state-root "$complete_state_root" \
    --confirm || fail "apply should accept a complete compatible payload array"
/usr/bin/cmp -s "$complete_original_path" "$complete_target_path" || fail "complete payload arrays must not be reserialized during apply"
"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 30ae \
    --product-id 62a5 \
    --overrides-root "$complete_overrides_root" \
    --state-root "$complete_state_root" \
    --confirm || fail "complete compatible payload arrays should retain exact rollback behavior"
/usr/bin/cmp -s "$complete_original_path" "$complete_target_path" || fail "complete payload array revert must restore the exact original override"

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 30ae \
    --product-id 62a5 \
    --overrides-root "$similar_overrides_root" \
    --state-root "$similar_state_root" \
    --confirm || fail "similar-resolution apply should retain exact rollback behavior"
/usr/bin/cmp -s "$similar_original_path" "$similar_target_path" || fail "similar-resolution revert must restore the exact original override"

{
    printf 'target|vendor-id=30ae|product-id=62a5\n'
    for sample in {80..120}; do
        logical_width=$((sample * 16))
        logical_height=$((sample * 9))
        printf 'mode|logical=%sx%s|pixels=%sx%s|refresh=60.00|flags=1\n' \
            "$logical_width" "$logical_height" "$((logical_width * 2))" "$((logical_height * 2))"
    done
    printf 'mode|logical=1920x1079|pixels=3840x2158|refresh=60.00|flags=1\n'
    for sample in {80..120}; do
        logical_width=$((sample * 16))
        logical_height=$((sample * 9))
        printf 'mode|logical=%sx%s|pixels=%sx%s|refresh=60.00|flags=0\n' \
            "$logical_width" "$logical_height" "$logical_width" "$logical_height"
        printf 'mode|logical=%sx%s|pixels=%sx%s|refresh=60.00|flags=0\n' \
            "$((logical_width * 2))" "$((logical_height * 2))" "$((logical_width * 2))" "$((logical_height * 2))"
    done
    printf 'mode|logical=1920x1079|pixels=1920x1079|refresh=60.00|flags=0\n'
    printf 'mode|logical=3840x2158|pixels=3840x2158|refresh=60.00|flags=0\n'
} > "$full_modes_path" || fail "could not create complete smooth mode capture"

full_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --modes-file "$full_modes_path")" || fail "complete smooth capture should verify"
assert_contains "$full_output" "smooth-01: 1280x720 framebuffer=2560x1440 status=observed"
assert_contains "$full_output" "native: 1920x1080 framebuffer=3840x2160 status=observed"
assert_contains "$full_output" "near-native: 1920x1079 framebuffer=3840x2158 status=observed"
assert_contains "$full_output" "similar-logical-smooth-01: 1280x720 framebuffer=1280x720 status=observed"
assert_contains "$full_output" "similar-framebuffer-near-native: 3840x2158 framebuffer=3840x2158 status=observed"
assert_contains "$full_output" "verification=complete observed=126 missing=0"

/usr/bin/sed '$d' "$full_modes_path" > "$partial_modes_path" || fail "could not create partial smooth mode capture"
partial_output=""
partial_status=0
partial_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --modes-file "$partial_modes_path" 2>&1)" || partial_status=$?
[[ "$partial_status" == 2 ]] || fail "missing similar framebuffer mode must return status 2, got ${partial_status}"
assert_contains "$partial_output" "similar-framebuffer-near-native: 3840x2158 framebuffer=3840x2158 status=missing"
assert_contains "$partial_output" "verification=partial observed=125 missing=1"

four_k_modes_path="${scratch_dir}/four-k-modes.txt"
{
    printf 'target|vendor-id=30ae|product-id=62a5\n'
    for sample in {160..240}; do
        logical_width=$((sample * 16))
        logical_height=$((sample * 9))
        printf 'mode|logical=%sx%s|pixels=%sx%s|refresh=60.00|flags=1\n' \
            "$logical_width" "$logical_height" "$((logical_width * 2))" "$((logical_height * 2))"
        printf 'mode|logical=%sx%s|pixels=%sx%s|refresh=60.00|flags=0\n' \
            "$logical_width" "$logical_height" "$logical_width" "$logical_height"
        printf 'mode|logical=%sx%s|pixels=%sx%s|refresh=60.00|flags=0\n' \
            "$((logical_width * 2))" "$((logical_height * 2))" "$((logical_width * 2))" "$((logical_height * 2))"
    done
} > "$four_k_modes_path" || fail "could not create complete 4K similar-resolution mode capture"

four_k_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 3840x2160 \
    --mode-set smooth \
    --include-similar-resolutions \
    --modes-file "$four_k_modes_path")" || fail "complete 4K similar-resolution capture should verify"
assert_contains "$four_k_output" "similar-framebuffer-native: 7680x4320 framebuffer=7680x4320 status=observed"
assert_contains "$four_k_output" "verification=complete observed=123 missing=0"

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

duplicate_verify_similar_resolutions_output=""
if duplicate_verify_similar_resolutions_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-similar-resolutions \
    --include-similar-resolutions \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "verify-modes must reject duplicate similar-resolution options"
fi
assert_contains "$duplicate_verify_similar_resolutions_output" "error: --include-similar-resolutions may only be provided once"

invalid_verify_mode_set_output=""
if invalid_verify_mode_set_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set unsupported \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "verify-modes must reject unsupported mode sets"
fi
assert_contains "$invalid_verify_mode_set_output" "error: mode set or compatibility configuration is invalid"

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
assert_contains "$invalid_verify_configuration_output" "error: mode set or compatibility configuration is invalid"

invalid_mode_set_output=""
if invalid_mode_set_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set preset \
    --include-near-native 2>&1)"; then
    fail "near-native mode must require the smooth mode set"
fi
assert_contains "$invalid_mode_set_output" "error: mode set or compatibility configuration is invalid"

printf 'PASS: Intel HiDPI smooth apply and verify\n'
