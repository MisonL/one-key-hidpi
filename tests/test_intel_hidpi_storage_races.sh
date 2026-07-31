#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
readonly REMOVE_RACE_FIXTURE_SIZE=256m
readonly REMOVE_RACE_WAIT_SECONDS=10
readonly INSTALL_IDENTITY_RACE_WAIT_SECONDS=60
readonly LSOF_WAIT_SECONDS=2

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local expected="$2"

    printf '%s\n' "$haystack" | /usr/bin/grep -Fq "$expected" || fail "missing expected text: ${expected}"
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

assert_file_hash() {
    local path="$1"
    local expected_hash="$2"

    [[ "$(sha256_file "$path")" == "$expected_hash" ]] || fail "expected ${path} hash to remain unchanged"
}

assert_directory_empty() {
    local path="$1"
    local first_entry

    [[ -d "$path" ]] || fail "expected directory: $path"
    first_entry="$(/usr/bin/find "$path" -mindepth 1 -maxdepth 1 -print -quit)" || fail "could not inspect directory: $path"
    [[ -z "$first_entry" ]] || fail "expected empty directory: $path"
}

assert_directory_exists() {
    [[ -d "$1" && ! -L "$1" ]] || fail "expected directory: $1"
}

assert_replace_uses_single_swap() {
    local replace_swap_count

    replace_swap_count="$(/usr/bin/awk '
        /^[[:space:]]*when "replace"/ { in_replace = 1; next }
        in_replace && /^[[:space:]]*when "remove"/ { exit }
        in_replace && /RENAME_SWAP/ { count++ }
        END { print count + 0 }
    ' "${repo_dir}/lib/intel_hidpi_darwin_fs.sh")" || fail "could not inspect replacement swap count"
    [[ "$replace_swap_count" == "1" ]] || fail "replacement must not issue a second swap after verification failure"
    if /usr/bin/grep -Fq 'restore_failed_swap' "${repo_dir}/lib/intel_hidpi_darwin_fs.sh" ||
        /usr/bin/grep -Fq 'restore_pre_swap_stage_replacement' "${repo_dir}/lib/intel_hidpi_darwin_fs.sh"; then
        fail "replacement must not reintroduce automatic swap recovery"
    fi
}

assert_copy_uses_descriptor_bound_new_file() {
    local copy_function

    /usr/bin/grep -Fq 'def copy_fd_to_new_file' "${repo_dir}/lib/intel_hidpi_darwin_fs.sh" ||
        fail "new-file installation must use a descriptor-bound copy helper"
    /usr/bin/grep -Fq 'target_fd = create_regular_file(target_directory_fd, target_name, 0o600)' "${repo_dir}/lib/intel_hidpi_darwin_fs.sh" ||
        fail "new-file installation must create the destination with O_EXCL before copying"
    copy_function="$(/usr/bin/awk '
        /def copy_fd_to_new_file/ { in_copy = 1 }
        in_copy { print }
        in_copy && /^        end$/ { exit }
    ' "${repo_dir}/lib/intel_hidpi_darwin_fs.sh")" || fail "could not inspect descriptor-bound copy helper"
    printf '%s\n' "$copy_function" | /usr/bin/grep -Fq 'DarwinSecureFs.fcopyfile(source_fd, target_fd, nil, COPYFILE_ALL)' ||
        fail "new-file installation must copy between the already-open descriptors"
    if /usr/bin/grep -Fq 'fclonefileat' "${repo_dir}/lib/intel_hidpi_darwin_fs.sh"; then
        fail "new-file installation must not reopen an fclonefileat destination by name"
    fi
}

