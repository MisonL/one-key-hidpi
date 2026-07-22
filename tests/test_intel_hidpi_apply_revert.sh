#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="${repo_dir}/tests/fixtures"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-test.XXXXXX")"
overrides_root="${scratch_dir}/Overrides"
state_root="${scratch_dir}/state"
outside_dir="${scratch_dir}/outside"
tmp_alias_real_dir="$(mktemp -d /private/tmp/one-key-hidpi-alias.XXXXXX)"
tmp_alias_scratch_dir="/tmp/${tmp_alias_real_dir##*/}"
/bin/rmdir "$tmp_alias_real_dir" || fail "could not prepare an absent /tmp alias root"

cleanup() {
    /bin/rm -rf "$scratch_dir"
    /bin/rm -rf "$tmp_alias_real_dir"
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
    [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected file: $1"
}

assert_file_mode() {
    local path="$1"
    local expected_mode="$2"
    local actual_mode

    actual_mode="$(/usr/bin/stat -f '%Lp' "$path")" || fail "could not read mode for ${path}"
    [[ "$actual_mode" == "$expected_mode" ]] || fail "expected ${path} mode ${expected_mode}, got ${actual_mode}"
}

assert_directory_absent() {
    [[ ! -e "$1" ]] || fail "unexpected directory: $1"
}

assert_contains() {
    local haystack="$1"
    local expected="$2"

    printf '%s\n' "$haystack" | /usr/bin/grep -Fq "$expected" || fail "missing expected text: ${expected}"
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
/bin/chmod 0600 "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
/bin/chmod 0640 "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-7777"

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
normalized_overrides_root="$(/bin/realpath "$overrides_root")" || fail "could not normalize overrides root"

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
assert_file_mode "$original_path" 600
assert_plist_value "$manifest_path" manifest-version 2
assert_plist_value "$manifest_path" overrides-root "$normalized_overrides_root"
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
assert_file_mode "$target_path" 600
assert_plist_value "${overrides_root}/DisplayVendorID-30ae/DisplayProductID-7777" custom-metadata sibling-must-survive
assert_file_absent "$manifest_path"
assert_file_absent "$original_path"
assert_directory_absent "${overrides_root}/.one-key-hidpi-locks"

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
assert_directory_absent "${state_root}/DisplayVendorID-30ae"

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
assert_file_mode "$no_scales_target_path" 640

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

bound_overrides_root="${scratch_dir}/bound-overrides"
wrong_overrides_root="${scratch_dir}/wrong-overrides"
bound_state_root="${scratch_dir}/bound-state"
bound_target_path="${bound_overrides_root}/DisplayVendorID-7/DisplayProductID-8"
wrong_target_path="${wrong_overrides_root}/DisplayVendorID-7/DisplayProductID-8"
bound_manifest_path="${bound_state_root}/DisplayVendorID-7/DisplayProductID-8/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 7 \
    --product-id 8 \
    --native-resolution 1920x1080 \
    --overrides-root "$bound_overrides_root" \
    --state-root "$bound_state_root" \
    --confirm || fail "apply for override-root binding should succeed"
/bin/mkdir -p "$(/usr/bin/dirname "$wrong_target_path")"
/bin/cp "$bound_target_path" "$wrong_target_path"
wrong_root_output=""
if wrong_root_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 7 \
    --product-id 8 \
    --overrides-root "$wrong_overrides_root" \
    --state-root "$bound_state_root" \
    --confirm 2>&1)"; then
    fail "revert must reject a manifest for a different overrides root"
fi
assert_contains "$wrong_root_output" "manifest override root does not match this target"
assert_file_exists "$wrong_target_path"
assert_file_exists "$bound_manifest_path"
assert_directory_absent "${wrong_overrides_root}/.one-key-hidpi-locks"
"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 7 \
    --product-id 8 \
    --overrides-root "$bound_overrides_root" \
    --state-root "$bound_state_root" \
    --confirm || fail "revert with the manifest overrides root should succeed"
assert_file_absent "$bound_target_path"
assert_file_exists "$wrong_target_path"

legacy_state_overrides_root="${scratch_dir}/legacy-state-overrides"
legacy_state_root="${scratch_dir}/legacy-state"
legacy_state_target_path="${legacy_state_overrides_root}/DisplayVendorID-9/DisplayProductID-a"
legacy_state_manifest_path="${legacy_state_root}/DisplayVendorID-9/DisplayProductID-a/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 9 \
    --product-id a \
    --native-resolution 1920x1080 \
    --overrides-root "$legacy_state_overrides_root" \
    --state-root "$legacy_state_root" \
    --confirm || fail "apply for legacy-state rejection should succeed"
/usr/bin/plutil -replace manifest-version -integer 1 "$legacy_state_manifest_path" || fail "could not create legacy manifest fixture"
legacy_state_output=""
if legacy_state_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 9 \
    --product-id a \
    --overrides-root "$legacy_state_overrides_root" \
    --state-root "$legacy_state_root" \
    --confirm 2>&1)"; then
    fail "revert must reject a legacy manifest without an overrides root binding"
