#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="${repo_dir}/tests/fixtures"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

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

assert_file_contents() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$(/bin/cat "$path")" || fail "could not read ${path}"
    [[ "$actual" == "$expected" ]] || fail "expected ${path} contents to remain unchanged"
}

assert_directory_empty() {
    local path="$1"
    local first_entry

    [[ -d "$path" && ! -L "$path" ]] || fail "expected directory: ${path}"
    first_entry="$(/usr/bin/find "$path" -mindepth 1 -maxdepth 1 -print -quit)" || fail "could not inspect ${path}"
    [[ -z "$first_entry" ]] || fail "expected empty directory: ${path}"
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

file_identity() {
    /usr/bin/stat -f '%d:%i' "$1"
}

assert_manifest_file_identity() {
    local manifest_path="$1"
    local key_path="$2"
    local tracked_path="$3"

    assert_plist_value "$manifest_path" "$key_path" "$(file_identity "$tracked_path")"
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
assert_plist_value "$manifest_path" manifest-version 4
assert_plist_value "$manifest_path" commit-state committed
assert_plist_value "$manifest_path" overrides-root "$normalized_overrides_root"
assert_plist_value "$manifest_path" target-existed true
assert_plist_value "$manifest_path" native-resolution 3840x2160
assert_plist_value "$manifest_path" original-sha256 "$existing_original_hash"
assert_plist_value "$manifest_path" candidate-sha256 "$candidate_hash"
assert_manifest_file_identity "$manifest_path" candidate-file-identity "$target_path"
assert_manifest_file_identity "$manifest_path" original-file-identity "$original_path"
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
assert_directory_empty "${overrides_root}/.one-key-hidpi-locks"

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
assert_directory_empty "${state_root}/DisplayVendorID-30ae/DisplayProductID-62a5"

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
assert_plist_value "$new_manifest_path" commit-state committed
assert_plist_value "$new_manifest_path" original-sha256 ""
assert_plist_value "$new_manifest_path" candidate-sha256 "$(sha256_file "$new_target_path")"
assert_manifest_file_identity "$new_manifest_path" candidate-file-identity "$new_target_path"
assert_plist_value "$new_manifest_path" original-file-identity ""
assert_file_mode "$new_target_path" 644

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 4c2d \
    --product-id 7668 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "revert created override should succeed"

assert_file_absent "$new_target_path"
assert_file_absent "$new_manifest_path"

missing_existing_overrides_root="${scratch_dir}/missing-existing-overrides"
missing_existing_state_root="${scratch_dir}/missing-existing-state"
missing_existing_target_path="${missing_existing_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
missing_existing_original_path="${missing_existing_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/original.plist"
missing_existing_manifest_path="${missing_existing_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/manifest.plist"
/bin/mkdir -p "$(/usr/bin/dirname "$missing_existing_target_path")" || fail "could not create missing-existing target directory"
/bin/cp "${fixture_dir}/overrides/DisplayVendorID-30ae/DisplayProductID-62a5-rich" "$missing_existing_target_path" || fail "could not create missing-existing target fixture"
/bin/chmod 0600 "$missing_existing_target_path" || fail "could not set missing-existing target mode"
/bin/cp "$missing_existing_target_path" "${scratch_dir}/missing-existing-original.plist" || fail "could not preserve missing-existing original fixture"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --overrides-root "$missing_existing_overrides_root" \
    --state-root "$missing_existing_state_root" \
    --confirm || fail "apply for missing existing target recovery should succeed"
assert_file_exists "$missing_existing_original_path"
/bin/rm -f "$missing_existing_target_path"
"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 30ae \
    --product-id 62a5 \
    --overrides-root "$missing_existing_overrides_root" \
    --state-root "$missing_existing_state_root" \
    --confirm || fail "revert must restore a verified original after its target was removed"
/usr/bin/cmp -s "${scratch_dir}/missing-existing-original.plist" "$missing_existing_target_path" || fail "revert must restore the deleted original override exactly"
assert_file_mode "$missing_existing_target_path" 600
assert_file_absent "$missing_existing_manifest_path"
assert_file_absent "$missing_existing_original_path"

missing_created_overrides_root="${scratch_dir}/missing-created-overrides"
missing_created_state_root="${scratch_dir}/missing-created-state"
missing_created_target_path="${missing_created_overrides_root}/DisplayVendorID-c/DisplayProductID-d"
missing_created_manifest_path="${missing_created_state_root}/DisplayVendorID-c/DisplayProductID-d/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id c \
    --product-id d \
    --native-resolution 1920x1080 \
    --overrides-root "$missing_created_overrides_root" \
    --state-root "$missing_created_state_root" \
    --confirm || fail "apply for missing created target recovery should succeed"
assert_file_exists "$missing_created_target_path"
/bin/rm -f "$missing_created_target_path"
"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id c \
    --product-id d \
    --overrides-root "$missing_created_overrides_root" \
    --state-root "$missing_created_state_root" \
    --confirm || fail "revert must clean state when a created target was removed"
assert_file_absent "$missing_created_target_path"
assert_file_absent "$missing_created_manifest_path"
assert_directory_empty "${missing_created_state_root}/DisplayVendorID-c/DisplayProductID-d"

backup_identity_overrides_root="${scratch_dir}/backup-identity-overrides"
backup_identity_state_root="${scratch_dir}/backup-identity-state"
backup_identity_target_path="${backup_identity_overrides_root}/DisplayVendorID-31/DisplayProductID-32"
backup_identity_state_dir="${backup_identity_state_root}/DisplayVendorID-31/DisplayProductID-32"
backup_identity_original_path="${backup_identity_state_dir}/original.plist"
backup_identity_manifest_path="${backup_identity_state_dir}/manifest.plist"
/bin/mkdir -p "$(/usr/bin/dirname "$backup_identity_target_path")" || fail "could not prepare backup identity fixture"
/bin/cp "${fixture_dir}/overrides/DisplayVendorID-30ae/DisplayProductID-62a5-rich" "$backup_identity_target_path" || fail "could not create backup identity target"
/usr/bin/plutil -replace DisplayVendorID -integer 49 "$backup_identity_target_path" || fail "could not set backup identity vendor id"
/usr/bin/plutil -replace DisplayProductID -integer 50 "$backup_identity_target_path" || fail "could not set backup identity product id"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 31 \
    --product-id 32 \
    --native-resolution 1920x1080 \
    --overrides-root "$backup_identity_overrides_root" \
    --state-root "$backup_identity_state_root" \
    --confirm || fail "apply for original backup identity protection should succeed"
/bin/cp "$backup_identity_original_path" "${backup_identity_state_dir}/.original.replacement" || fail "could not copy original backup identity fixture"
/bin/mv "${backup_identity_state_dir}/.original.replacement" "$backup_identity_original_path" || fail "could not replace original backup identity fixture"
backup_identity_output=""
if backup_identity_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 31 \
    --product-id 32 \
    --overrides-root "$backup_identity_overrides_root" \
    --state-root "$backup_identity_state_root" \
    --confirm 2>&1)"; then
    fail "revert must reject a same-content original backup with a different identity"
fi
assert_contains "$backup_identity_output" "original backup identity changed after apply; refusing to restore it"
assert_file_exists "$backup_identity_target_path"
assert_file_exists "$backup_identity_original_path"
assert_file_exists "$backup_identity_manifest_path"

target_identity_overrides_root="${scratch_dir}/target-identity-overrides"
target_identity_state_root="${scratch_dir}/target-identity-state"
target_identity_target_path="${target_identity_overrides_root}/DisplayVendorID-33/DisplayProductID-34"
target_identity_manifest_path="${target_identity_state_root}/DisplayVendorID-33/DisplayProductID-34/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 33 \
    --product-id 34 \
    --native-resolution 1920x1080 \
    --overrides-root "$target_identity_overrides_root" \
    --state-root "$target_identity_state_root" \
    --confirm || fail "apply for target identity protection should succeed"
/bin/cp "$target_identity_target_path" "${target_identity_target_path}.replacement" || fail "could not copy target identity fixture"
/bin/mv "${target_identity_target_path}.replacement" "$target_identity_target_path" || fail "could not replace target identity fixture"
target_identity_output=""
if target_identity_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 33 \
    --product-id 34 \
    --overrides-root "$target_identity_overrides_root" \
    --state-root "$target_identity_state_root" \
    --confirm 2>&1)"; then
    fail "revert must reject a same-content target with a different identity"