find_ruby_holding_path() {
    local worker_pid="$1"
    local path="$2"
    local wait_seconds="${3:-$REMOVE_RACE_WAIT_SECONDS}"
    local observed_path
    local ruby_pid
    local deadline

    [[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
    deadline=$((SECONDS + wait_seconds))

    while ((SECONDS < deadline)); do
        [[ -e "$path" && ! -L "$path" ]] || {
            /bin/sleep 0.05
            continue
        }
        observed_path="$(/bin/realpath "$path")" || {
            /bin/sleep 0.05
            continue
        }
        while IFS= read -r ruby_pid; do
            [[ "$ruby_pid" =~ ^[0-9]+$ ]] || continue
            if lsof_reports_open_path "$ruby_pid" "$observed_path"; then
                printf '%s\n' "$ruby_pid"
                return 0
            fi
        done < <(/bin/ps -axo pid=,ppid=,comm= | LC_ALL=C /usr/bin/awk -v worker_pid="$worker_pid" '
            {
                parent[$1] = $2
                command[$1] = $3
            }
            END {
                descendant[worker_pid] = 1
                changed = 1
                while (changed) {
                    changed = 0
                    for (pid in parent) {
                        if (descendant[parent[pid]] && !descendant[pid]) {
                            descendant[pid] = 1
                            changed = 1
                        }
                    }
                }
                for (pid in descendant) {
                    if (pid != worker_pid && command[pid] ~ /ruby/) {
                        print pid
                    }
                }
            }
        ')
        /bin/sleep 0.05
    done
    return 1
}

wait_for_stopped_process() {
    local process_id="$1"
    local wait_seconds="$2"
    local process_state
    local deadline

    [[ "$process_id" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
    deadline=$((SECONDS + wait_seconds))

    while ((SECONDS < deadline)); do
        process_state="$(/bin/ps -p "$process_id" -o stat= 2>/dev/null)" || return 1
        [[ "$process_state" == *T* ]] && return 0
        /bin/sleep 0.05
    done
    return 1
}

lsof_reports_open_path() {
    local process_id="$1"
    local path="$2"
    local output_path
    local lsof_pid
    local deadline=$((SECONDS + LSOF_WAIT_SECONDS))
    local status
    local matched=false

    output_path="$(/usr/bin/mktemp "${scratch_dir}/.lsof.XXXXXX")" || return 1
    /usr/sbin/lsof -n -p "$process_id" >"$output_path" 2>/dev/null &
    lsof_pid=$!
    while /bin/kill -0 "$lsof_pid" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            /bin/kill -TERM "$lsof_pid" 2>/dev/null || true
            /bin/sleep 0.05
            /bin/kill -KILL "$lsof_pid" 2>/dev/null || true
            wait "$lsof_pid" 2>/dev/null || true
            /bin/rm -f "$output_path"
            return 1
        fi
        /bin/sleep 0.05
    done
    wait "$lsof_pid"
    status=$?
    if ((status == 0)) && /usr/bin/grep -Fq "$path" "$output_path"; then
        matched=true
    fi
    /bin/rm -f "$output_path" || return 1
    [[ "$matched" == true ]]
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

file_identity() {
    /usr/bin/stat -f '%d:%i' "$1"
}

create_pending_manifest() {
    local path="$1"

    /usr/bin/plutil -create xml1 "$path" || return 1
    /usr/bin/plutil -insert commit-state -string pending "$path" || return 1
    /usr/bin/plutil -insert candidate-file-identity -string "" "$path" || return 1
    /usr/bin/plutil -insert original-file-identity -string "" "$path" || return 1
    /usr/bin/plutil -insert candidate-persistent-identity -string "" "$path" || return 1
    /usr/bin/plutil -insert original-persistent-identity -string "" "$path"
}

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-races.XXXXXX")" || fail "could not create scratch directory"
install_race_worker_pid=""
install_race_ruby_pid=""
install_race_ruby_stopped=false
remove_race_ruby_pid=""
remove_race_ruby_stopped=false
remove_race_worker_pid=""
replace_content_race_worker_pid=""
replace_content_race_ruby_pid=""
replace_content_race_ruby_stopped=false
alias_lock_real_root=""

cleanup() {
    if [[ "$install_race_ruby_stopped" == true && -n "$install_race_ruby_pid" ]]; then
        /bin/kill -CONT "$install_race_ruby_pid" 2>/dev/null || true
    fi
    if [[ -n "$install_race_worker_pid" ]] && /bin/kill -0 "$install_race_worker_pid" 2>/dev/null; then
        /bin/kill -TERM "$install_race_worker_pid" 2>/dev/null || true
        if [[ -n "$install_race_ruby_pid" ]] && /bin/kill -0 "$install_race_ruby_pid" 2>/dev/null; then
            /bin/kill -TERM "$install_race_ruby_pid" 2>/dev/null || true
        fi
        wait "$install_race_worker_pid" 2>/dev/null || true
    fi
    if [[ "$remove_race_ruby_stopped" == true && -n "$remove_race_ruby_pid" ]]; then
        /bin/kill -CONT "$remove_race_ruby_pid" 2>/dev/null || true
    fi
    if [[ -n "$remove_race_worker_pid" ]] && /bin/kill -0 "$remove_race_worker_pid" 2>/dev/null; then
        /bin/kill -TERM "$remove_race_worker_pid" 2>/dev/null || true
        if [[ -n "$remove_race_ruby_pid" ]] && /bin/kill -0 "$remove_race_ruby_pid" 2>/dev/null; then
            /bin/kill -TERM "$remove_race_ruby_pid" 2>/dev/null || true
        fi
        wait "$remove_race_worker_pid" 2>/dev/null || true
    fi
    if [[ "$replace_content_race_ruby_stopped" == true && -n "$replace_content_race_ruby_pid" ]]; then
        /bin/kill -CONT "$replace_content_race_ruby_pid" 2>/dev/null || true
    fi
    if [[ -n "$replace_content_race_worker_pid" ]] && /bin/kill -0 "$replace_content_race_worker_pid" 2>/dev/null; then
        /bin/kill -TERM "$replace_content_race_worker_pid" 2>/dev/null || true
        if [[ -n "$replace_content_race_ruby_pid" ]] && /bin/kill -0 "$replace_content_race_ruby_pid" 2>/dev/null; then
            /bin/kill -TERM "$replace_content_race_ruby_pid" 2>/dev/null || true
        fi
        wait "$replace_content_race_worker_pid" 2>/dev/null || true
    fi
    case "$alias_lock_real_root" in
    /private/tmp/one-key-hidpi-alias-lock-*)
        /bin/rm -rf "$alias_lock_real_root"
        ;;
    esac
    /bin/rm -rf "$scratch_dir"
}
trap cleanup EXIT

assert_replace_uses_single_swap
assert_copy_uses_descriptor_bound_new_file

normalization_race_root="${scratch_dir}/normalization-race-root"
normalization_race_outside="${scratch_dir}/normalization-race-outside"
normalization_race_saved_root="${scratch_dir}/normalization-race-saved-root"
/bin/mkdir -p "$normalization_race_root" "$normalization_race_outside" || fail "could not prepare root-normalization race fixture"
normalization_race_normalized_root="$(/bin/bash -c '
    source "$1"
    normalize_storage_root "$2"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$normalization_race_root")" || fail "could not normalize root-normalization race fixture"
normalization_race_expected_root="$(/bin/bash -c '
    source "$1"
    lexical_root="$(normalize_lexical_path "$2")" || exit 1
    normalize_darwin_system_alias "$lexical_root"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$normalization_race_root")" || fail "could not calculate the lexical root-normalization expectation"
[[ "$normalization_race_normalized_root" == "$normalization_race_expected_root" ]] || fail "storage-root normalization must remain lexical"
normalization_race_child="${normalization_race_normalized_root}/child"
/bin/mv "$normalization_race_root" "$normalization_race_saved_root" || fail "could not move root-normalization race source"
/bin/ln -s "$normalization_race_outside" "$normalization_race_root" || fail "could not replace normalized root with a symbolic link"
if /bin/bash -c '
    source "$1"
    ensure_directory_path_without_symlinks "$2"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$normalization_race_child" >/dev/null 2>&1; then
    fail "descriptor-based directory creation must reject a root replaced by a symbolic link"
fi
assert_directory_empty "$normalization_race_outside"
[[ -L "$normalization_race_root" ]] || fail "root-normalization race link must remain in place"

directory_tracking_root="${scratch_dir}/directory-tracking"
directory_tracking_target="${directory_tracking_root}/created"
/bin/mkdir -p "$directory_tracking_root" || fail "could not prepare directory tracking fixture"
/bin/bash -c '
    source "$1"
    ensure_directory_path_without_symlinks "$2" || exit 1
    [[ -d "$2" && ! -L "$2" ]] || exit 2
    trap - EXIT
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_tracking_target" ||
    fail "directory creation must retain a directory whose ownership cannot be bound to an FD"
/bin/rmdir "$directory_tracking_target" "$directory_tracking_root" || fail "could not clean directory tracking fixture"

dangling_directory_link="${scratch_dir}/dangling-directory-link"
dangling_directory_target="${scratch_dir}/missing-directory-target"
/bin/ln -s "$dangling_directory_target" "$dangling_directory_link" || fail "could not create dangling directory link"
if /bin/bash -c '
    source "$1"
    directory_is_empty "$2"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$dangling_directory_link" >/dev/null 2>&1; then
    fail "directory checks must reject a dangling symbolic link"
fi
[[ -L "$dangling_directory_link" ]] || fail "dangling directory link must remain in place"

dangling_candidate_path="${scratch_dir}/dangling/DisplayProductID-1.candidate"
dangling_target_path="${scratch_dir}/dangling/DisplayProductID-1"
dangling_outside_path="${scratch_dir}/outside/missing-target"
/bin/mkdir -p "$(/usr/bin/dirname "$dangling_candidate_path")" || fail "could not prepare dangling-link fixture"
printf 'candidate\n' > "$dangling_candidate_path"
/bin/ln -s "$dangling_outside_path" "$dangling_target_path" || fail "could not create dangling target link"
if /bin/bash -c '
    source "$1"
    install_file_without_replacement "$2" "$3" "$(sha256_file "$2")" "$(darwin_file_identity "$2")"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$dangling_candidate_path" "$dangling_target_path" >/dev/null 2>&1; then
    fail "no-replacement install must reject a dangling target symbolic link"
fi
[[ -L "$dangling_target_path" ]] || fail "dangling target link must remain in place"
assert_file_absent "$dangling_outside_path"

candidate_hash_path="${scratch_dir}/candidate-hash/DisplayProductID-1.candidate"
candidate_hash_target_path="${scratch_dir}/candidate-hash/DisplayProductID-1"
/bin/mkdir -p "$(/usr/bin/dirname "$candidate_hash_path")" || fail "could not prepare candidate-hash fixture"
printf 'verified candidate\n' > "$candidate_hash_path"
candidate_expected_hash="$(sha256_file "$candidate_hash_path")"
candidate_expected_identity="$(file_identity "$candidate_hash_path")"
printf 'changed candidate\n' > "$candidate_hash_path"
if /bin/bash -c '
    source "$1"
    install_file_without_replacement "$2" "$3" "$4" "$5"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$candidate_hash_path" "$candidate_hash_target_path" "$candidate_expected_hash" "$candidate_expected_identity" >/dev/null 2>&1; then
    fail "no-replacement install must reject a candidate changed after hashing"
fi
assert_file_contents "$candidate_hash_path" "changed candidate"
assert_file_absent "$candidate_hash_target_path"

install_identity_target_path="${scratch_dir}/install-identity-target/DisplayProductID-1a"
install_identity_candidate_path="${scratch_dir}/install-identity-candidate/DisplayProductID-1a.candidate"
install_identity_state_dir="${scratch_dir}/install-identity-state/DisplayVendorID-1/DisplayProductID-1a"
install_identity_manifest_candidate_path="${install_identity_state_dir}/.manifest.candidate"
install_identity_manifest_path="${install_identity_state_dir}/manifest.plist"
install_identity_original_target_path="${scratch_dir}/install-identity-installed-target"
install_identity_worker_output="${scratch_dir}/install-identity-worker-output"
/bin/mkdir -p "$(/usr/bin/dirname "$install_identity_target_path")" "$(/usr/bin/dirname "$install_identity_candidate_path")" "$install_identity_state_dir" || fail "could not prepare install identity race fixture"
/usr/sbin/mkfile -n "$REMOVE_RACE_FIXTURE_SIZE" "$install_identity_candidate_path" || fail "could not create install identity race candidate"
create_pending_manifest "$install_identity_manifest_candidate_path" || fail "could not create install identity manifest candidate"
install_identity_candidate_hash="$(sha256_file "$install_identity_candidate_path")" || fail "could not hash install identity race candidate"
install_identity_candidate_identity="$(file_identity "$install_identity_candidate_path")" || fail "could not identify install identity race candidate"
install_identity_manifest_hash="$(sha256_file "$install_identity_manifest_candidate_path")" || fail "could not hash install identity manifest candidate"
install_identity_manifest_identity="$(file_identity "$install_identity_manifest_candidate_path")" || fail "could not identify install identity manifest candidate"
/bin/bash -c '
    source "$1"
    commit_apply_state "$2" "$3" false "" "" "$4" "$5" "$6" "$7" "$8" "" "$9" "${10}"
    operation_status=$?
    trap - EXIT
    exit "$operation_status"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" \
    "$install_identity_target_path" "$install_identity_candidate_path" "${install_identity_state_dir}/original.plist" \
    "$install_identity_manifest_candidate_path" "$install_identity_manifest_path" "$install_identity_candidate_hash" \
    "$install_identity_manifest_hash" "$install_identity_candidate_identity" "$install_identity_manifest_identity" >"$install_identity_worker_output" 2>&1 &
install_race_worker_pid=$!
install_race_ruby_pid="$(find_ruby_holding_path "$install_race_worker_pid" "$install_identity_target_path" "$INSTALL_IDENTITY_RACE_WAIT_SECONDS")" || {
    /bin/kill -TERM "$install_race_worker_pid" 2>/dev/null || true
    wait "$install_race_worker_pid" 2>/dev/null || true
    install_race_worker_pid=""
    fail "could not observe the installation holding the created target"
}
/bin/kill -STOP "$install_race_ruby_pid" || fail "could not pause the installation verification"
install_race_ruby_stopped=true
/bin/mv "$install_identity_target_path" "$install_identity_original_target_path" || {
    /bin/kill -CONT "$install_race_ruby_pid" 2>/dev/null || true
    install_race_ruby_stopped=false
    wait "$install_race_worker_pid" 2>/dev/null || true
    install_race_worker_pid=""
    fail "could not move the descriptor-bound install target"
}
/bin/cp "$install_identity_candidate_path" "$install_identity_target_path" || {
    /bin/kill -CONT "$install_race_ruby_pid" 2>/dev/null || true
    install_race_ruby_stopped=false
    wait "$install_race_worker_pid" 2>/dev/null || true
    install_race_worker_pid=""
    fail "could not create the competing same-content install target"
}
/bin/kill -CONT "$install_race_ruby_pid" || fail "could not resume the installation verification"
install_race_ruby_stopped=false
install_identity_created_target_identity="$(file_identity "$install_identity_original_target_path")" || fail "could not identify the descriptor-bound install target"
install_identity_competing_target_identity="$(file_identity "$install_identity_target_path")" || fail "could not identify the competing install target"
[[ "$install_identity_competing_target_identity" != "$install_identity_created_target_identity" ]] || fail "same-content install replacement must use a different inode"
if wait "$install_race_worker_pid"; then
    install_race_worker_pid=""
    fail "install must reject a same-content target replacement after creation"
fi
install_race_worker_pid=""
assert_contains "$(/bin/cat "$install_identity_worker_output")" "target installation may have completed before verification failed; state was retained for manual inspection"
assert_file_hash "$install_identity_target_path" "$install_identity_candidate_hash"
[[ "$(file_identity "$install_identity_target_path")" == "$install_identity_competing_target_identity" ]] || fail "install must retain the competing target path"
assert_file_hash "$install_identity_original_target_path" "$install_identity_candidate_hash"
[[ "$(file_identity "$install_identity_original_target_path")" == "$install_identity_created_target_identity" ]] || fail "install must retain the descriptor-bound target artifact"
assert_file_exists "$install_identity_manifest_path"
[[ "$(/usr/bin/plutil -extract commit-state raw -o - "$install_identity_manifest_path")" == pending ]] || fail "same-content install race must retain a pending manifest"
install_identity_manifest_candidate_identity="$(/usr/bin/plutil -extract candidate-file-identity raw -o - "$install_identity_manifest_path")" || fail "could not read pending manifest candidate identity"
[[ -z "$install_identity_manifest_candidate_identity" ]] || fail "pending manifest must not record the competing target identity"

backup_target_path="${scratch_dir}/backup-target/DisplayProductID-2"
backup_candidate_path="${scratch_dir}/backup-target/.DisplayProductID-2.candidate"
backup_candidate_original_path="${scratch_dir}/backup-state/DisplayVendorID-1/DisplayProductID-2/.original.candidate"
backup_state_dir="${scratch_dir}/backup-state/DisplayVendorID-1/DisplayProductID-2"
backup_original_path="${backup_state_dir}/original.plist"
backup_manifest_candidate_path="${backup_state_dir}/.manifest.candidate"
backup_manifest_path="${backup_state_dir}/manifest.plist"
/bin/mkdir -p "$(/usr/bin/dirname "$backup_target_path")" "$backup_state_dir" || fail "could not prepare backup collision fixture"
printf 'original target\n' > "$backup_target_path"
printf 'candidate target\n' > "$backup_candidate_path"
/bin/cp "$backup_target_path" "$backup_candidate_original_path" || fail "could not prepare exact backup collision candidate"
printf 'competing original\n' > "$backup_original_path"
printf 'manifest candidate\n' > "$backup_manifest_candidate_path"
backup_collision_output=""
if backup_collision_output="$(/bin/bash -c '
    source "$1"
    candidate_hash="$(sha256_file "$3")"
    manifest_hash="$(sha256_file "$7")"
    original_identity="$(darwin_file_identity "$2")"
    candidate_identity="$(darwin_file_identity "$3")"
    manifest_identity="$(darwin_file_identity "$7")"
    commit_apply_state "$2" "$3" true "$4" "$5" "$6" "$7" "$8" "$candidate_hash" "$manifest_hash" "$original_identity" "$candidate_identity" "$manifest_identity" "$(darwin_file_persistent_identity "$2")"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" \
    "$backup_target_path" "$backup_candidate_path" "$(sha256_file "$backup_target_path")" \
    "$backup_candidate_original_path" "$backup_original_path" "$backup_manifest_candidate_path" "$backup_manifest_path" 2>&1)"; then
    fail "existing-target commit must reject a competing original backup"
fi
assert_contains "$backup_collision_output" "could not store exact original backup without replacement"
assert_file_contents "$backup_target_path" "original target"
assert_file_contents "$backup_original_path" "competing original"
assert_file_absent "$backup_manifest_path"

manifest_hash_target_path="${scratch_dir}/manifest-hash-target/DisplayProductID-21"
manifest_hash_candidate_path="${scratch_dir}/manifest-hash-target/.DisplayProductID-21.candidate"
manifest_hash_backup_candidate_path="${scratch_dir}/manifest-hash-state/DisplayVendorID-1/DisplayProductID-21/.original.candidate"
manifest_hash_state_dir="${scratch_dir}/manifest-hash-state/DisplayVendorID-1/DisplayProductID-21"
manifest_hash_original_path="${manifest_hash_state_dir}/original.plist"
manifest_hash_candidate_manifest_path="${manifest_hash_state_dir}/.manifest.candidate"
manifest_hash_path="${manifest_hash_state_dir}/manifest.plist"
/bin/mkdir -p "$(/usr/bin/dirname "$manifest_hash_target_path")" "$manifest_hash_state_dir" || fail "could not prepare manifest-hash race fixture"
printf 'original target\n' > "$manifest_hash_target_path"
printf 'candidate target\n' > "$manifest_hash_candidate_path"
/bin/cp "$manifest_hash_target_path" "$manifest_hash_backup_candidate_path"
printf 'candidate manifest\n' > "$manifest_hash_candidate_manifest_path"
manifest_candidate_hash="$(sha256_file "$manifest_hash_candidate_manifest_path")"
manifest_hash_output=""
if manifest_hash_output="$(/bin/bash -c '
    source "$1"
    manifest_candidate="$2"
    eval "$(declare -f install_file_without_replacement | /usr/bin/sed 's/^install_file_without_replacement/original_install_file_without_replacement/')"
    install_file_without_replacement() {
        if [[ "$1" == "$manifest_candidate" ]]; then
            printf "modified manifest candidate\\n" > "$1"
        fi
        original_install_file_without_replacement "$@"
    }
    original_identity="$(darwin_file_identity "$4")"
    candidate_identity="$(darwin_file_identity "$5")"
    manifest_identity="$(darwin_file_identity "$2")"
    commit_apply_state "$4" "$5" true "$6" "$7" "$8" "$2" "$9" "${10}" "$3" "$original_identity" "$candidate_identity" "$manifest_identity" "$(darwin_file_persistent_identity "$4")"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$manifest_hash_candidate_manifest_path" "$manifest_candidate_hash" \
    "$manifest_hash_target_path" "$manifest_hash_candidate_path" "$(sha256_file "$manifest_hash_target_path")" \
    "$manifest_hash_backup_candidate_path" "$manifest_hash_original_path" "$manifest_hash_path" "$(sha256_file "$manifest_hash_candidate_path")" 2>&1)"; then
    fail "commit must reject a manifest candidate changed before installation"
fi
assert_contains "$manifest_hash_output" "could not install verified manifest without replacement"
assert_file_contents "$manifest_hash_target_path" "original target"
assert_file_contents "$manifest_hash_original_path" "original target"
assert_file_absent "$manifest_hash_path"

replace_target_path="${scratch_dir}/replace-target/DisplayProductID-3"
replace_candidate_path="${scratch_dir}/replace-target/.DisplayProductID-3.candidate"
replace_backup_candidate_path="${scratch_dir}/replace-state/DisplayVendorID-1/DisplayProductID-3/.original.candidate"
replace_state_dir="${scratch_dir}/replace-state/DisplayVendorID-1/DisplayProductID-3"
replace_original_path="${replace_state_dir}/original.plist"
replace_manifest_candidate_path="${replace_state_dir}/.manifest.candidate"
replace_manifest_path="${replace_state_dir}/manifest.plist"
replace_outside_dir="${scratch_dir}/replace-outside"
/bin/mkdir -p "$(/usr/bin/dirname "$replace_target_path")" "$replace_state_dir" "$replace_outside_dir" || fail "could not prepare replacement-link fixture"
printf 'original target\n' > "$replace_target_path"
printf 'candidate target\n' > "$replace_candidate_path"
/bin/cp "$replace_target_path" "$replace_backup_candidate_path" || fail "could not prepare exact replacement backup candidate"
create_pending_manifest "$replace_manifest_candidate_path" || fail "could not prepare pending manifest fixture"
replace_output=""
if replace_output="$(/bin/bash -c '
    source "$1"
    race_outside="$2"
    target_matches_calls=0
    target_matches_pre_apply_state() {
        target_matches_calls=$((target_matches_calls + 1))
        if ((target_matches_calls == 2)); then
            /bin/rm -f "$1" || return 1
            /bin/ln -s "$race_outside" "$1" || return 1
        fi
        return 0
    }
    original_hash="$(sha256_file "$3")"
    candidate_hash="$(sha256_file "$4")"
    manifest_hash="$(sha256_file "$7")"
    original_identity="$(darwin_file_identity "$3")"
    candidate_identity="$(darwin_file_identity "$4")"
    manifest_identity="$(darwin_file_identity "$7")"
    commit_apply_state "$3" "$4" true "$original_hash" "$5" "$6" "$7" "$8" "$candidate_hash" "$manifest_hash" "$original_identity" "$candidate_identity" "$manifest_identity" "$(darwin_file_persistent_identity "$3")"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$replace_outside_dir" \
    "$replace_target_path" "$replace_candidate_path" "$replace_backup_candidate_path" \
    "$replace_original_path" "$replace_manifest_candidate_path" "$replace_manifest_path" 2>&1)"; then
    fail "existing-target commit must reject a post-validation directory symbolic link"
fi
assert_contains "$replace_output" "could not atomically replace target override"
assert_directory_empty "$replace_outside_dir"
[[ -L "$replace_target_path" ]] || fail "existing-target commit must preserve the raced target link"
assert_file_contents "$replace_original_path" "original target"
[[ "$(/usr/bin/plutil -extract commit-state raw -o - "$replace_manifest_path")" == pending ]] || fail "replacement race must retain a pending manifest"

cleanup_regular_path="${scratch_dir}/cleanup-regular-file"
printf 'owned temporary artifact\n' > "$cleanup_regular_path"
cleanup_regular_hash="$(sha256_file "$cleanup_regular_path")"
cleanup_regular_identity="$(file_identity "$cleanup_regular_path")"
/bin/bash -c '
    source "$1"
    TEMPORARY_FILES=("$2")
    TEMPORARY_FILE_HASHES=("$3")
    TEMPORARY_FILE_IDENTITIES=("$4")
    cleanup_temporary_files || exit 1
    TEMPORARY_FILES=("")
    TEMPORARY_FILE_HASHES=("")
    TEMPORARY_FILE_IDENTITIES=("")
    trap - EXIT
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$cleanup_regular_path" "$cleanup_regular_hash" "$cleanup_regular_identity" || fail "temporary cleanup must remove an unchanged owned file"
assert_file_absent "$cleanup_regular_path"

remove_race_target_path="${scratch_dir}/remove-race-target"
remove_race_original_path="${scratch_dir}/remove-race-original"
remove_race_worker_output="${scratch_dir}/remove-race-worker-output"
/usr/sbin/mkfile -n "$REMOVE_RACE_FIXTURE_SIZE" "$remove_race_target_path" || fail "could not create remove race target"
remove_race_hash="$(sha256_file "$remove_race_target_path")" || fail "could not hash remove race target"
remove_race_identity="$(file_identity "$remove_race_target_path")" || fail "could not identify remove race target"
/bin/bash -c '
    source "$1"
    darwin_remove_file_if_unchanged "$2" "$3" "$4"
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$remove_race_target_path" "$remove_race_hash" "$remove_race_identity" >"$remove_race_worker_output" 2>&1 &
remove_race_worker_pid=$!
remove_race_ruby_pid="$(find_ruby_holding_path "$remove_race_worker_pid" "$remove_race_target_path")" || {
    /bin/kill "$remove_race_worker_pid" 2>/dev/null || true
    wait "$remove_race_worker_pid" 2>/dev/null || true
    fail "could not observe the remove operation holding the target file"
}
/bin/kill -STOP "$remove_race_ruby_pid" || fail "could not pause the remove operation"
remove_race_ruby_stopped=true
/bin/mv "$remove_race_target_path" "$remove_race_original_path" || {
    /bin/kill -CONT "$remove_race_ruby_pid" 2>/dev/null || true
    remove_race_ruby_stopped=false
    wait "$remove_race_worker_pid" 2>/dev/null || true
    fail "could not move the original target for the remove race"
}
/bin/mkdir "$remove_race_target_path" || {
    /bin/kill -CONT "$remove_race_ruby_pid" 2>/dev/null || true
    remove_race_ruby_stopped=false
    wait "$remove_race_worker_pid" 2>/dev/null || true
    fail "could not create the competing remove-race directory"
}
printf 'competing remove directory\n' > "${remove_race_target_path}/sentinel" || fail "could not create remove-race sentinel"
/bin/kill -CONT "$remove_race_ruby_pid" || fail "could not resume the remove operation"
remove_race_ruby_stopped=false
if wait "$remove_race_worker_pid"; then
    fail "remove must reject a target changed to a directory after opening"
fi
remove_race_worker_pid=""
assert_file_hash "$remove_race_original_path" "$remove_race_hash"
assert_directory_exists "$remove_race_target_path"
assert_file_contents "${remove_race_target_path}/sentinel" "competing remove directory"
remove_race_quarantine_path="$(/usr/bin/find "$scratch_dir" -maxdepth 1 -name '.one-key-hidpi-quarantine-*' -print -quit)" || fail "could not inspect remove-race quarantine"
[[ -z "$remove_race_quarantine_path" ]] || fail "remove race must not retain a hidden quarantine entry"

temporary_init_directory="${scratch_dir}/temporary-init"
/bin/mkdir "$temporary_init_directory" || fail "could not prepare temporary initialization fixture"
/bin/bash -c '
    source "$1"
    OPERATION_TEMPORARY_DIRECTORY="$2"
    darwin_file_snapshot() {
        return 1
    }
    if create_temporary_file "init-failure"; then
        exit 1
    fi
    [[ ${#TEMPORARY_FILES[@]} -eq 2 ]] || exit 2
    temporary_file="${TEMPORARY_FILES[1]}"
    [[ -f "$temporary_file" ]] || exit 3
    cleanup_temporary_files >/dev/null 2>&1 && exit 4
    [[ -f "$temporary_file" ]] || exit 5
    TEMPORARY_FILES=("")
    TEMPORARY_FILE_HASHES=("")
    TEMPORARY_FILE_IDENTITIES=("")
    trap - EXIT
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$temporary_init_directory" ||
    fail "temporary initialization failure must retain a tracked artifact"
temporary_init_entry="$(/usr/bin/find "$temporary_init_directory" -mindepth 1 -maxdepth 1 -print -quit)" || fail "could not inspect temporary initialization fixture"
[[ -n "$temporary_init_entry" ]] || fail "temporary initialization failure must leave recovery evidence"

directory_init_root="${scratch_dir}/directory-init"
directory_init_created="${directory_init_root}/created"
directory_init_component="$(/usr/bin/perl -e 'print "x" x 256')"
directory_init_target="${directory_init_created}/${directory_init_component}"
/bin/mkdir -p "$directory_init_root" || fail "could not prepare directory initialization fixture"
/bin/bash -c '
    source "$1"
    if ensure_directory_path_without_symlinks "$2"; then
        exit 1
    fi
    [[ -d "$3" && ! -L "$3" ]] || exit 2
    trap - EXIT
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_init_target" "$directory_init_created" ||
    fail "directory initialization failure must retain an unowned created directory"
/bin/rmdir "$directory_init_created" "$directory_init_root" || fail "could not clean directory initialization fixture"

directory_identity_root="${scratch_dir}/directory-identity"
directory_identity_target="${directory_identity_root}/created"
/bin/mkdir -p "$directory_identity_root" || fail "could not prepare directory identity fixture"
/bin/bash -c '
    source "$1"
    ensure_directory_path_without_symlinks "$2" || exit 1
    /bin/rmdir "$2" || exit 2
    /bin/mkdir "$2" || exit 3
    complete_operation_cleanup || exit 4
    [[ -d "$2" && ! -L "$2" ]] || exit 5
    /bin/rmdir "$2" || exit 6
    /bin/rmdir "$(/usr/bin/dirname "$2")" || exit 7
    trap - EXIT
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_identity_target" ||
    fail "operation cleanup must not claim a replaced directory"

directory_empty_root="${scratch_dir}/directory-empty"
directory_empty_target="${directory_empty_root}/owned"
/bin/mkdir -p "$directory_empty_target" || fail "could not prepare verified directory cleanup fixture"
directory_empty_identity="$(/bin/bash -c 'source "$1"; darwin_directory_identity "$2"' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_empty_target")" ||
    fail "could not identify verified directory cleanup fixture"
/bin/bash -c '
    source "$1"
    darwin_remove_empty_directory_if_unchanged "$2" "$3"
    trap - EXIT
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_empty_target" "$directory_empty_identity" ||
    fail "verified directory cleanup must remove an unchanged empty directory"
assert_file_absent "$directory_empty_target"

directory_nonempty_root="${scratch_dir}/directory-nonempty"
directory_nonempty_target="${directory_nonempty_root}/owned"
/bin/mkdir -p "$directory_nonempty_target" || fail "could not prepare nonempty directory cleanup fixture"
printf 'competing directory entry\n' > "${directory_nonempty_target}/sentinel" || fail "could not prepare nonempty directory sentinel"
directory_nonempty_identity="$(/bin/bash -c 'source "$1"; darwin_directory_identity "$2"' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_nonempty_target")" ||
    fail "could not identify nonempty directory cleanup fixture"
directory_nonempty_output=""
if directory_nonempty_output="$(/bin/bash -c '
    source "$1"
    if darwin_remove_empty_directory_if_unchanged "$2" "$3"; then
        trap - EXIT
        exit 0
    fi
    trap - EXIT
    exit 1
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_nonempty_target" "$directory_nonempty_identity" 2>&1)"; then
    fail "verified directory cleanup must reject a nonempty directory"
fi
assert_contains "$directory_nonempty_output" "directory cleanup was not empty; retained directory"
assert_directory_exists "$directory_nonempty_target"
assert_file_contents "${directory_nonempty_target}/sentinel" "competing directory entry"
directory_nonempty_quarantine="$(/usr/bin/find "$directory_nonempty_root" -maxdepth 1 -name '.one-key-hidpi-directory-quarantine-*' -print -quit)" || fail "could not inspect nonempty directory quarantine"
[[ -z "$directory_nonempty_quarantine" ]] || fail "nonempty directory cleanup must restore the original path"

alias_lock_candidate_root="/private/tmp/one-key-hidpi-alias-lock-${scratch_dir##*/}"
alias_lock_root="/tmp/${alias_lock_candidate_root#/private/tmp/}"
[[ ! -e "$alias_lock_candidate_root" && ! -L "$alias_lock_candidate_root" ]] || fail "could not prepare an absent /tmp alias lock root"
alias_lock_real_root="$alias_lock_candidate_root"
/bin/bash -c '
    source "$1"
    raw_root="$2"
    reset_operation_cleanup_state
    acquire_display_lock "$raw_root" aa bb || exit 1
    [[ "$OPERATION_LOCK_PATH" == "${raw_root}/.one-key-hidpi-locks/DisplayVendorID-aa-DisplayProductID-bb.lock" ]] || exit 2
    release_display_lock || exit 3
    [[ -d "${raw_root}/.one-key-hidpi-locks" && ! -L "${raw_root}/.one-key-hidpi-locks" ]] || exit 4
    [[ -z "$(/usr/bin/find "${raw_root}/.one-key-hidpi-locks" -mindepth 1 -maxdepth 1 -print -quit)" ]] || exit 5
    /bin/rmdir "${raw_root}/.one-key-hidpi-locks" "$raw_root" || exit 6
    reset_operation_cleanup_state
    trap - EXIT
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$alias_lock_root" ||
    fail "/tmp aliases must retain an unowned lock directory after release"

cleanup_changed_path="${scratch_dir}/cleanup-changed-file"
printf 'owned temporary artifact\n' > "$cleanup_changed_path"
cleanup_changed_hash="$(sha256_file "$cleanup_changed_path")"
cleanup_changed_identity="$(file_identity "$cleanup_changed_path")"
printf 'competing replacement\n' > "$cleanup_changed_path"
cleanup_changed_output=""
if cleanup_changed_output="$(/bin/bash -c '
    source "$1"
    TEMPORARY_FILES=("$2")
    TEMPORARY_FILE_HASHES=("$3")
    TEMPORARY_FILE_IDENTITIES=("$4")
    if cleanup_temporary_files; then
        exit 0
    fi
    TEMPORARY_FILES=("")
    TEMPORARY_FILE_HASHES=("")
    TEMPORARY_FILE_IDENTITIES=("")
    trap - EXIT
    exit 1
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$cleanup_changed_path" "$cleanup_changed_hash" "$cleanup_changed_identity" 2>&1)"; then
    fail "temporary cleanup must retain a changed candidate"
fi
assert_contains "$cleanup_changed_output" "refusing to remove a changed temporary artifact"
assert_file_contents "$cleanup_changed_path" "competing replacement"

lock_cleanup_path="${scratch_dir}/cleanup-lock"
printf '%s\n' "$$" > "$lock_cleanup_path"
lock_cleanup_hash="$(sha256_file "$lock_cleanup_path")"
lock_cleanup_identity="$(file_identity "$lock_cleanup_path")"
printf 'competing lock owner\n' > "$lock_cleanup_path"
lock_cleanup_output=""
if lock_cleanup_output="$(/bin/bash -c '
    source "$1"
    OPERATION_LOCK_PATH="$2"
    OPERATION_LOCK_HASH="$3"
    OPERATION_LOCK_IDENTITY="$4"
    if release_display_lock; then
        exit 0
    fi
    OPERATION_LOCK_PATH=""
    OPERATION_LOCK_HASH=""
    OPERATION_LOCK_IDENTITY=""
    trap - EXIT
    exit 1
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$lock_cleanup_path" "$lock_cleanup_hash" "$lock_cleanup_identity" 2>&1)"; then
    fail "lock cleanup must retain a changed lock"
fi
[[ -z "$lock_cleanup_output" ]] || fail "changed lock cleanup should fail without extra output"
assert_file_contents "$lock_cleanup_path" "competing lock owner"

directory_replace_candidate_path="${scratch_dir}/directory-replace-candidate"
directory_replace_target_path="${scratch_dir}/directory-replace-target"
printf 'candidate target\n' > "$directory_replace_candidate_path"
printf 'original target\n' > "$directory_replace_target_path"
directory_replace_output=""
if directory_replace_output="$(/bin/bash -c '
    source "$1"
    candidate_path="$2"
    target_path="$3"
    target_hash="$(/usr/bin/shasum -a 256 "$target_path" | /usr/bin/awk '\''{print $1}'\'')"
    candidate_hash="$(/usr/bin/shasum -a 256 "$candidate_path" | /usr/bin/awk '\''{print $1}'\'')"
    target_identity="$(darwin_file_identity "$target_path")"
    candidate_identity="$(darwin_file_identity "$candidate_path")"
    race_armed=true
    set -o functrace
    race_before_replace() {
        case "$BASH_COMMAND" in
        *"/usr/bin/ruby -rfiddle -rfiddle/import"*)
            if [[ "$race_armed" == true ]]; then
                race_armed=false
                trap - DEBUG
                /bin/rm "$target_path" || return 1
                /bin/mkdir "$target_path" || return 1
            fi
            ;;
        esac
    }
    trap race_before_replace DEBUG
    if replace_file_without_following_directory_link "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity" "$target_hash" "$target_identity"; then
        exit 0
    fi
    exit 1
' bash "${repo_dir}/lib/intel_hidpi_storage.sh" "$directory_replace_candidate_path" "$directory_replace_target_path" 2>&1)"; then
    fail "replacement must reject a target that becomes a directory after validation"
fi
[[ -z "$directory_replace_output" ]] || fail "directory replacement should fail without writing an error"
assert_file_contents "$directory_replace_candidate_path" "candidate target"
assert_directory_exists "$directory_replace_target_path"
assert_directory_empty "$directory_replace_target_path"

pre_swap_directory_root="$scratch_dir/pre-swap-directory"
pre_swap_directory_candidate_path="$pre_swap_directory_root/candidate"
pre_swap_directory_target_path="$pre_swap_directory_root/target"
# Hashing the staged candidate creates a reproducible interval between cloning
# and the first swap. The attacker must not be able to exchange its directory
# into target during that interval.
/bin/mkdir -p "$pre_swap_directory_root" || fail "could not create pre-swap staged race directory"
/bin/dd if=/dev/zero of="$pre_swap_directory_candidate_path" bs=1048576 count=64 >/dev/null 2>&1 || fail "could not create pre-swap staged race candidate"
printf 'original target\n' > "$pre_swap_directory_target_path"
pre_swap_directory_original_hash="$(sha256_file "$pre_swap_directory_target_path")"
pre_swap_directory_candidate_hash="$(sha256_file "$pre_swap_directory_candidate_path")"
pre_swap_directory_output=""
if ! pre_swap_directory_output="$(/bin/bash -c '
    source "$1"
    candidate_path="$2"
    target_path="$3"
    target_hash="$(sha256_file "$target_path")"
    candidate_hash="$(sha256_file "$candidate_path")"
    target_identity="$(darwin_file_identity "$target_path")"
    candidate_identity="$(darwin_file_identity "$candidate_path")"
    (
        deadline=$((SECONDS + 10))
        while ((SECONDS < deadline)); do
            for staged_path in "$(/usr/bin/dirname "$target_path")"/.one-key-hidpi-stage-*; do
                [[ -f "$staged_path" && ! -L "$staged_path" ]] || continue
                /bin/rm -f "$staged_path" || exit 2
                /bin/mkdir "$staged_path" || exit 3
                printf "competing pre-swap staged directory\n" > "$staged_path/sentinel" || exit 4
                exit 0
            done
        done
        exit 5
    ) &
    attacker_pid=$!
    replace_file_without_following_directory_link "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity" "$target_hash" "$target_identity"
    operation_status=$?
    if ((operation_status == 0)); then
        wait "$attacker_pid"
        exit 1
    fi
    wait "$attacker_pid" || exit 2
    [[ "$operation_status" -eq 2 ]] || exit 3
' bash "$repo_dir/lib/intel_hidpi_storage.sh" "$pre_swap_directory_candidate_path" "$pre_swap_directory_target_path" 2>&1)"; then
    fail "replacement must refuse a staged path replaced before the first swap"
fi
assert_contains "$pre_swap_directory_output" "replacement did not start and staged recovery artifact was retained"
assert_file_hash "$pre_swap_directory_target_path" "$pre_swap_directory_original_hash"
assert_file_hash "$pre_swap_directory_candidate_path" "$pre_swap_directory_candidate_hash"
pre_swap_directory_stage_path="$(/usr/bin/find "$(/usr/bin/dirname "$pre_swap_directory_target_path")" -maxdepth 1 -name '.one-key-hidpi-stage-*' -print -quit)" || fail "could not inspect pre-swap staged race directory"
[[ -n "$pre_swap_directory_stage_path" ]] || fail "pre-swap staged replacement must be retained"
assert_directory_exists "$pre_swap_directory_stage_path"
assert_file_contents "$pre_swap_directory_stage_path/sentinel" "competing pre-swap staged directory"

pre_swap_content_root="$scratch_dir/pre-swap-content"
pre_swap_content_candidate_path="$pre_swap_content_root/candidate"
pre_swap_content_target_path="$pre_swap_content_root/target"
/bin/mkdir -p "$pre_swap_content_root" || fail "could not create pre-swap content race directory"
/usr/sbin/mkfile -n "$REMOVE_RACE_FIXTURE_SIZE" "$pre_swap_content_candidate_path" || fail "could not create pre-swap content race candidate"
printf 'original target\n' > "$pre_swap_content_target_path"
pre_swap_content_candidate_hash="$(sha256_file "$pre_swap_content_candidate_path")"
pre_swap_content_target_identity="$(file_identity "$pre_swap_content_target_path")"
pre_swap_content_worker_output="$pre_swap_content_root/worker-output"
/bin/bash -c '
    source "$1"
    candidate_path="$2"
    target_path="$3"
    target_hash="$(sha256_file "$target_path")"
    candidate_hash="$(sha256_file "$candidate_path")"
    target_identity="$(darwin_file_identity "$target_path")"
    candidate_identity="$(darwin_file_identity "$candidate_path")"
    replace_file_without_following_directory_link "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity" "$target_hash" "$target_identity"
    exit $?
' bash "$repo_dir/lib/intel_hidpi_storage.sh" "$pre_swap_content_candidate_path" "$pre_swap_content_target_path" >"$pre_swap_content_worker_output" 2>&1 &
replace_content_race_worker_pid=$!
replace_content_race_ruby_pid="$(find_ruby_holding_path "$replace_content_race_worker_pid" "$pre_swap_content_target_path" "$INSTALL_IDENTITY_RACE_WAIT_SECONDS")" || {
    /bin/kill -TERM "$replace_content_race_worker_pid" 2>/dev/null || true
    wait "$replace_content_race_worker_pid" 2>/dev/null || true
    replace_content_race_worker_pid=""
    fail "could not observe replacement holding the target before the content race"
}
pre_swap_content_stage_path=""
pre_swap_content_deadline=$((SECONDS + REMOVE_RACE_WAIT_SECONDS))
while ((SECONDS < pre_swap_content_deadline)); do
    for staged_path in "$pre_swap_content_root"/.one-key-hidpi-stage-*; do
        [[ -f "$staged_path" && ! -L "$staged_path" ]] || continue
        target_first_byte="$(/usr/bin/od -An -tx1 -N1 "$pre_swap_content_target_path" | /usr/bin/tr -d '[:space:]')" || continue
        [[ "$target_first_byte" == "6f" ]] || continue
        /bin/kill -STOP "$replace_content_race_ruby_pid" || fail "could not pause replacement before the first swap"
        replace_content_race_ruby_stopped=true
        target_first_byte="$(/usr/bin/od -An -tx1 -N1 "$pre_swap_content_target_path" | /usr/bin/tr -d '[:space:]')" || fail "could not inspect paused replacement target"
        [[ "$target_first_byte" == "6f" ]] || fail "replacement advanced beyond the first swap before it could be paused"
        pre_swap_content_stage_path="$staged_path"
        break 2
    done
    /bin/sleep 0.01
done
[[ -n "$pre_swap_content_stage_path" ]] || fail "could not observe a staged replacement before the first swap"
printf 'competing target\n' > "$pre_swap_content_target_path" || fail "could not mutate target contents during the pre-swap race"
[[ "$(file_identity "$pre_swap_content_target_path")" == "$pre_swap_content_target_identity" ]] || fail "pre-swap target mutation must retain the target inode"
/bin/kill -CONT "$replace_content_race_ruby_pid" || fail "could not resume replacement after the content race"
replace_content_race_ruby_stopped=false
if wait "$replace_content_race_worker_pid"; then
    replace_content_race_worker_pid=""
    fail "replacement must reject a target changed in place before the first swap"
fi
replace_content_race_worker_pid=""
pre_swap_content_output="$(/bin/cat "$pre_swap_content_worker_output")"
assert_contains "$pre_swap_content_output" "replacement did not start because target changed before swap"
assert_file_contents "$pre_swap_content_target_path" "competing target"
[[ "$(file_identity "$pre_swap_content_target_path")" == "$pre_swap_content_target_identity" ]] || fail "in-place target mutation must retain the target inode"
assert_file_hash "$pre_swap_content_candidate_path" "$pre_swap_content_candidate_hash"
pre_swap_content_remaining_stage_path="$(/usr/bin/find "$pre_swap_content_root" -maxdepth 1 -name '.one-key-hidpi-stage-*' -print -quit)" || fail "could not inspect pre-swap content race directory"
[[ -z "$pre_swap_content_remaining_stage_path" ]] || fail "unchanged staged candidate must be cleaned after a target content race"

pre_swap_staged_content_root="$scratch_dir/pre-swap-staged-content"
pre_swap_staged_content_candidate_path="$pre_swap_staged_content_root/candidate"
pre_swap_staged_content_target_path="$pre_swap_staged_content_root/target"
/bin/mkdir -p "$pre_swap_staged_content_root" || fail "could not create pre-swap staged-content race directory"
/usr/sbin/mkfile -n "$REMOVE_RACE_FIXTURE_SIZE" "$pre_swap_staged_content_candidate_path" || fail "could not create pre-swap staged-content race candidate"
printf 'original target\n' > "$pre_swap_staged_content_target_path"
pre_swap_staged_content_candidate_hash="$(sha256_file "$pre_swap_staged_content_candidate_path")"
pre_swap_staged_content_target_hash="$(sha256_file "$pre_swap_staged_content_target_path")"
pre_swap_staged_content_worker_output="$pre_swap_staged_content_root/worker-output"
pre_swap_staged_content_darwin_fs_path="$pre_swap_staged_content_root/intel_hidpi_darwin_fs.sh"
# Use a temporary copy of the FFI helper to stop immediately after the initial
# staged-content hash. This lets the fixture exercise the second pre-swap hash
# without racing the descriptor-bound copy itself.
/usr/bin/awk '
    /^[[:space:]]*Failure\.raise_failure unless expected_sha256\?\(staged_fd, expected_source_hash\)$/ {
        count += 1
        print
        print "            Process.kill(\"STOP\", Process.pid)"
        next
    }
    { print }
    END { exit(count == 1 ? 0 : 1) }
' "$repo_dir/lib/intel_hidpi_darwin_fs.sh" > "$pre_swap_staged_content_darwin_fs_path" || fail "could not prepare staged-content race helper"
/bin/bash -c '
    source "$1"
    source "$2"
    candidate_path="$3"
    target_path="$4"
    target_hash="$(sha256_file "$target_path")"
    candidate_hash="$(sha256_file "$candidate_path")"
    target_identity="$(darwin_file_identity "$target_path")"
    candidate_identity="$(darwin_file_identity "$candidate_path")"
    replace_file_without_following_directory_link "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity" "$target_hash" "$target_identity"
    exit $?
' bash "$repo_dir/lib/intel_hidpi_storage.sh" "$pre_swap_staged_content_darwin_fs_path" "$pre_swap_staged_content_candidate_path" "$pre_swap_staged_content_target_path" >"$pre_swap_staged_content_worker_output" 2>&1 &
replace_content_race_worker_pid=$!
replace_content_race_ruby_pid="$(find_ruby_holding_path "$replace_content_race_worker_pid" "$pre_swap_staged_content_target_path" "$INSTALL_IDENTITY_RACE_WAIT_SECONDS")" || {
    /bin/kill -TERM "$replace_content_race_worker_pid" 2>/dev/null || true
    wait "$replace_content_race_worker_pid" 2>/dev/null || true
    replace_content_race_worker_pid=""
    fail "could not observe replacement holding the target before the staged-content race"
}
wait_for_stopped_process "$replace_content_race_ruby_pid" "$INSTALL_IDENTITY_RACE_WAIT_SECONDS" || {
    /bin/kill -TERM "$replace_content_race_worker_pid" 2>/dev/null || true
    /bin/kill -CONT "$replace_content_race_ruby_pid" 2>/dev/null || true
    wait "$replace_content_race_worker_pid" 2>/dev/null || true
    replace_content_race_worker_pid=""
    fail "replacement did not reach the staged-content verification pause"
}
replace_content_race_ruby_stopped=true
target_first_byte="$(/usr/bin/od -An -tx1 -N1 "$pre_swap_staged_content_target_path" | /usr/bin/tr -d '[:space:]')" || fail "could not inspect paused staged-content target"
[[ "$target_first_byte" == "6f" ]] || fail "replacement advanced beyond the first swap before staged content could be changed"
pre_swap_staged_content_stage_path="$(/usr/bin/find "$pre_swap_staged_content_root" -maxdepth 1 -name '.one-key-hidpi-stage-*' -print -quit)" || fail "could not inspect paused staged-content path"
[[ -n "$pre_swap_staged_content_stage_path" ]] || fail "could not observe a staged replacement after its initial hash"
assert_file_hash "$pre_swap_staged_content_stage_path" "$pre_swap_staged_content_candidate_hash"
pre_swap_staged_content_stage_identity="$(file_identity "$pre_swap_staged_content_stage_path")"
printf 'competing staged candidate\n' > "$pre_swap_staged_content_stage_path" || fail "could not mutate staged contents during the pre-swap race"
[[ "$(file_identity "$pre_swap_staged_content_stage_path")" == "$pre_swap_staged_content_stage_identity" ]] || fail "pre-swap staged mutation must retain the staged inode"
/bin/kill -CONT "$replace_content_race_ruby_pid" || fail "could not resume replacement after the staged-content race"
replace_content_race_ruby_stopped=false
if wait "$replace_content_race_worker_pid"; then
    replace_content_race_worker_pid=""
    fail "replacement must reject a staged candidate changed in place before the first swap"
fi
replace_content_race_worker_pid=""
pre_swap_staged_content_output="$(/bin/cat "$pre_swap_staged_content_worker_output")"
assert_contains "$pre_swap_staged_content_output" "replacement did not start and staged recovery artifact was retained"
assert_file_hash "$pre_swap_staged_content_target_path" "$pre_swap_staged_content_target_hash"
assert_file_hash "$pre_swap_staged_content_candidate_path" "$pre_swap_staged_content_candidate_hash"
assert_file_contents "$pre_swap_staged_content_stage_path" "competing staged candidate"
[[ "$(file_identity "$pre_swap_staged_content_stage_path")" == "$pre_swap_staged_content_stage_identity" ]] || fail "in-place staged mutation must retain the staged inode"

swap_directory_root="$scratch_dir/swap-directory"
swap_directory_candidate_path="$swap_directory_root/candidate"
swap_directory_target_path="$swap_directory_root/target"
# The structural assertion above proves this code path cannot perform a second
# swap. A larger candidate keeps post-swap hash verification active long enough
# to exercise the retained-artifact outcome when the displaced staged path changes.
/bin/mkdir -p "$swap_directory_root" || fail "could not create staged swap-race directory"
/bin/dd if=/dev/zero of="$swap_directory_candidate_path" bs=1048576 count=64 >/dev/null 2>&1 || fail "could not create staged swap-race candidate"
printf 'original target\n' > "$swap_directory_target_path"
swap_directory_candidate_hash="$(sha256_file "$swap_directory_candidate_path")"
swap_directory_output=""
if ! swap_directory_output="$(/bin/bash -c '
    source "$1"
    candidate_path="$2"
    target_path="$3"
    target_hash="$(sha256_file "$target_path")"
    candidate_hash="$(sha256_file "$candidate_path")"
    target_identity="$(darwin_file_identity "$target_path")"
    candidate_identity="$(darwin_file_identity "$candidate_path")"
    (
        deadline=$((SECONDS + 10))
        while ((SECONDS < deadline)); do
            for staged_path in "$(/usr/bin/dirname "$target_path")"/.one-key-hidpi-stage-*; do
                [[ -e "$staged_path" ]] || continue
                target_first_byte="$(/usr/bin/od -An -tx1 -N1 "$target_path" | /usr/bin/tr -d "[:space:]")" || exit 2
                # The original target starts with "o". A zero byte proves the
                # initial RENAME_SWAP has already moved the candidate into target.
                [[ "$target_first_byte" == "00" ]] || continue
                /bin/rm -f "$staged_path" || exit 2
                /bin/mkdir "$staged_path" || exit 3
                printf "competing staged directory\n" > "$staged_path/sentinel" || exit 4
                exit 0
            done
        done
        exit 5
    ) &
    attacker_pid=$!
    replace_file_without_following_directory_link "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity" "$target_hash" "$target_identity"
    operation_status=$?
    if ((operation_status == 0)); then
        wait "$attacker_pid"
        exit 1
    fi
    wait "$attacker_pid" || exit 2
    [[ "$operation_status" -eq 2 ]] || exit 3
' bash "$repo_dir/lib/intel_hidpi_storage.sh" "$swap_directory_candidate_path" "$swap_directory_target_path" 2>&1)"; then
    fail "replacement must retain the candidate target when the staged path changes after swap"
fi
assert_contains "$swap_directory_output" "replacement verification failed after swap; retained target and staged path for manual inspection"
assert_file_hash "$swap_directory_target_path" "$swap_directory_candidate_hash"
assert_file_exists "$swap_directory_candidate_path"
assert_file_hash "$swap_directory_candidate_path" "$swap_directory_candidate_hash"
swap_directory_stage_path="$(/usr/bin/find "$(/usr/bin/dirname "$swap_directory_target_path")" -maxdepth 1 -name '.one-key-hidpi-stage-*' -print -quit)" || fail "could not inspect staged race directory"
[[ -n "$swap_directory_stage_path" ]] || fail "replacement must retain the competing staged path"
assert_directory_exists "$swap_directory_stage_path"
assert_file_contents "$swap_directory_stage_path/sentinel" "competing staged directory"

swap_identity_root="$scratch_dir/swap-identity"
swap_identity_candidate_path="$swap_identity_root/candidate"
swap_identity_target_path="$swap_identity_root/target"
swap_identity_original_copy_path="$swap_identity_root/original-copy"
# Replacing the displaced staged file with equal bytes must still fail because
# its inode is not the original target inode. The target remains the first-swap
# candidate and no compensating swap may run.
/bin/mkdir -p "$swap_identity_root" || fail "could not create same-content staged race directory"
/bin/dd if=/dev/zero of="$swap_identity_candidate_path" bs=1048576 count=64 >/dev/null 2>&1 || fail "could not create same-content staged race candidate"
printf 'original target\n' > "$swap_identity_target_path"
/bin/cp "$swap_identity_target_path" "$swap_identity_original_copy_path" || fail "could not preserve same-content staged race original"
swap_identity_candidate_hash="$(sha256_file "$swap_identity_candidate_path")"
swap_identity_original_hash="$(sha256_file "$swap_identity_target_path")"
swap_identity_original_identity="$(file_identity "$swap_identity_target_path")"
swap_identity_output=""
if ! swap_identity_output="$(/bin/bash -c '
    source "$1"
    candidate_path="$2"
    target_path="$3"
    original_copy_path="$4"
    target_hash="$(sha256_file "$target_path")"
    candidate_hash="$(sha256_file "$candidate_path")"
    target_identity="$(darwin_file_identity "$target_path")"
    candidate_identity="$(darwin_file_identity "$candidate_path")"
    (
        deadline=$((SECONDS + 10))
        while ((SECONDS < deadline)); do
            for staged_path in "$(/usr/bin/dirname "$target_path")"/.one-key-hidpi-stage-*; do
                [[ -f "$staged_path" && ! -L "$staged_path" ]] || continue
                target_first_byte="$(/usr/bin/od -An -tx1 -N1 "$target_path" | /usr/bin/tr -d "[:space:]")" || exit 2
                [[ "$target_first_byte" == "00" ]] || continue
                /bin/rm -f "$staged_path" || exit 3
                /bin/cp "$original_copy_path" "$staged_path" || exit 4
                exit 0
            done
        done
        exit 5
    ) &
    attacker_pid=$!
    replace_file_without_following_directory_link "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity" "$target_hash" "$target_identity"
    operation_status=$?
    if ((operation_status == 0)); then
        wait "$attacker_pid"
        exit 1
    fi
    wait "$attacker_pid" || exit 2
    [[ "$operation_status" -eq 2 ]] || exit 3
' bash "$repo_dir/lib/intel_hidpi_storage.sh" "$swap_identity_candidate_path" "$swap_identity_target_path" "$swap_identity_original_copy_path" 2>&1)"; then
    fail "replacement must reject a same-content staged inode replacement after swap"
fi
assert_contains "$swap_identity_output" "replacement verification failed after swap; retained target and staged path for manual inspection"
assert_file_hash "$swap_identity_target_path" "$swap_identity_candidate_hash"
swap_identity_stage_path="$(/usr/bin/find "$(/usr/bin/dirname "$swap_identity_target_path")" -maxdepth 1 -name '.one-key-hidpi-stage-*' -print -quit)" || fail "could not inspect same-content staged race path"
[[ -n "$swap_identity_stage_path" ]] || fail "same-content staged race must retain the competing staged file"
assert_file_hash "$swap_identity_stage_path" "$swap_identity_original_hash"
[[ "$(file_identity "$swap_identity_stage_path")" != "$swap_identity_original_identity" ]] || fail "same-content staged replacement must use a different inode"

manifest_read_overrides_root="${scratch_dir}/manifest-read-overrides"
manifest_read_state_root="${scratch_dir}/manifest-read-state"
manifest_read_target_path="${manifest_read_overrides_root}/DisplayVendorID-20/DisplayProductID-21"
manifest_read_manifest_path="${manifest_read_state_root}/DisplayVendorID-20/DisplayProductID-21/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 20 \
    --product-id 21 \
    --native-resolution 1920x1080 \
    --overrides-root "$manifest_read_overrides_root" \
    --state-root "$manifest_read_state_root" \
    --confirm || fail "apply for manifest read race should succeed"
manifest_read_output=""
if manifest_read_output="$(/bin/bash -c '
    source "$1" >/dev/null
    manifest_path="$2"
    manifest_read_injected=false
    eval "$(declare -f darwin_read_plist_file | /usr/bin/sed '\''s/^darwin_read_plist_file/original_darwin_read_plist_file/'\'')"
    darwin_read_plist_file() {
        if [[ "$1" == "$manifest_path" && "$manifest_read_injected" == false ]]; then
            /usr/bin/plutil -replace native-resolution -string 1600x900 "$1" || return 1
            manifest_read_injected=true
        fi
        original_darwin_read_plist_file "$@"
    }
    revert_override 20 21 "$3" "$4" true
' bash "${repo_dir}/intel-hidpi.sh" "$manifest_read_manifest_path" "$manifest_read_overrides_root" "$manifest_read_state_root" 2>&1)"; then
    fail "revert must reject a manifest changed while it is being read"
fi
assert_contains "$manifest_read_output" "manifest changed while it was being read; refusing to revert"
assert_file_exists "$manifest_read_target_path"
assert_file_exists "$manifest_read_manifest_path"
[[ "$(/usr/bin/plutil -extract native-resolution raw -o - "$manifest_read_manifest_path")" == "1600x900" ]] || fail "manifest read race must retain the competing manifest"

revert_link_overrides_root="${scratch_dir}/revert-link-overrides"
revert_link_state_root="${scratch_dir}/revert-link-state"
revert_link_target_path="${revert_link_overrides_root}/DisplayVendorID-19/DisplayProductID-1a"
revert_link_manifest_path="${revert_link_state_root}/DisplayVendorID-19/DisplayProductID-1a/manifest.plist"
revert_link_outside_path="${scratch_dir}/revert-link-outside.plist"
printf 'post-lock revert target\n' > "$revert_link_outside_path"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 19 \
    --product-id 1a \
    --native-resolution 1920x1080 \
    --overrides-root "$revert_link_overrides_root" \
    --state-root "$revert_link_state_root" \
    --confirm || fail "apply for post-lock revert link test should succeed"
revert_link_output=""
if revert_link_output="$(/bin/bash -c '
    source "$1"
    race_outside="$2"
    acquire_display_lock() {
        /bin/rm -f "$1/DisplayVendorID-$2/DisplayProductID-$3" || return 1
        /bin/ln -s "$race_outside" "$1/DisplayVendorID-$2/DisplayProductID-$3"
    }
    revert_override 19 1a "$3" "$4" true
' bash "${repo_dir}/intel-hidpi.sh" "$revert_link_outside_path" "$revert_link_overrides_root" "$revert_link_state_root" 2>&1)"; then
    fail "revert must recheck a target symbolic link created after lock acquisition"
fi
assert_contains "$revert_link_output" "target path traverses a symbolic link"
assert_file_contents "$revert_link_outside_path" "post-lock revert target"
[[ -L "$revert_link_target_path" ]] || fail "post-lock revert target link must remain in place"
assert_file_exists "$revert_link_manifest_path"

revert_replace_overrides_root="${scratch_dir}/revert-replace-overrides"
revert_replace_state_root="${scratch_dir}/revert-replace-state"
revert_replace_target_path="${revert_replace_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
revert_replace_original_path="${scratch_dir}/revert-replace-original.plist"
revert_replace_outside_dir="${scratch_dir}/revert-replace-outside"
/bin/mkdir -p "$(/usr/bin/dirname "$revert_replace_target_path")" "$revert_replace_outside_dir" || fail "could not prepare revert replacement-link fixture"
/bin/cp "${repo_dir}/tests/fixtures/overrides/DisplayVendorID-30ae/DisplayProductID-62a5-rich" "$revert_replace_target_path" || fail "could not create revert replacement target"
/bin/cp "$revert_replace_target_path" "$revert_replace_original_path" || fail "could not preserve revert replacement original"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --overrides-root "$revert_replace_overrides_root" \
    --state-root "$revert_replace_state_root" \
    --confirm || fail "apply for revert replacement-link test should succeed"
revert_replace_output=""
if revert_replace_output="$(/bin/bash -c '
    source "$1" >/dev/null
    target_path="$2"
    outside_dir="$3"
    target_replaced=false
    eval "$(declare -f replace_file_without_following_directory_link_persistent | /usr/bin/sed '\''s/^replace_file_without_following_directory_link_persistent/original_replace_file_without_following_directory_link_persistent/'\'')"
    replace_file_without_following_directory_link_persistent() {
        if [[ "$2" == "$target_path" && "$target_replaced" == false ]]; then
            /bin/rm -f "$target_path" || return 1
            /bin/ln -s "$outside_dir" "$target_path" || return 1
            target_replaced=true
        fi
        original_replace_file_without_following_directory_link_persistent "$@"
    }
    revert_override 30ae 62a5 "$4" "$5" true
' bash "${repo_dir}/intel-hidpi.sh" "$revert_replace_target_path" "$revert_replace_outside_dir" "$revert_replace_overrides_root" "$revert_replace_state_root" 2>&1)"; then
    fail "revert must reject a post-validation directory symbolic link"
fi
assert_contains "$revert_replace_output" "could not atomically restore original override"
assert_directory_empty "$revert_replace_outside_dir"
[[ -L "$revert_replace_target_path" ]] || fail "revert must preserve the raced target link"
assert_file_exists "${revert_replace_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/original.plist"
assert_file_exists "${revert_replace_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/manifest.plist"
/usr/bin/cmp -s "$revert_replace_original_path" "${revert_replace_state_root}/DisplayVendorID-30ae/DisplayProductID-62a5/original.plist" || fail "revert must retain the exact original backup after a raced target link"

created_race_overrides_root="${scratch_dir}/created-race-overrides"
created_race_state_root="${scratch_dir}/created-race-state"
created_race_target_path="${created_race_overrides_root}/DisplayVendorID-1b/DisplayProductID-1c"
created_race_state_dir="${created_race_state_root}/DisplayVendorID-1b/DisplayProductID-1c"
created_race_original_path="${created_race_state_dir}/original.plist"
created_race_manifest_path="${created_race_state_dir}/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1b \
    --product-id 1c \
    --native-resolution 1920x1080 \
    --overrides-root "$created_race_overrides_root" \
    --state-root "$created_race_state_root" \
    --confirm || fail "apply for created-target state race should succeed"
created_race_output=""
if created_race_output="$(/bin/bash -c '
    source "$1"
    target_path="$2"
    original_path="$3"
    injected_original=false
    eval "$(declare -f remove_file_if_unchanged_persistent | /usr/bin/sed '"'"'s/^remove_file_if_unchanged_persistent/original_remove_file_if_unchanged_persistent/'"'"')"
    remove_file_if_unchanged_persistent() {
        original_remove_file_if_unchanged_persistent "$@" || return 1
        if [[ "$1" == "$target_path" && "$injected_original" == false ]]; then
            printf "competing original\\n" > "$original_path"
            injected_original=true
        fi
    }
    revert_override 1b 1c "$4" "$5" true
' bash "${repo_dir}/intel-hidpi.sh" "$created_race_target_path" "$created_race_original_path" "$created_race_overrides_root" "$created_race_state_root" 2>&1)"; then
    fail "revert must retain state when an unexpected original backup appears"
fi
assert_contains "$created_race_output" "unexpected original backup appeared during revert"
assert_file_absent "$created_race_target_path"
assert_file_contents "$created_race_original_path" "competing original"
assert_file_exists "$created_race_manifest_path"

created_reappeared_overrides_root="${scratch_dir}/created-reappeared-overrides"
created_reappeared_state_root="${scratch_dir}/created-reappeared-state"
created_reappeared_target_path="${created_reappeared_overrides_root}/DisplayVendorID-22/DisplayProductID-23"
created_reappeared_manifest_path="${created_reappeared_state_root}/DisplayVendorID-22/DisplayProductID-23/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 22 \
    --product-id 23 \
    --native-resolution 1920x1080 \
    --overrides-root "$created_reappeared_overrides_root" \
    --state-root "$created_reappeared_state_root" \
    --confirm || fail "apply for created-target reappear race should succeed"
created_reappeared_output=""
if created_reappeared_output="$(/bin/bash -c '
    source "$1"
    target_path="$2"
    eval "$(declare -f remove_file_if_unchanged_persistent | /usr/bin/sed '"'"'s/^remove_file_if_unchanged_persistent/original_remove_file_if_unchanged_persistent/'"'"')"
    remove_file_if_unchanged_persistent() {
        original_remove_file_if_unchanged_persistent "$@" || return 1
        if [[ "$1" == "$target_path" ]]; then
            printf "competing target\\n" > "$target_path"
        fi
    }
    revert_override 22 23 "$3" "$4" true
' bash "${repo_dir}/intel-hidpi.sh" "$created_reappeared_target_path" "$created_reappeared_overrides_root" "$created_reappeared_state_root" 2>&1)"; then
    fail "revert must retain state when a created target reappears"
fi
assert_contains "$created_reappeared_output" "created target appeared during revert; retaining state"
assert_file_contents "$created_reappeared_target_path" "competing target"
assert_file_exists "$created_reappeared_manifest_path"

original_cleanup_overrides_root="${scratch_dir}/original-cleanup-overrides"
original_cleanup_state_root="${scratch_dir}/original-cleanup-state"
original_cleanup_target_path="${original_cleanup_overrides_root}/DisplayVendorID-24/DisplayProductID-25"
original_cleanup_original_fixture="${scratch_dir}/original-cleanup-original.plist"
original_cleanup_state_dir="${original_cleanup_state_root}/DisplayVendorID-24/DisplayProductID-25"
original_cleanup_original_path="${original_cleanup_state_dir}/original.plist"
original_cleanup_manifest_path="${original_cleanup_state_dir}/manifest.plist"
/bin/mkdir -p "$(/usr/bin/dirname "$original_cleanup_target_path")" || fail "could not prepare original cleanup fixture"
/bin/cp "${repo_dir}/tests/fixtures/overrides/DisplayVendorID-30ae/DisplayProductID-62a5-rich" "$original_cleanup_target_path" || fail "could not create original cleanup target"
/usr/bin/plutil -replace DisplayVendorID -integer 36 "$original_cleanup_target_path" || fail "could not set original cleanup vendor id"
/usr/bin/plutil -replace DisplayProductID -integer 37 "$original_cleanup_target_path" || fail "could not set original cleanup product id"
/bin/cp "$original_cleanup_target_path" "$original_cleanup_original_fixture" || fail "could not preserve original cleanup fixture"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 24 \
    --product-id 25 \
    --native-resolution 1920x1080 \
    --overrides-root "$original_cleanup_overrides_root" \
    --state-root "$original_cleanup_state_root" \
    --confirm || fail "apply for original cleanup race should succeed"
original_cleanup_output=""
if original_cleanup_output="$(/bin/bash -c '
    source "$1" >/dev/null
    original_path="$2"
    eval "$(declare -f remove_file_if_unchanged_persistent | /usr/bin/sed '"'"'s/^remove_file_if_unchanged_persistent/original_remove_file_if_unchanged_persistent/'"'"')"
    remove_file_if_unchanged_persistent() {
        if [[ "$1" == "$original_path" ]]; then
            printf "changed original\\n" > "$original_path"
        fi
        original_remove_file_if_unchanged_persistent "$@"
    }
    revert_override 24 25 "$3" "$4" true
' bash "${repo_dir}/intel-hidpi.sh" "$original_cleanup_original_path" "$original_cleanup_overrides_root" "$original_cleanup_state_root" 2>&1)"; then
    fail "revert must retain state when original backup changes before cleanup"
fi
assert_contains "$original_cleanup_output" "override was restored but original backup could not be removed"
/usr/bin/cmp -s "$original_cleanup_original_fixture" "$original_cleanup_target_path" || fail "target must be restored before original cleanup failure"
assert_file_contents "$original_cleanup_original_path" "changed original"
assert_file_exists "$original_cleanup_manifest_path"

manifest_cleanup_overrides_root="${scratch_dir}/manifest-cleanup-overrides"
manifest_cleanup_state_root="${scratch_dir}/manifest-cleanup-state"
manifest_cleanup_target_path="${manifest_cleanup_overrides_root}/DisplayVendorID-26/DisplayProductID-27"
manifest_cleanup_manifest_path="${manifest_cleanup_state_root}/DisplayVendorID-26/DisplayProductID-27/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 26 \
    --product-id 27 \
    --native-resolution 1920x1080 \
    --overrides-root "$manifest_cleanup_overrides_root" \
    --state-root "$manifest_cleanup_state_root" \
    --confirm || fail "apply for manifest cleanup race should succeed"
manifest_cleanup_output=""
if manifest_cleanup_output="$(/bin/bash -c '
    source "$1" >/dev/null
    target_path="$2"
    manifest_path="$3"
    eval "$(declare -f remove_file_if_unchanged_persistent | /usr/bin/sed '"'"'s/^remove_file_if_unchanged_persistent/original_remove_file_if_unchanged_persistent/'"'"')"
    remove_file_if_unchanged_persistent() {
        original_remove_file_if_unchanged_persistent "$@" || return 1
        if [[ "$1" == "$target_path" ]]; then
            /usr/bin/plutil -replace native-resolution -string 1600x900 "$manifest_path" || return 1
        fi
    }
    revert_override 26 27 "$4" "$5" true
' bash "${repo_dir}/intel-hidpi.sh" "$manifest_cleanup_target_path" "$manifest_cleanup_manifest_path" "$manifest_cleanup_overrides_root" "$manifest_cleanup_state_root" 2>&1)"; then
    fail "revert must retain state when manifest changes before cleanup"
fi
assert_contains "$manifest_cleanup_output" "manifest changed before state cleanup; retaining state"
assert_file_absent "$manifest_cleanup_target_path"
assert_file_exists "$manifest_cleanup_manifest_path"
[[ "$(/usr/bin/plutil -extract native-resolution raw -o - "$manifest_cleanup_manifest_path")" == "1600x900" ]] || fail "manifest cleanup race must retain the competing manifest"

manifest_persistent_cleanup_overrides_root="${scratch_dir}/manifest-persistent-cleanup-overrides"
manifest_persistent_cleanup_state_root="${scratch_dir}/manifest-persistent-cleanup-state"
manifest_persistent_cleanup_target_path="${manifest_persistent_cleanup_overrides_root}/DisplayVendorID-28/DisplayProductID-29"
manifest_persistent_cleanup_manifest_path="${manifest_persistent_cleanup_state_root}/DisplayVendorID-28/DisplayProductID-29/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 28 \
    --product-id 29 \
    --native-resolution 1920x1080 \
    --overrides-root "$manifest_persistent_cleanup_overrides_root" \
    --state-root "$manifest_persistent_cleanup_state_root" \
    --confirm || fail "apply for manifest persistent cleanup test should succeed"
manifest_persistent_cleanup_output=""
if ! manifest_persistent_cleanup_output="$(/bin/bash -c '
    source "$1" >/dev/null
    manifest_path="$2"
    manifest_cleanup_used=false
    eval "$(declare -f remove_file_if_unchanged_persistent | /usr/bin/sed '\''s/^remove_file_if_unchanged_persistent/original_remove_file_if_unchanged_persistent/'\'')"
    remove_file_if_unchanged_persistent() {
        if [[ "$1" == "$manifest_path" ]]; then
            [[ "$4" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
            manifest_cleanup_used=true
        fi
        original_remove_file_if_unchanged_persistent "$@"
    }
    revert_override 28 29 "$3" "$4" true
    [[ "$manifest_cleanup_used" == true ]] || exit 1
    printf "manifest persistent cleanup verified\\n"
' bash "${repo_dir}/intel-hidpi.sh" "$manifest_persistent_cleanup_manifest_path" "$manifest_persistent_cleanup_overrides_root" "$manifest_persistent_cleanup_state_root" 2>&1)"; then
    fail "revert must use persistent identity when removing the manifest"
fi
assert_contains "$manifest_persistent_cleanup_output" "manifest persistent cleanup verified"
assert_file_absent "$manifest_persistent_cleanup_target_path"
assert_file_absent "$manifest_persistent_cleanup_manifest_path"

manifest_replacement_overrides_root="${scratch_dir}/manifest-replacement-overrides"
manifest_replacement_state_root="${scratch_dir}/manifest-replacement-state"
manifest_replacement_target_path="${manifest_replacement_overrides_root}/DisplayVendorID-2a/DisplayProductID-2b"
manifest_replacement_manifest_path="${manifest_replacement_state_root}/DisplayVendorID-2a/DisplayProductID-2b/manifest.plist"
"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 2a \
    --product-id 2b \
    --native-resolution 1920x1080 \
    --overrides-root "$manifest_replacement_overrides_root" \
    --state-root "$manifest_replacement_state_root" \
    --confirm || fail "apply for manifest replacement protection should succeed"
manifest_replacement_output=""
if manifest_replacement_output="$(/bin/bash -c '
    source "$1" >/dev/null
    target_path="$2"
    manifest_path="$3"
    manifest_replaced=false
    eval "$(declare -f remove_file_if_unchanged_persistent | /usr/bin/sed '\''s/^remove_file_if_unchanged_persistent/original_remove_file_if_unchanged_persistent/'\'')"
    remove_file_if_unchanged_persistent() {
        original_remove_file_if_unchanged_persistent "$@" || return 1
        if [[ "$1" == "$target_path" && "$manifest_replaced" == false ]]; then
            /bin/cp "$manifest_path" "${manifest_path}.replacement" || return 1
            /bin/mv "${manifest_path}.replacement" "$manifest_path" || return 1
            manifest_replaced=true
        fi
    }
    revert_override 2a 2b "$4" "$5" true
' bash "${repo_dir}/intel-hidpi.sh" "$manifest_replacement_target_path" "$manifest_replacement_manifest_path" "$manifest_replacement_overrides_root" "$manifest_replacement_state_root" 2>&1)"; then
    fail "revert must reject a same-content manifest replacement before cleanup"
fi
assert_contains "$manifest_replacement_output" "manifest changed before state cleanup; retaining state"
assert_file_absent "$manifest_replacement_target_path"
assert_file_exists "$manifest_replacement_manifest_path"

printf 'PASS: Intel HiDPI storage races\n'
