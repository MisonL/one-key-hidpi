#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="${repo_dir}/tests/fixtures"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-test.XXXXXX")"
overrides_root="${scratch_dir}/Overrides"
state_root="${scratch_dir}/state"

cleanup() {
    /bin/rm -rf "$scratch_dir"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_plist_value() {
    local plist_path="$1"
    local key_path="$2"
    local expected="$3"
    local actual

    actual="$(/usr/bin/plutil -extract "$key_path" raw -o - "$plist_path")" || fail "missing ${key_path} in ${plist_path}"
    [[ "$actual" == "$expected" ]] || fail "expected ${key_path}=${expected}, got ${actual}"
}

assert_file_exists() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_file_absent() {
    [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

assert_file_mode() {
    local path="$1"
    local expected_mode="$2"
    local actual_mode

    actual_mode="$(/usr/bin/stat -f '%Lp' "$path")" || fail "could not read mode for ${path}"
    [[ "$actual_mode" == "$expected_mode" ]] || fail "expected ${path} mode ${expected_mode}, got ${actual_mode}"
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

/bin/mkdir -p "${overrides_root}/DisplayVendorID-30ae"
/bin/cp "${fixture_dir}/overrides/DisplayVendorID-30ae/DisplayProductID-62a5-rich" \
    "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
/bin/cp "${fixture_dir}/overrides/DisplayVendorID-30ae/DisplayProductID-7777" \
    "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-7777"
/bin/cp "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5" "${scratch_dir}/original-existing.plist"
/bin/cp "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-7777" "${scratch_dir}/original-without-scales.plist"

existing_original_hash="$(sha256_file "${scratch_dir}/original-existing.plist")"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 3840x2160 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "apply to existing override should succeed"

target_path="${overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
manifest_path="${state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/manifest.plist"
original_path="${state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/original.plist"
candidate_hash="$(sha256_file "$target_path")"

assert_plist_value "$target_path" custom-metadata preserve-me
assert_plist_value "$target_path" DisplayVendorID 12462
assert_plist_value "$target_path" DisplayProductID 25253
assert_plist_value "$target_path" scale-resolutions.0 AAANAAAAB1A=
assert_plist_value "$target_path" scale-resolutions.1 AAAPAAAACHAAAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions.2 AAASAAAACiAAAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions.3 AAAUAAAAC0AAAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions.4 AAAWgAAADKgAAAABACAAAA==
assert_plist_value "$target_path" scale-resolutions.5 AAAeAAAAEOAAAAABACAAAA==
assert_plist_value "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-7777" custom-metadata sibling-must-survive
assert_file_exists "$manifest_path"
assert_file_exists "$original_path"
assert_file_mode "$target_path" 644
assert_file_mode "$manifest_path" 644
assert_file_mode "$original_path" 644
assert_plist_value "$manifest_path" manifest-version 1
assert_plist_value "$manifest_path" target-existed true
assert_plist_value "$manifest_path" native-resolution 3840x2160
assert_plist_value "$manifest_path" original-sha256 "$existing_original_hash"
assert_plist_value "$manifest_path" candidate-sha256 "$candidate_hash"
assert_plist_value "$manifest_path" payloads.0 AAANAAAAB1A=
assert_plist_value "$manifest_path" payloads.5 AAAeAAAAEOAAAAABACAAAA==
/usr/bin/cmp -s "${scratch_dir}/original-existing.plist" "$original_path" || fail "backup must preserve the exact original override"

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 30ae \
    --product-id 62a5 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "revert existing override should succeed"

/usr/bin/cmp -s "${scratch_dir}/original-existing.plist" "$target_path" || fail "revert must restore the exact original override"
assert_plist_value "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-7777" custom-metadata sibling-must-survive
assert_file_absent "$manifest_path"
assert_file_absent "$original_path"

if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1x1080 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm >/dev/null 2>&1; then
    fail "invalid generated mode must fail explicitly"
fi

/usr/bin/cmp -s "${scratch_dir}/original-existing.plist" "$target_path" || fail "failed apply must not change the existing override"
assert_file_absent "$manifest_path"
assert_file_absent "$original_path"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 7777 \
    --native-resolution 3840x2160 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "apply to an override without scale-resolutions should succeed"

no_scales_target_path="${overrides_root}/DisplayVendorID-30ae/DisplayProductID-7777"
assert_plist_value "$no_scales_target_path" custom-metadata sibling-must-survive
assert_plist_value "$no_scales_target_path" scale-resolutions.0 AAAPAAAACHAAAAABACAAAA==

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 30ae \
    --product-id 7777 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "revert without prior scale-resolutions should succeed"

/usr/bin/cmp -s "${scratch_dir}/original-without-scales.plist" "$no_scales_target_path" || fail "revert must restore an override without scale-resolutions"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 4c2d \
    --product-id 7668 \
    --native-resolution 3840x2160 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "apply to absent override should succeed"

new_target_path="${overrides_root}/DisplayVendorID-4c2d/DisplayProductID-7668"
new_manifest_path="${state_root}/DisplayVendorID-4c2d/DisplayProductID-7668/manifest.plist"
assert_file_exists "$new_target_path"
assert_plist_value "$new_target_path" DisplayVendorID 19501
assert_plist_value "$new_target_path" DisplayProductID 30312
assert_plist_value "$new_manifest_path" target-existed false
assert_plist_value "$new_manifest_path" original-sha256 ""
assert_plist_value "$new_manifest_path" candidate-sha256 "$(sha256_file "$new_target_path")"
assert_file_mode "$new_target_path" 644

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 4c2d \
    --product-id 7668 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "revert created override should succeed"

assert_file_absent "$new_target_path"
assert_file_absent "$new_manifest_path"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 4c2d \
    --product-id 7669 \
    --native-resolution 3840x2160 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "apply for modified-target protection should succeed"

modified_target_path="${overrides_root}/DisplayVendorID-4c2d/DisplayProductID-7669"
modified_manifest_path="${state_root}/DisplayVendorID-4c2d/DisplayProductID-7669/manifest.plist"
/usr/bin/plutil -insert external-change -string must-survive "$modified_target_path" || fail "could not modify target fixture"

if "${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 4c2d \
    --product-id 7669 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm >/dev/null 2>&1; then
    fail "revert must refuse a target changed after apply"
fi

assert_plist_value "$modified_target_path" external-change must-survive
assert_file_exists "$modified_manifest_path"

if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 3840x2160 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" >/dev/null 2>&1; then
    fail "apply without --confirm must fail explicitly"
fi

if ((EUID != 0)); then
    if "${repo_dir}/intel-hidpi.sh" apply \
        --vendor-id 4c2d \
        --product-id 7668 \
        --native-resolution 3840x2160 \
        --overrides-root /Library/Displays/Contents/Resources/Overrides \
        --state-root "$state_root" \
        --confirm >/dev/null 2>&1; then
        fail "default system override path must require root"
    fi
fi

printf 'PASS: Intel HiDPI apply and revert\n'