fi
assert_contains "$target_identity_output" "target override identity changed after apply; refusing to overwrite it"
assert_file_exists "$target_identity_target_path"
assert_file_exists "$target_identity_manifest_path"

pending_manifest_overrides_root="${scratch_dir}/pending-manifest-overrides"
pending_manifest_state_root="${scratch_dir}/pending-manifest-state"
pending_manifest_target_path="${pending_manifest_overrides_root}/DisplayVendorID-35/DisplayProductID-36"
pending_manifest_path="${pending_manifest_state_root}/DisplayVendorID-35/DisplayProductID-36/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 35 \
    --product-id 36 \
    --native-resolution 1920x1080 \
    --overrides-root "$pending_manifest_overrides_root" \
    --state-root "$pending_manifest_state_root" \
    --confirm || fail "apply for pending manifest protection should succeed"
/usr/bin/plutil -replace commit-state -string pending "$pending_manifest_path" || fail "could not create pending manifest fixture"
pending_manifest_output=""
if pending_manifest_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 35 \
    --product-id 36 \
    --overrides-root "$pending_manifest_overrides_root" \
    --state-root "$pending_manifest_state_root" \
    --confirm 2>&1)"; then
    fail "revert must reject a pending manifest"
fi
assert_contains "$pending_manifest_output" "manifest apply state is incomplete; refusing to revert automatically"
assert_file_exists "$pending_manifest_target_path"
assert_file_exists "$pending_manifest_path"