fi
assert_contains "$legacy_state_output" "manifest version is unsupported"
assert_file_exists "$legacy_state_target_path"
assert_file_exists "$legacy_state_manifest_path"
assert_directory_absent "${legacy_state_overrides_root}/.one-key-hidpi-locks"

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

/bin/rm -f "$modified_target_path"
/bin/mkdir -p "$outside_dir"
/bin/ln -s "${outside_dir}/revert-target" "$modified_target_path"
revert_symlink_output=""
if revert_symlink_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 4c2d \
    --product-id 7669 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm 2>&1)"; then
    fail "revert must reject a symbolic-link target path"
fi
assert_contains "$revert_symlink_output" "target path traverses a symbolic link"
assert_file_exists "$modified_manifest_path"

if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 3840x2160 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" >/dev/null 2>&1; then
    fail "apply without --confirm must fail explicitly"
fi

failed_target_vendor_dir="${overrides_root}/DisplayVendorID-1"
failed_target_state_vendor_dir="${state_root}/DisplayVendorID-1"
if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 1 \
    --native-resolution 1x1080 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm >/dev/null 2>&1; then
    fail "invalid apply to a new target must fail explicitly"
fi
assert_directory_absent "$failed_target_vendor_dir"
assert_directory_absent "$failed_target_state_vendor_dir"

overflow_resolution="18446744073709555456x18446744073709553776"
if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 2 \
    --native-resolution "$overflow_resolution" \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm >/dev/null 2>&1; then
    fail "overflowing apply resolution must fail explicitly"
fi
assert_directory_absent "${overrides_root}/DisplayVendorID-1"
assert_directory_absent "${state_root}/DisplayVendorID-1"

/bin/ln -s "$outside_dir" "${overrides_root}/DisplayVendorID-dead"
if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id dead \
    --product-id beef \
    --native-resolution 1920x1080 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm >/dev/null 2>&1; then
    fail "apply must reject a symbolic-link vendor directory"
fi
assert_file_absent "${outside_dir}/DisplayProductID-beef"

symlink_root="${scratch_dir}/overrides-link"
/bin/ln -s "$overrides_root" "$symlink_root"
if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 3 \
    --native-resolution 1920x1080 \
    --overrides-root "$symlink_root" \
    --state-root "$state_root" \
    --confirm >/dev/null 2>&1; then
    fail "apply must reject a symbolic-link overrides root"
fi

state_symlink_root="${scratch_dir}/state-link"
/bin/ln -s "$state_root" "$state_symlink_root"
if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 4 \
    --native-resolution 1920x1080 \
    --overrides-root "$overrides_root" \
    --state-root "$state_symlink_root" \
    --confirm >/dev/null 2>&1; then
    fail "apply must reject a symbolic-link state root"
fi
assert_file_absent "${overrides_root}/DisplayVendorID-1/DisplayProductID-4"

