INTEL_HIDPI_STORAGE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
# shellcheck source=lib/intel_hidpi_storage_support.sh
source "${INTEL_HIDPI_STORAGE_CORE_DIR}/intel_hidpi_storage_support.sh" || return 1
unset INTEL_HIDPI_STORAGE_CORE_DIR

commit_apply_state() {
    local target_path="$1"
    local candidate_path="$2"
    local target_existed="$3"
    local original_hash="$4"
    local backup_candidate_path="$5"
    local original_path="$6"
    local manifest_candidate_path="$7"
    local manifest_path="$8"
    local candidate_hash="${9:-}"
    local manifest_candidate_hash="${10:-}"
    local original_identity="${11:-}"
    local candidate_identity="${12:-}"
    local manifest_candidate_identity="${13:-}"
    local backup_expected_hash=""
    local backup_candidate_identity=""
    local backup_candidate_snapshot
    local backup_candidate_hash
    local installed_backup_snapshot
    local installed_backup_hash
    local installed_backup_identity
    local installed_manifest_snapshot
    local installed_manifest_hash
    local installed_manifest_identity
    local installed_target_snapshot
    local installed_target_hash
    local installed_target_identity
    local target_install_status=0

    [[ "$target_existed" == true || "$target_existed" == false ]] || return 1
    valid_sha256 "$candidate_hash" || return 1
    valid_sha256 "$manifest_candidate_hash" || return 1
    valid_file_identity "$candidate_identity" || return 1
    valid_file_identity "$manifest_candidate_identity" || return 1
    file_matches_snapshot "$candidate_path" "$candidate_hash" "$candidate_identity" || {
        printf 'error: target candidate changed before state commit; no override was written\n' >&2
        return 1
    }
    file_matches_snapshot "$manifest_candidate_path" "$manifest_candidate_hash" "$manifest_candidate_identity" || {
        printf 'error: could not install verified manifest without replacement; state was retained for manual inspection\n' >&2
        return 1
    }
    if [[ "$target_existed" == true ]]; then
        valid_sha256 "$original_hash" || return 1
        valid_file_identity "$original_identity" || return 1
        backup_expected_hash="$original_hash"
        backup_candidate_snapshot="$(darwin_file_snapshot "$backup_candidate_path")" || return 1
        IFS='|' read -r backup_candidate_hash backup_candidate_identity <<< "$backup_candidate_snapshot"
        [[ "$backup_candidate_hash" == "$backup_expected_hash" ]] || return 1
        valid_file_identity "$backup_candidate_identity" || return 1
        file_matches_snapshot "$backup_candidate_path" "$backup_expected_hash" "$backup_candidate_identity" || {
            printf 'error: original backup candidate changed before state commit; no override was written\n' >&2
            return 1
        }
        target_matches_pre_apply_state "$target_path" "$target_existed" "$original_hash" "$original_identity" || {
            printf 'error: target changed after validation; no override was written and state was retained for manual inspection\n' >&2
            return 1
        }
    else
        target_matches_pre_apply_state "$target_path" "$target_existed" "$original_hash" "$original_identity" || {
            printf 'error: target changed after validation; no override was written and state was retained for manual inspection\n' >&2
            return 1
        }
    fi
    if [[ "$target_existed" == true ]]; then
        if ! installed_backup_snapshot="$(install_file_without_replacement "$backup_candidate_path" "$original_path" "$backup_expected_hash" "$backup_candidate_identity")"; then
            printf 'error: could not store exact original backup without replacement\n' >&2
            return 1
        fi
        IFS='|' read -r installed_backup_hash installed_backup_identity <<< "$installed_backup_snapshot"
        [[ "$installed_backup_hash" == "$backup_expected_hash" ]] || return 1
        valid_file_identity "$installed_backup_identity" || return 1
        file_matches_snapshot "$original_path" "$backup_expected_hash" "$installed_backup_identity" || return 1
    fi
    if ! installed_manifest_snapshot="$(install_file_without_replacement "$manifest_candidate_path" "$manifest_path" "$manifest_candidate_hash" "$manifest_candidate_identity")"; then
        printf 'error: could not install verified manifest without replacement; state was retained for manual inspection\n' >&2
        return 1
    fi
    IFS='|' read -r installed_manifest_hash installed_manifest_identity <<< "$installed_manifest_snapshot"
    [[ "$installed_manifest_hash" == "$manifest_candidate_hash" ]] || return 1
    valid_file_identity "$installed_manifest_identity" || return 1
    if [[ "$target_existed" == true ]]; then
        record_pending_manifest_original_identity "$manifest_path" "$installed_manifest_hash" "$installed_manifest_identity" "$installed_backup_identity" || {
            printf 'error: original backup was stored but manifest identity could not be committed; state was retained for manual inspection\n' >&2
            return 1
        }
        installed_manifest_hash="$PLIST_OPERATION_HASH"
        installed_manifest_identity="$PLIST_OPERATION_IDENTITY"
        file_matches_snapshot "$original_path" "$backup_expected_hash" "$installed_backup_identity" || {
            printf 'error: original backup changed before target commit; state was retained for manual inspection\n' >&2
            return 1
        }
    fi
    if ! target_matches_pre_apply_state "$target_path" "$target_existed" "$original_hash" "$original_identity"; then
        printf 'error: target changed after validation; no override was written and state was retained for manual inspection\n' >&2
        return 1
    fi
    if [[ "$target_existed" == false ]]; then
        installed_target_snapshot="$(install_file_without_replacement "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity")"
        target_install_status=$?
        if ((target_install_status != 0)); then
            if ((target_install_status == 2)); then
                printf 'error: target installation may have completed before verification failed; state was retained for manual inspection\n' >&2
            else
                printf 'error: could not atomically install a new target override without replacement; state was retained for manual inspection\n' >&2
            fi
            return 1
        fi
    else
        installed_target_snapshot="$(replace_file_without_following_directory_link "$candidate_path" "$target_path" "$candidate_hash" "$candidate_identity" "$original_hash" "$original_identity")"
        target_install_status=$?
        if ((target_install_status != 0)); then
            if ((target_install_status == 2)); then
                printf 'error: target replacement may have completed before verification or cleanup failed; state was retained for manual inspection\n' >&2
            else
                printf 'error: could not atomically replace target override; state was retained for manual inspection\n' >&2
            fi
            return 1
        fi
    fi
    IFS='|' read -r installed_target_hash installed_target_identity <<< "$installed_target_snapshot"
    [[ "$installed_target_hash" == "$candidate_hash" ]] || return 1
    valid_file_identity "$installed_target_identity" || return 1
    file_matches_snapshot "$target_path" "$candidate_hash" "$installed_target_identity" || {
        printf 'error: target changed immediately after installation; state was retained for manual inspection\n' >&2
        return 1
    }
    finalize_pending_manifest "$manifest_path" "$installed_manifest_hash" "$installed_manifest_identity" "$installed_target_identity" || {
        printf 'error: target was installed but manifest identity could not be committed; state was retained for manual inspection\n' >&2
        return 1
    }
    file_matches_snapshot "$target_path" "$candidate_hash" "$installed_target_identity" || {
        printf 'error: target changed while finalizing manifest; state was retained for manual inspection\n' >&2
        return 1
    }
}