empty_operation_directory_output="$(/bin/bash -c '
    source "$1"
    reset_operation_cleanup_state
    create_operation_temporary_directory || exit 1
    operation_directory="$OPERATION_TEMPORARY_DIRECTORY"
    complete_operation_cleanup || exit 1
    [[ ! -e "$operation_directory" && ! -L "$operation_directory" ]] || exit 1
    trap - EXIT
    printf "%s\\n" "$operation_directory"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh")" || fail "empty private operation directory must be removed"
[[ "$empty_operation_directory_output" == /private/tmp/one-key-hidpi-operation.* ]] || fail "empty operation directory cleanup returned an unexpected path"

competing_target_root="${scratch_dir}/competing-target-overrides"
competing_state_root="${scratch_dir}/competing-target-state"
competing_target_path="${competing_target_root}/DisplayVendorID-e/DisplayProductID-f"
competing_state_dir="${competing_state_root}/DisplayVendorID-e/DisplayProductID-f"
competing_manifest_path="${competing_state_dir}/manifest.plist"
competing_manifest_candidate_path="${competing_state_dir}/.manifest.candidate"
competing_candidate_path="${competing_target_root}/DisplayVendorID-e/.DisplayProductID-f.candidate"
/bin/mkdir -p "$(/usr/bin/dirname "$competing_target_path")" "$competing_state_dir" || fail "could not prepare competing-target fixture"
printf 'candidate\n' > "$competing_candidate_path"
printf 'manifest\n' > "$competing_manifest_candidate_path"
competing_target_output=""
if competing_target_output="$(/bin/bash -c '
    source "$1"
    race_target="$2"
    eval "$(declare -f darwin_install_file_without_replacement | /usr/bin/sed '"'"'s/^darwin_install_file_without_replacement/original_darwin_install_file_without_replacement/'"'"')"
    darwin_install_file_without_replacement() {
        if [[ "$2" == "$race_target" ]]; then
            printf "competing target\\n" > "$2"
        fi
        original_darwin_install_file_without_replacement "$@"
    }
    candidate_hash="$(sha256_file "$3")"
    manifest_hash="$(sha256_file "$5")"
    candidate_identity="$(darwin_file_identity "$3")"
    manifest_identity="$(darwin_file_identity "$5")"
    commit_apply_state "$race_target" "$3" false "" "" "$4" "$5" "$6" "$candidate_hash" "$manifest_hash" "" "$candidate_identity" "$manifest_identity"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" \
    "$competing_target_path" "$competing_candidate_path" "${competing_state_dir}/original.plist" \
    "$competing_manifest_candidate_path" "$competing_manifest_path" 2>&1)"; then
    fail "new-target commit must reject a competing target"