lock_path="$(
    /bin/bash -c 'source "$1"; target_lock_path "$2" "$3" "$4"' bash \
        "${repo_dir}/lib/intel_hidpi_storage.sh" "$normalized_overrides_root" 1 5
)" || fail "could not calculate target lock path"
/bin/mkdir -p "$(/usr/bin/dirname "$lock_path")" || fail "could not create target lock directory"
/usr/bin/shlock -f "$lock_path" -p "$$" >/dev/null 2>&1 || fail "could not create a test lock"
lock_output=""
if lock_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 5 \
    --native-resolution 1920x1080 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm 2>&1)"; then
    fail "apply must reject a display already locked by another process"
fi
assert_contains "$lock_output" "could not acquire display operation lock"
assert_file_absent "${overrides_root}/DisplayVendorID-1/DisplayProductID-5"
/bin/rm -f "$lock_path"

second_operation_state_root="${scratch_dir}/second-operation-state"
interrupted_lock_path="$(
    /bin/bash -c 'source "$1"; target_lock_path "$2" "$3" "$4"' bash \
        "${repo_dir}/lib/intel_hidpi_storage.sh" "$normalized_overrides_root" 1 8
)" || fail "could not calculate interrupted target lock path"
/bin/bash -c '
    source "$1"
    reset_operation_cleanup_state
    acquire_display_lock "$2" 1 8 || exit 1
    sleep 30
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$normalized_overrides_root" &
interrupted_lock_pid=$!
for _ in {1..100}; do
    [[ -f "$interrupted_lock_path" ]] && break
    sleep 0.05
done
if [[ ! -f "$interrupted_lock_path" ]]; then
    /bin/kill -TERM "$interrupted_lock_pid" 2>/dev/null || true
    wait "$interrupted_lock_pid" 2>/dev/null || true
    fail "interrupted operation did not acquire its display lock"
fi
concurrent_lock_output=""
if concurrent_lock_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 8 \
    --native-resolution 1920x1080 \
    --overrides-root "$overrides_root" \
    --state-root "$second_operation_state_root" \
    --confirm 2>&1)"; then
    fail "a different state root must not bypass a target operation lock"
fi
assert_contains "$concurrent_lock_output" "could not acquire display operation lock"
assert_file_absent "${overrides_root}/DisplayVendorID-1/DisplayProductID-8"
assert_directory_absent "${second_operation_state_root}/DisplayVendorID-1"
/bin/kill -TERM "$interrupted_lock_pid" || fail "could not terminate the interrupted operation"
wait "$interrupted_lock_pid" 2>/dev/null || true
assert_file_absent "$interrupted_lock_path"

if ((EUID != 0)); then
    if "${repo_dir}/intel-hidpi.sh" apply \
        --vendor-id 1 \
        --product-id 6 \
        --native-resolution 1920x1080 \
        --overrides-root /Library/Displays/Contents/Resources/Overrides/./ \
        --state-root "$state_root" \
        --confirm >/dev/null 2>&1; then
        fail "lexically equivalent system override path must require root"
    fi

    if "${repo_dir}/intel-hidpi.sh" apply \
        --vendor-id 1 \
        --product-id 7 \
        --native-resolution 1920x1080 \
        --overrides-root /System/Volumes/Data/Library/Displays/Contents/Resources/Overrides \
        --state-root "$state_root" \
        --confirm >/dev/null 2>&1; then
        fail "data-volume system override path must require root"
    fi

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

tmp_alias_overrides_root="${tmp_alias_scratch_dir}/Overrides"
tmp_alias_state_root="${tmp_alias_scratch_dir}/state"
tmp_alias_target_path="${tmp_alias_overrides_root}/DisplayVendorID-2/DisplayProductID-9"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 2 \
    --product-id 9 \
    --native-resolution 1920x1080 \
    --overrides-root "$tmp_alias_overrides_root" \
    --state-root "$tmp_alias_state_root" \
    --confirm || fail "apply through the /tmp system alias should succeed"
assert_file_exists "$tmp_alias_target_path"
"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 2 \
    --product-id 9 \
    --overrides-root "$tmp_alias_overrides_root" \
    --state-root "$tmp_alias_state_root" \
    --confirm || fail "revert through the /tmp system alias should succeed"
assert_file_absent "$tmp_alias_target_path"

printf 'PASS: Intel HiDPI apply and revert\n'
