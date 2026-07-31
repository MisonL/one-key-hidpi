readonly MANIFEST_VERSION=5
readonly LEGACY_MANIFEST_VERSION=4

insert_manifest_payloads() {
    local manifest_path="$1"
    local candidate_path="$2"
    local expected_hash="$3"
    local expected_identity="$4"
    local candidate_hash="$5"
    local candidate_identity="$6"
    local payloads
    local payload_array_xml
    local current_hash="$expected_hash"
    local current_identity="$expected_identity"

    payloads="$(verified_scale_payloads_from_override "$candidate_path" "$candidate_hash" "$candidate_identity")" || return 1
    payload_array_xml="$(plist_string_array_xml_from_payloads "$payloads")" || return 1
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" \
        -insert payloads -xml "$payload_array_xml" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    PLIST_OPERATION_HASH="$current_hash"
    PLIST_OPERATION_IDENTITY="$current_identity"
}

write_manifest() {
    local manifest_path="$1"
    local candidate_path="$2"
    local overrides_root="$3"
    local target_relative="$4"
    local target_existed="$5"
    local vendor_id="$6"
    local product_id="$7"
    local native_resolution="$8"
    local original_hash="$9"
    local candidate_hash="${10}"
    local candidate_identity="${11}"
    local expected_hash="${12}"
    local expected_identity="${13}"
    local mode_set="${14:-$MODE_SET_PRESET}"
    local include_near_native="${15:-false}"
    local include_similar_resolutions="${16:-false}"
    local current_hash="$expected_hash"
    local current_identity="$expected_identity"
    local boot_session

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    valid_file_identity "$candidate_identity" || return 1
    validate_mode_configuration "$mode_set" "$include_near_native" "$include_similar_resolutions" || return 1
    boot_session="$(current_boot_session)" || return 1
    [[ "$boot_session" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -create xml1 || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert manifest-version -integer "$MANIFEST_VERSION" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert commit-state -string pending || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert overrides-root -string "$overrides_root" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert target-relative-path -string "$target_relative" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert target-existed -bool "$target_existed" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert vendor-id -string "$vendor_id" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert product-id -string "$product_id" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert native-resolution -string "$native_resolution" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert mode-set -string "$mode_set" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert include-near-native -bool "$include_near_native" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert include-similar-resolutions -bool "$include_similar_resolutions" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert original-sha256 -string "$original_hash" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert candidate-sha256 -string "$candidate_hash" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert candidate-file-identity -string "" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert original-file-identity -string "" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert boot-session -string "$boot_session" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert candidate-persistent-identity -string "" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" -insert original-persistent-identity -string "" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    insert_manifest_payloads "$manifest_path" "$candidate_path" "$current_hash" "$current_identity" "$candidate_hash" "$candidate_identity" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    plist_file_is_valid "$manifest_path" "$current_hash" "$current_identity" || return 1
    PLIST_OPERATION_HASH="$current_hash"
    PLIST_OPERATION_IDENTITY="$current_identity"
}

migrate_v4_manifest() {
    local manifest_path="$1"
    local expected_manifest_hash="$2"
    local expected_manifest_identity="$3"
    local target_existed="$4"
    local candidate_identity="$5"
    local candidate_persistent_identity="$6"
    local original_identity="$7"
    local original_persistent_identity="$8"
    local boot_session="$9"
    local migration_candidate_path
    local migration_hash
    local migration_identity
    local manifest_persistent_snapshot
    local manifest_current_hash
    local manifest_current_identity
    local manifest_persistent_identity
    local migrated_snapshot
    local migrated_hash
    local migrated_identity
    local migrated_persistent_identity
    local migration_status

    valid_sha256 "$expected_manifest_hash" || return 1
    valid_file_identity "$expected_manifest_identity" || return 1
    [[ "$target_existed" == true || "$target_existed" == false ]] || return 1
    [[ "$boot_session" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    valid_file_identity "$candidate_identity" || return 1
    valid_persistent_file_identity "$candidate_persistent_identity" || return 1
    if [[ "$target_existed" == true ]]; then
        valid_file_identity "$original_identity" || return 1
        valid_persistent_file_identity "$original_persistent_identity" || return 1
    else
        [[ -z "$original_identity" && -z "$original_persistent_identity" ]] || return 1
    fi
    manifest_persistent_snapshot="$(darwin_file_persistent_snapshot "$manifest_path")" || return 1
    IFS='|' read -r manifest_current_hash manifest_current_identity manifest_persistent_identity <<< "$manifest_persistent_snapshot"
    [[ "$manifest_current_hash" == "$expected_manifest_hash" && "$manifest_current_identity" == "$expected_manifest_identity" ]] || return 1
    valid_persistent_file_identity "$manifest_persistent_identity" || return 1

    if [[ -z "$OPERATION_TEMPORARY_DIRECTORY" ]]; then
        create_operation_temporary_directory || return 1
    fi
    create_temporary_file "manifest-v5.plist" || return 1
    migration_candidate_path="$TEMPORARY_FILE"
    copy_file_and_verify_hash "$manifest_path" "$migration_candidate_path" "$expected_manifest_hash" "$expected_manifest_identity" "$manifest_persistent_identity" || return 1
    migration_hash="$(temporary_file_expected_hash "$migration_candidate_path")" || return 1
    migration_identity="$(temporary_file_expected_identity "$migration_candidate_path")" || return 1

    run_plutil_and_update_hash "$migration_candidate_path" "$migration_hash" "$migration_identity" -replace manifest-version -integer "$MANIFEST_VERSION" || return 1
    migration_hash="$PLIST_OPERATION_HASH"
    migration_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$migration_candidate_path" "$migration_hash" "$migration_identity" -replace candidate-file-identity -string "$candidate_identity" || return 1
    migration_hash="$PLIST_OPERATION_HASH"
    migration_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$migration_candidate_path" "$migration_hash" "$migration_identity" -replace original-file-identity -string "$original_identity" || return 1
    migration_hash="$PLIST_OPERATION_HASH"
    migration_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$migration_candidate_path" "$migration_hash" "$migration_identity" -insert boot-session -string "$boot_session" || return 1
    migration_hash="$PLIST_OPERATION_HASH"
    migration_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$migration_candidate_path" "$migration_hash" "$migration_identity" -insert candidate-persistent-identity -string "$candidate_persistent_identity" || return 1
    migration_hash="$PLIST_OPERATION_HASH"
    migration_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$migration_candidate_path" "$migration_hash" "$migration_identity" -insert original-persistent-identity -string "$original_persistent_identity" || return 1
    migration_hash="$PLIST_OPERATION_HASH"
    migration_identity="$PLIST_OPERATION_IDENTITY"
    plist_file_is_valid "$migration_candidate_path" "$migration_hash" "$migration_identity" || return 1
    record_temporary_file_snapshot "$migration_candidate_path" "$migration_hash" "$migration_identity" || return 1
    file_matches_persistent_snapshot "$manifest_path" "$expected_manifest_hash" "$expected_manifest_identity" "$manifest_persistent_identity" || return 1

    migrated_snapshot="$(replace_file_without_following_directory_link_persistent "$migration_candidate_path" "$manifest_path" "$migration_hash" "$migration_identity" "$expected_manifest_hash" "$expected_manifest_identity" "$manifest_persistent_identity")"
    migration_status=$?
    ((migration_status == 0)) || return "$migration_status"
    IFS='|' read -r migrated_hash migrated_identity migrated_persistent_identity <<< "$migrated_snapshot"
    valid_sha256 "$migrated_hash" || return 1
    valid_file_identity "$migrated_identity" || return 1
    valid_persistent_file_identity "$migrated_persistent_identity" || return 1
    file_matches_persistent_snapshot "$manifest_path" "$migrated_hash" "$migrated_identity" "$migrated_persistent_identity" || return 1
    PLIST_OPERATION_HASH="$migrated_hash"
    PLIST_OPERATION_IDENTITY="$migrated_identity"
}

record_pending_manifest_original_identity() {
    local manifest_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local original_identity="$4"
    local original_persistent_identity="$5"
    local commit_state
    local recorded_original_identity
    local recorded_original_persistent_identity

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    valid_file_identity "$original_identity" || return 1
    valid_persistent_file_identity "$original_persistent_identity" || return 1
    commit_state="$(plist_raw_value "$manifest_path" "$expected_hash" "$expected_identity" commit-state string)" || return 1
    [[ "$commit_state" == pending ]] || return 1
    recorded_original_identity="$(plist_raw_value "$manifest_path" "$expected_hash" "$expected_identity" original-file-identity string)" || return 1
    [[ -z "$recorded_original_identity" ]] || return 1
    recorded_original_persistent_identity="$(plist_raw_value "$manifest_path" "$expected_hash" "$expected_identity" original-persistent-identity string)" || return 1
    [[ -z "$recorded_original_persistent_identity" ]] || return 1
    run_plutil_and_update_hash "$manifest_path" "$expected_hash" "$expected_identity" \
        -replace original-file-identity -string "$original_identity" || return 1
    run_plutil_and_update_hash "$manifest_path" "$PLIST_OPERATION_HASH" "$PLIST_OPERATION_IDENTITY" \
        -replace original-persistent-identity -string "$original_persistent_identity"
}

finalize_pending_manifest() {
    local manifest_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local candidate_identity="$4"
    local candidate_persistent_identity="$5"
    local current_hash="$expected_hash"
    local current_identity="$expected_identity"
    local commit_state
    local recorded_candidate_identity
    local recorded_candidate_persistent_identity

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    valid_file_identity "$candidate_identity" || return 1
    valid_persistent_file_identity "$candidate_persistent_identity" || return 1
    commit_state="$(plist_raw_value "$manifest_path" "$current_hash" "$current_identity" commit-state string)" || return 1
    [[ "$commit_state" == pending ]] || return 1
    recorded_candidate_identity="$(plist_raw_value "$manifest_path" "$current_hash" "$current_identity" candidate-file-identity string)" || return 1
    [[ -z "$recorded_candidate_identity" ]] || return 1
    recorded_candidate_persistent_identity="$(plist_raw_value "$manifest_path" "$current_hash" "$current_identity" candidate-persistent-identity string)" || return 1
    [[ -z "$recorded_candidate_persistent_identity" ]] || return 1
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" \
        -replace candidate-file-identity -string "$candidate_identity" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" \
        -replace candidate-persistent-identity -string "$candidate_persistent_identity" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$manifest_path" "$current_hash" "$current_identity" \
        -replace commit-state -string committed || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    plist_file_is_valid "$manifest_path" "$current_hash" "$current_identity" || return 1
    PLIST_OPERATION_HASH="$current_hash"
    PLIST_OPERATION_IDENTITY="$current_identity"
}

read_revert_manifest() {
    local manifest_path="$1"
    local vendor_id="$2"
    local product_id="$3"
    local target_relative="$4"
    local overrides_root="$5"
    local manifest_version
    local manifest_vendor
    local manifest_product
    local manifest_overrides_root
    local manifest_relative
    local manifest_native_resolution
    local commit_state
    local target_existed
    local candidate_hash
    local original_hash
    local candidate_identity
    local original_identity
    local candidate_persistent_identity
    local original_persistent_identity
    local boot_session
    local payload_count
    local manifest_hash_before
    local manifest_identity_before
    local manifest_persistent_identity_before
    local manifest_snapshot

    manifest_snapshot="$(darwin_file_persistent_snapshot "$manifest_path")" || return 1
    IFS='|' read -r manifest_hash_before manifest_identity_before manifest_persistent_identity_before <<< "$manifest_snapshot"
    valid_sha256 "$manifest_hash_before" || return 1
    valid_file_identity "$manifest_identity_before" || return 1
    valid_persistent_file_identity "$manifest_persistent_identity_before" || return 1

    read_revert_manifest_failure() {
        if file_matches_persistent_snapshot "$manifest_path" "$manifest_hash_before" "$manifest_identity_before" "$manifest_persistent_identity_before"; then
            return 1
        fi
        return 4
    }

    read_revert_manifest_value() {
        local key_path="$1"
        local expected_type="$2"

        plist_raw_value "$manifest_path" "$manifest_hash_before" "$manifest_identity_before" "$key_path" "$expected_type" || {
            read_revert_manifest_failure
            return $?
        }
    }

    plist_file_is_valid "$manifest_path" "$manifest_hash_before" "$manifest_identity_before" || {
        read_revert_manifest_failure
        return $?
    }
    manifest_version="$(read_revert_manifest_value manifest-version integer)" || return $?
    [[ "$manifest_version" == "$MANIFEST_VERSION" || "$manifest_version" == "$LEGACY_MANIFEST_VERSION" ]] || return 2
    commit_state="$(read_revert_manifest_value commit-state string)" || return $?
    [[ "$commit_state" == committed ]] || return 5
    manifest_vendor="$(read_revert_manifest_value vendor-id string)" || return $?
    manifest_product="$(read_revert_manifest_value product-id string)" || return $?
    manifest_overrides_root="$(read_revert_manifest_value overrides-root string)" || return $?
    manifest_relative="$(read_revert_manifest_value target-relative-path string)" || return $?
    manifest_native_resolution="$(read_revert_manifest_value native-resolution string)" || return $?
    target_existed="$(read_revert_manifest_value target-existed bool)" || return $?
    candidate_hash="$(read_revert_manifest_value candidate-sha256 string)" || return $?
    original_hash="$(read_revert_manifest_value original-sha256 string)" || return $?
    candidate_identity="$(read_revert_manifest_value candidate-file-identity string)" || return $?
    original_identity="$(read_revert_manifest_value original-file-identity string)" || return $?
    if [[ "$manifest_version" == "$MANIFEST_VERSION" ]]; then
        boot_session="$(read_revert_manifest_value boot-session string)" || return $?
        candidate_persistent_identity="$(read_revert_manifest_value candidate-persistent-identity string)" || return $?
        original_persistent_identity="$(read_revert_manifest_value original-persistent-identity string)" || return $?
    else
        boot_session=""
        candidate_persistent_identity=""
        original_persistent_identity=""
    fi
    payload_count="$(read_revert_manifest_value payloads array)" || return $?

    [[ "$manifest_vendor" == "$vendor_id" && "$manifest_product" == "$product_id" ]] || return 1
    [[ "$manifest_overrides_root" == "$overrides_root" ]] || return 3
    [[ "$manifest_relative" == "$target_relative" ]] || return 1
    parse_resolution "$manifest_native_resolution" >/dev/null || return 1
    [[ "$target_existed" == true || "$target_existed" == false ]] || return 1
    valid_sha256 "$candidate_hash" || return 1
    if [[ "$manifest_version" == "$MANIFEST_VERSION" ]]; then
        [[ "$boot_session" =~ ^[0-9]+:[0-9]+$ ]] || return 1
        valid_file_identity "$candidate_identity" || return 1
        valid_persistent_file_identity "$candidate_persistent_identity" || return 1
    else
        valid_file_identity "$candidate_identity" || return 1
    fi
    [[ "$payload_count" =~ ^[1-9][0-9]*$ ]] || return 1

    if [[ "$target_existed" == true ]]; then
        valid_sha256 "$original_hash" || return 1
        valid_file_identity "$original_identity" || return 1
        if [[ "$manifest_version" == "$MANIFEST_VERSION" ]]; then
            valid_persistent_file_identity "$original_persistent_identity" || return 1
        fi
    else
        [[ -z "$original_hash" ]] || return 1
        [[ -z "$original_identity" ]] || return 1
        [[ -z "$original_persistent_identity" ]] || return 1
    fi

    file_matches_persistent_snapshot "$manifest_path" "$manifest_hash_before" "$manifest_identity_before" "$manifest_persistent_identity_before" || return 4

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$manifest_version" "$target_existed" "$candidate_hash" "$candidate_identity" "$candidate_persistent_identity" "$original_hash" "$original_identity" "$original_persistent_identity" \
        "$boot_session" "$manifest_hash_before" "$manifest_identity_before" "$manifest_persistent_identity_before"
}