fi
assert_contains "$competing_target_output" "state was retained for manual inspection"
assert_file_contents "$competing_target_path" "competing target"
assert_file_contents "$competing_manifest_path" "manifest"

competing_link_target_path="${competing_target_root}/DisplayVendorID-e/DisplayProductID-10"
competing_link_candidate_path="${competing_target_root}/DisplayVendorID-e/.DisplayProductID-10.candidate"
competing_link_outside_dir="${scratch_dir}/competing-link-outside"
/bin/mkdir -p "$competing_link_outside_dir" || fail "could not prepare competing-link fixture"
printf 'candidate\n' > "$competing_link_candidate_path"
/bin/ln -s "$competing_link_outside_dir" "$competing_link_target_path" || fail "could not create competing target link"
if /bin/bash -c '
    source "$1"
    install_file_without_replacement "$2" "$3" "$(sha256_file "$2")" "$(darwin_file_identity "$2")"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" \
    "$competing_link_candidate_path" "$competing_link_target_path" >/dev/null 2>&1; then
    fail "new-target install must reject a competing target symbolic link"
fi
assert_directory_empty "$competing_link_outside_dir"
[[ -L "$competing_link_target_path" ]] || fail "competing target symbolic link must remain in place"

existing_commit_target_path="${scratch_dir}/existing-commit-target"
existing_commit_candidate_path="${scratch_dir}/existing-commit-candidate"
existing_commit_backup_candidate_path="${scratch_dir}/existing-commit-backup-candidate"
existing_commit_state_dir="${scratch_dir}/existing-commit-state/DisplayVendorID-11/DisplayProductID-12"
existing_commit_original_path="${existing_commit_state_dir}/original.plist"
existing_commit_manifest_path="${existing_commit_state_dir}/manifest.plist"
existing_commit_manifest_candidate_path="${existing_commit_state_dir}/.manifest.candidate"
/bin/mkdir -p "$existing_commit_state_dir" || fail "could not prepare existing-target commit fixture"
printf 'original target\n' > "$existing_commit_target_path"
printf 'candidate target\n' > "$existing_commit_candidate_path"
/bin/cp "$existing_commit_target_path" "$existing_commit_backup_candidate_path" || fail "could not prepare exact existing-target backup candidate"
printf 'competing manifest\n' > "$existing_commit_manifest_path"
printf 'candidate manifest\n' > "$existing_commit_manifest_candidate_path"
existing_commit_output=""
if existing_commit_output="$(/bin/bash -c '
    source "$1"
    candidate_hash="$(sha256_file "$3")"
    manifest_hash="$(sha256_file "$7")"
    original_identity="$(darwin_file_identity "$2")"
    candidate_identity="$(darwin_file_identity "$3")"
    manifest_identity="$(darwin_file_identity "$7")"
    commit_apply_state "$2" "$3" true "$4" "$5" "$6" "$7" "$8" "$candidate_hash" "$manifest_hash" "$original_identity" "$candidate_identity" "$manifest_identity"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" \
    "$existing_commit_target_path" "$existing_commit_candidate_path" "$(sha256_file "$existing_commit_target_path")" \
    "$existing_commit_backup_candidate_path" "$existing_commit_original_path" "$existing_commit_manifest_candidate_path" \
    "$existing_commit_manifest_path" 2>&1)"; then
    fail "existing-target commit must reject a competing manifest"