apply_override() {
    local vendor_id="$1"
    local product_id="$2"
    local native_resolution="$3"
    local overrides_root="$4"
    local state_root="$5"
    local confirmed="$6"
    local apply_request
    local vendor_decimal
    local product_decimal
    local target_path
    local target_relative
    local target_dir
    local state_dir
    local candidate_path
    local backup_candidate_path=""
    local manifest_candidate_path
    local original_path
    local manifest_path
    local target_existed=false
    local original_hash=""
    local original_identity=""
    local original_snapshot
    local candidate_hash
    local candidate_identity
    local manifest_candidate_hash
    local manifest_candidate_identity
    local overrides_are_system_paths=false
    local state_is_system_path=false

    [[ "$confirmed" == true ]] || fail "apply requires --confirm"
    apply_request="$(parse_apply_request "$vendor_id" "$product_id" "$native_resolution")" || fail "vendor id, product id, or native resolution is invalid"
    IFS='|' read -r vendor_id product_id vendor_decimal product_decimal <<< "$apply_request"
    overrides_root="$(normalize_storage_root "$overrides_root")" || fail "overrides root is invalid or traverses a symbolic link"
    state_root="$(normalize_storage_root "$state_root")" || fail "state root is invalid or traverses a symbolic link"
    storage_roots_have_matching_trust "$overrides_root" "$state_root" || fail "system overrides root and state root must be used together"
    require_root_for_system_paths "$overrides_root" "$state_root"
    is_system_overrides_root "$overrides_root" && overrides_are_system_paths=true
    is_system_state_root "$state_root" && state_is_system_path=true

    target_path="$(path_for_display "$overrides_root" "$vendor_id" "$product_id")"
    target_relative="DisplayVendorID-${vendor_id}/DisplayProductID-${product_id}"
    target_dir="$(/usr/bin/dirname "$target_path")"
    state_dir="$(state_dir_for_display "$state_root" "$vendor_id" "$product_id")"
    original_path="${state_dir}/original.plist"
    manifest_path="${state_dir}/manifest.plist"

    path_has_disallowed_symbolic_link "$target_path" && fail "target path traverses a symbolic link"
    if path_has_disallowed_symbolic_link "$state_dir" ||
        path_has_disallowed_symbolic_link "$manifest_path" ||
        path_has_disallowed_symbolic_link "$original_path"; then
        fail "state files traverse a symbolic link"
    fi
    reset_operation_cleanup_state
    acquire_display_lock "$overrides_root" "$vendor_id" "$product_id" || fail "could not acquire display operation lock"
    path_has_disallowed_symbolic_link "$target_path" && fail "target path traverses a symbolic link"
    if path_has_disallowed_symbolic_link "$state_dir" ||
        path_has_disallowed_symbolic_link "$manifest_path" ||
        path_has_disallowed_symbolic_link "$original_path"; then
        fail "target or state files traverse a symbolic link"
    fi
    ensure_directory_path_without_symlinks "$target_dir" || fail "could not create target directory safely"
    ensure_directory_path_without_symlinks "$state_dir" || fail "could not create state directory safely"
    [[ ! -e "$manifest_path" && ! -L "$manifest_path" && ! -e "$original_path" && ! -L "$original_path" ]] || fail "existing state requires manual inspection before another apply"
    directory_is_empty "$state_dir" || fail "state directory must be empty before apply"
    create_operation_temporary_directory || fail "could not create private operation directory"
    create_temporary_file "DisplayProductID-${product_id}.candidate" || fail "could not create target candidate"
    candidate_path="$TEMPORARY_FILE"

    if [[ -f "$target_path" && ! -L "$target_path" ]]; then
        target_existed=true
        create_temporary_file "original.plist" || fail "could not create original backup candidate"
        backup_candidate_path="$TEMPORARY_FILE"
        original_snapshot="$(darwin_file_snapshot "$target_path")" || fail "could not snapshot original override"
        IFS='|' read -r original_hash original_identity <<< "$original_snapshot"
        valid_sha256 "$original_hash" || fail "could not snapshot original override"
        valid_file_identity "$original_identity" || fail "could not identify original override"
        copy_file_and_verify_hash "$target_path" "$backup_candidate_path" "$original_hash" "$original_identity" || fail "could not create exact original backup"
        copy_file_and_verify_hash "$target_path" "$candidate_path" "$original_hash" "$original_identity" || fail "could not create candidate override"
    elif [[ -e "$target_path" || -L "$target_path" ]]; then
        fail "target override exists but is not a regular file"
    else
        candidate_hash="$(temporary_file_expected_hash "$candidate_path")" || fail "could not verify base override candidate"
        candidate_identity="$(temporary_file_expected_identity "$candidate_path")" || fail "could not verify base override candidate"
        create_base_override "$candidate_path" "$vendor_decimal" "$product_decimal" "$candidate_hash" "$candidate_identity" || fail "could not create base override"
        candidate_hash="$PLIST_OPERATION_HASH"
        candidate_identity="$PLIST_OPERATION_IDENTITY"
        record_temporary_file_snapshot "$candidate_path" "$candidate_hash" "$candidate_identity" || fail "could not verify base override candidate"
    fi

    candidate_hash="$(temporary_file_expected_hash "$candidate_path")" || fail "could not verify target candidate before mode merge"
    candidate_identity="$(temporary_file_expected_identity "$candidate_path")" || fail "could not verify target candidate before mode merge"
    append_missing_payloads "$candidate_path" "$native_resolution" "$DEFAULT_FRAMEBUFFER_LIMIT" "$candidate_hash" "$candidate_identity" || fail "could not merge generated modes"
    candidate_hash="$PLIST_OPERATION_HASH"
    candidate_identity="$PLIST_OPERATION_IDENTITY"
    validate_candidate_override "$candidate_path" "$candidate_hash" "$candidate_identity" "$vendor_decimal" "$product_decimal" || fail "candidate override did not validate"
    set_written_file_permissions "$candidate_path" "$overrides_are_system_paths" "$candidate_hash" "$candidate_identity" || fail "could not set candidate permissions"
    candidate_hash="$PLIST_OPERATION_HASH"
    candidate_identity="$PLIST_OPERATION_IDENTITY"
    record_temporary_file_snapshot "$candidate_path" "$candidate_hash" "$candidate_identity" || fail "could not verify target candidate"
    create_temporary_file "manifest.plist" || fail "could not create manifest candidate"
    manifest_candidate_path="$TEMPORARY_FILE"
    manifest_candidate_hash="$(temporary_file_expected_hash "$manifest_candidate_path")" || fail "could not verify manifest candidate"
    manifest_candidate_identity="$(temporary_file_expected_identity "$manifest_candidate_path")" || fail "could not verify manifest candidate"
    write_manifest "$manifest_candidate_path" "$candidate_path" "$overrides_root" "$target_relative" "$target_existed" "$vendor_id" "$product_id" "$native_resolution" "$original_hash" "$candidate_hash" "$candidate_identity" "$manifest_candidate_hash" "$manifest_candidate_identity" || fail "could not write manifest"
    manifest_candidate_hash="$PLIST_OPERATION_HASH"
    manifest_candidate_identity="$PLIST_OPERATION_IDENTITY"
    set_written_file_permissions "$manifest_candidate_path" "$state_is_system_path" "$manifest_candidate_hash" "$manifest_candidate_identity" || fail "could not set manifest permissions"
    manifest_candidate_hash="$PLIST_OPERATION_HASH"
    manifest_candidate_identity="$PLIST_OPERATION_IDENTITY"
    record_temporary_file_snapshot "$manifest_candidate_path" "$manifest_candidate_hash" "$manifest_candidate_identity" || fail "could not verify manifest candidate"
    commit_apply_state "$target_path" "$candidate_path" "$target_existed" "$original_hash" "$backup_candidate_path" "$original_path" "$manifest_candidate_path" "$manifest_path" "$candidate_hash" "$manifest_candidate_hash" "$original_identity" "$candidate_identity" "$manifest_candidate_identity" || fail "apply did not complete; recovery state was retained for manual inspection"
    complete_operation_cleanup || fail "apply committed but temporary artifact or operation lock cleanup failed"

    printf 'applied=%s\n' "$target_relative"
    printf 'manifest=%s\n' "$manifest_path"
}