fi
assert_contains "$existing_commit_output" "state was retained for manual inspection"
assert_file_contents "$existing_commit_target_path" "original target"
assert_file_contents "$existing_commit_original_path" "original target"
assert_file_contents "$existing_commit_manifest_path" "competing manifest"

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
assert_directory_empty "${wrong_overrides_root}/.one-key-hidpi-locks"
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
assert_directory_empty "${legacy_state_overrides_root}/.one-key-hidpi-locks"

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

state_file_link_overrides_root="${scratch_dir}/state-file-link-overrides"
state_file_link_state_root="${scratch_dir}/state-file-link-state"
state_file_link_target_path="${state_file_link_overrides_root}/DisplayVendorID-11/DisplayProductID-12"
state_file_link_dir="${state_file_link_state_root}/DisplayVendorID-11/DisplayProductID-12"
state_file_link_manifest_path="${state_file_link_dir}/manifest.plist"
state_file_link_outside_path="${scratch_dir}/state-file-link-outside.plist"
/bin/mkdir -p "$state_file_link_dir" || fail "could not prepare state-file-link fixture"
printf 'outside state manifest\n' > "$state_file_link_outside_path"
/bin/ln -s "$state_file_link_outside_path" "$state_file_link_manifest_path" || fail "could not create state manifest link"
state_file_link_apply_output=""
if state_file_link_apply_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 11 \
    --product-id 12 \
    --native-resolution 1920x1080 \
    --overrides-root "$state_file_link_overrides_root" \
    --state-root "$state_file_link_state_root" \
    --confirm 2>&1)"; then
    fail "apply must reject a symbolic-link manifest path"
fi
assert_contains "$state_file_link_apply_output" "state files traverse a symbolic link"
assert_file_contents "$state_file_link_outside_path" "outside state manifest"
assert_file_absent "$state_file_link_target_path"
assert_directory_absent "${state_file_link_overrides_root}/.one-key-hidpi-locks"

revert_state_link_overrides_root="${scratch_dir}/revert-state-link-overrides"
revert_state_link_state_root="${scratch_dir}/revert-state-link-state"
revert_state_link_target_path="${revert_state_link_overrides_root}/DisplayVendorID-13/DisplayProductID-14"
revert_state_link_manifest_path="${revert_state_link_state_root}/DisplayVendorID-13/DisplayProductID-14/manifest.plist"
revert_state_link_outside_path="${scratch_dir}/revert-state-link-outside.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 13 \
    --product-id 14 \
    --native-resolution 1920x1080 \
    --overrides-root "$revert_state_link_overrides_root" \
    --state-root "$revert_state_link_state_root" \
    --confirm || fail "apply for state-link revert protection should succeed"
/bin/cp "$revert_state_link_manifest_path" "$revert_state_link_outside_path" || fail "could not preserve state-link manifest fixture"
/bin/rm -f "$revert_state_link_manifest_path"
/bin/ln -s "$revert_state_link_outside_path" "$revert_state_link_manifest_path" || fail "could not replace state manifest with a link"
revert_state_link_output=""
if revert_state_link_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 13 \
    --product-id 14 \
    --overrides-root "$revert_state_link_overrides_root" \
    --state-root "$revert_state_link_state_root" \
    --confirm 2>&1)"; then
    fail "revert must reject a symbolic-link manifest path"
fi
assert_contains "$revert_state_link_output" "state files traverse a symbolic link"
assert_file_exists "$revert_state_link_target_path"
/usr/bin/cmp -s "$revert_state_link_outside_path" "$revert_state_link_manifest_path" || fail "revert must not change an external manifest link target"
assert_directory_empty "${revert_state_link_overrides_root}/.one-key-hidpi-locks"