revert_override() {
    local vendor_id="$1"
    local product_id="$2"
    local overrides_root="$3"
    local state_root="$4"
    local confirmed="$5"
    local target_path
    local state_dir
    local manifest_path
    local original_path
    local target_dir
    local target_relative
    local target_existed
    local manifest_metadata
    local manifest_hash
    local manifest_identity
    local candidate_hash
    local candidate_identity
    local original_hash
    local original_identity
    local backup_snapshot
    local target_identity
    local target_snapshot
    local target_hash
    local backup_hash
    local backup_identity
    local restore_candidate_path
    local restore_candidate_identity
    local restored_target_snapshot
    local restored_target_hash
    local restored_target_identity
    local restore_status=0
    local target_present=false

    [[ "$confirmed" == true ]] || fail "revert requires --confirm"
    vendor_id="$(normalize_hex_id "$vendor_id")" || fail "vendor id must be hexadecimal"
    product_id="$(normalize_hex_id "$product_id")" || fail "product id must be hexadecimal"
    overrides_root="$(normalize_storage_root "$overrides_root")" || fail "overrides root is invalid or traverses a symbolic link"
    state_root="$(normalize_storage_root "$state_root")" || fail "state root is invalid or traverses a symbolic link"
    storage_roots_have_matching_trust "$overrides_root" "$state_root" || fail "system overrides root and state root must be used together"
    require_root_for_system_paths "$overrides_root" "$state_root"
    target_path="$(path_for_display "$overrides_root" "$vendor_id" "$product_id")"
    target_dir="$(/usr/bin/dirname "$target_path")"
    target_relative="DisplayVendorID-${vendor_id}/DisplayProductID-${product_id}"
    state_dir="$(state_dir_for_display "$state_root" "$vendor_id" "$product_id")"
    manifest_path="${state_dir}/manifest.plist"
    original_path="${state_dir}/original.plist"

    path_has_disallowed_symbolic_link "$target_path" && fail "target path traverses a symbolic link"
    if path_has_disallowed_symbolic_link "$state_dir" ||
        path_has_disallowed_symbolic_link "$manifest_path" ||
        path_has_disallowed_symbolic_link "$original_path"; then
        fail "state files traverse a symbolic link"
    fi
    reset_operation_cleanup_state
    acquire_display_lock "$overrides_root" "$vendor_id" "$product_id" || fail "could not acquire display operation lock"
    path_has_disallowed_symbolic_link "$target_path" && fail "target path traverses a symbolic link"
    if path_has_disallowed_symbolic_link "$state_dir" ||
        path_has_disallowed_symbolic_link "$manifest_path" ||
        path_has_disallowed_symbolic_link "$original_path"; then
        fail "target or state files traverse a symbolic link"
    fi
    darwin_directory_identity "$state_dir" >/dev/null || fail "could not open state directory safely"
    [[ -f "$manifest_path" ]] || fail "no manifest exists for this target"
    if manifest_metadata="$(read_revert_manifest "$manifest_path" "$vendor_id" "$product_id" "$target_relative" "$overrides_root")"; then
        :
    else
        case "$?" in
        2)
            fail "manifest version is unsupported"
            ;;
        3)
            fail "manifest override root does not match this target"
            ;;
        4)
            fail "manifest changed while it was being read; refusing to revert"
            ;;
        5)
            fail "manifest apply state is incomplete; refusing to revert automatically"
            ;;
        *)
            fail "manifest is invalid or does not match this display"
            ;;
        esac
    fi
    IFS='|' read -r target_existed candidate_hash candidate_identity original_hash original_identity manifest_hash manifest_identity <<< "$manifest_metadata"

    case "$target_existed" in
    true)
        [[ -f "$original_path" && ! -L "$original_path" ]] || fail "original backup is missing"
        backup_snapshot="$(darwin_file_snapshot "$original_path")" || fail "could not snapshot original backup"
        IFS='|' read -r backup_hash backup_identity <<< "$backup_snapshot"
        valid_sha256 "$backup_hash" || fail "could not snapshot original backup"
        valid_file_identity "$backup_identity" || fail "could not snapshot original backup"
        [[ "$backup_hash" == "$original_hash" ]] || fail "original backup changed after apply; refusing to restore it"
        [[ "$backup_identity" == "$original_identity" ]] || fail "original backup identity changed after apply; refusing to restore it"
        plist_file_is_valid "$original_path" "$backup_hash" "$backup_identity" || fail "original backup is invalid or changed after apply; refusing to restore it"
        file_matches_snapshot "$original_path" "$original_hash" "$original_identity" || fail "original backup changed after apply; refusing to restore it"
        ;;
    false)
        [[ ! -e "$original_path" && ! -L "$original_path" ]] || fail "unexpected original backup exists for a created target"
        ;;
    *)
        fail "manifest target state is invalid"
        ;;
    esac

    if [[ -e "$target_path" || -L "$target_path" ]]; then
        [[ -f "$target_path" && ! -L "$target_path" ]] || fail "target override is not a regular file"
        target_present=true
        target_snapshot="$(darwin_file_snapshot "$target_path")" || fail "could not snapshot current target override"
        IFS='|' read -r target_hash target_identity <<< "$target_snapshot"
        valid_sha256 "$target_hash" || fail "could not snapshot current target override"
        valid_file_identity "$target_identity" || fail "could not snapshot current target override"
        [[ "$target_hash" == "$candidate_hash" ]] || fail "target override changed after apply; refusing to overwrite it"
        [[ "$target_identity" == "$candidate_identity" ]] || fail "target override identity changed after apply; refusing to overwrite it"
        file_matches_snapshot "$target_path" "$candidate_hash" "$candidate_identity" || fail "target override changed after apply; refusing to overwrite it"
    fi
    file_matches_snapshot "$manifest_path" "$manifest_hash" "$manifest_identity" || fail "manifest changed before reverting target; retaining state"

    if [[ "$target_existed" == true ]]; then
        ensure_directory_path_without_symlinks "$target_dir" || fail "could not prepare target directory safely"
        create_operation_temporary_directory || fail "could not create private operation directory"
        create_temporary_file "DisplayProductID-${product_id}.restore" || fail "could not create restore candidate"
        restore_candidate_path="$TEMPORARY_FILE"
        copy_file_and_verify_hash "$original_path" "$restore_candidate_path" "$original_hash" "$backup_identity" || fail "could not prepare an exact verified restore candidate"
        restore_candidate_identity="$(temporary_file_expected_identity "$restore_candidate_path")" || fail "could not verify restore candidate"
        if [[ "$target_present" == true ]]; then
            restored_target_snapshot="$(replace_file_without_following_directory_link "$restore_candidate_path" "$target_path" "$original_hash" "$restore_candidate_identity" "$candidate_hash" "$target_identity")"
            restore_status=$?
            if ((restore_status != 0)); then
                if ((restore_status == 2)); then
                    fail "restore may have replaced the target before verification or cleanup failed; state was retained for manual inspection"
                fi
                fail "could not atomically restore original override"
            fi
        else
            restored_target_snapshot="$(install_file_without_replacement "$restore_candidate_path" "$target_path" "$original_hash" "$restore_candidate_identity")"
            restore_status=$?
            if ((restore_status != 0)); then
                if ((restore_status == 2)); then
                    fail "restore may have created the target before verification failed; state was retained for manual inspection"
                fi
                fail "target appeared while restoring the original override"
            fi
        fi
        IFS='|' read -r restored_target_hash restored_target_identity <<< "$restored_target_snapshot"
        [[ "$restored_target_hash" == "$original_hash" ]] || fail "restored target does not match the original backup; retaining state"
        valid_file_identity "$restored_target_identity" || fail "could not identify restored target override"
        file_matches_snapshot "$target_path" "$original_hash" "$restored_target_identity" || fail "restored target changed immediately after installation; retaining state"
    elif [[ "$target_existed" == false ]]; then
        if [[ "$target_present" == true ]]; then
            remove_file_if_unchanged "$target_path" "$candidate_hash" "$candidate_identity" || fail "could not remove the unchanged created target override"
        fi
        [[ ! -e "$target_path" && ! -L "$target_path" ]] || fail "created target appeared during revert; retaining state"
    fi

    if [[ "$target_existed" == false ]] && [[ -e "$original_path" || -L "$original_path" ]]; then
        fail "unexpected original backup appeared during revert; retaining state"
    fi

    if [[ "$target_existed" == true ]]; then
        file_matches_snapshot "$target_path" "$original_hash" "$restored_target_identity" || fail "restored target changed before state cleanup; retaining state"
        file_matches_snapshot "$original_path" "$original_hash" "$original_identity" || fail "original backup changed before cleanup; retaining state"
        remove_file_if_unchanged "$original_path" "$original_hash" "$original_identity" || fail "override was restored but original backup could not be removed"
    fi
    if [[ "$target_existed" == false ]]; then
        [[ ! -e "$target_path" && ! -L "$target_path" ]] || fail "created target appeared before state cleanup; retaining state"
    fi
    file_matches_snapshot "$manifest_path" "$manifest_hash" "$manifest_identity" || fail "manifest changed before state cleanup; retaining state"
    remove_file_if_unchanged "$manifest_path" "$manifest_hash" "$manifest_identity" || fail "override was reverted but manifest could not be removed"
    complete_operation_cleanup || fail "revert committed but temporary artifact or operation lock cleanup failed"

    printf 'reverted=%s\n' "$target_relative"
}