post_lock_target_overrides_root="${scratch_dir}/post-lock-target-overrides"
post_lock_target_state_root="${scratch_dir}/post-lock-target-state"
post_lock_target_outside_path="${scratch_dir}/post-lock-target-outside.plist"
post_lock_target_path="${post_lock_target_overrides_root}/DisplayVendorID-15/DisplayProductID-16"
printf 'post-lock external target\n' > "$post_lock_target_outside_path"
post_lock_target_output=""
if post_lock_target_output="$(/bin/bash -c '
    source "$1"
    race_outside="$2"
    acquire_display_lock() {
        /bin/mkdir -p "$1/DisplayVendorID-$2" || return 1
        /bin/ln -s "$race_outside" "$1/DisplayVendorID-$2/DisplayProductID-$3"
    }
    apply_override 15 16 1920x1080 "$3" "$4" true
' bash "${repo_dir}/intel-hidpi.sh" "$post_lock_target_outside_path" "$post_lock_target_overrides_root" "$post_lock_target_state_root" 2>&1)"; then
    fail "apply must recheck a target symbolic link created after lock acquisition"
fi
assert_contains "$post_lock_target_output" "target path traverses a symbolic link"
assert_file_contents "$post_lock_target_outside_path" "post-lock external target"
[[ -L "$post_lock_target_path" ]] || fail "post-lock target link must remain in place"

post_lock_state_overrides_root="${scratch_dir}/post-lock-state-overrides"
post_lock_state_root="${scratch_dir}/post-lock-state-root"
post_lock_state_dir="${post_lock_state_root}/DisplayVendorID-17/DisplayProductID-18"
post_lock_state_outside_path="${scratch_dir}/post-lock-state-outside.plist"
post_lock_state_target_path="${post_lock_state_overrides_root}/DisplayVendorID-17/DisplayProductID-18"
printf 'post-lock external state\n' > "$post_lock_state_outside_path"
post_lock_state_output=""
if post_lock_state_output="$(/bin/bash -c '
    source "$1"
    state_dir="$2"
    race_outside="$3"
    acquire_display_lock() {
        /bin/mkdir -p "$state_dir" || return 1
        /bin/ln -s "$race_outside" "$state_dir/manifest.plist"
    }
    apply_override 17 18 1920x1080 "$4" "$5" true
' bash "${repo_dir}/intel-hidpi.sh" "$post_lock_state_dir" "$post_lock_state_outside_path" "$post_lock_state_overrides_root" "$post_lock_state_root" 2>&1)"; then
    fail "apply must recheck a state symbolic link created after lock acquisition"
fi
assert_contains "$post_lock_state_output" "target or state files traverse a symbolic link"
assert_file_contents "$post_lock_state_outside_path" "post-lock external state"
assert_file_absent "$post_lock_state_target_path"

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
failed_target_state_dir="${failed_target_state_vendor_dir}/DisplayProductID-1"
if "${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 1 \
    --native-resolution 1x1080 \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm >/dev/null 2>&1; then
    fail "invalid apply to a new target must fail explicitly"
fi
assert_directory_empty "$failed_target_vendor_dir"
assert_directory_empty "$failed_target_state_dir"

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
assert_directory_empty "${overrides_root}/DisplayVendorID-1"
assert_directory_empty "${state_root}/DisplayVendorID-1/DisplayProductID-1"
assert_directory_absent "${state_root}/DisplayVendorID-1/DisplayProductID-2"

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
    sleep 30 &
    lock_holder_sleep_pid=$!
    terminate_lock_holder() {
        /bin/kill -TERM "$lock_holder_sleep_pid" 2>/dev/null || true
        wait "$lock_holder_sleep_pid" 2>/dev/null || true
    }
    trap "terminate_lock_holder; exit 0" TERM INT
    wait "$lock_holder_sleep_pid"
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
