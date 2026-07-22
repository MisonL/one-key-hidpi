TEMPORARY_FILES=("")
TEMPORARY_FILE=""

cleanup_temporary_files() {
    local temporary_file

    for temporary_file in "${TEMPORARY_FILES[@]}"; do
        [[ -n "$temporary_file" && -e "$temporary_file" ]] || continue
        /bin/rm -f "$temporary_file"
    done
}

trap cleanup_temporary_files EXIT

normalize_hex_id() {
    local value="$1"

    [[ "$value" =~ ^[0-9A-Fa-f]{1,8}$ ]] || return 1
    printf '%s\n' "$(printf '%08x' "$((16#$value))" | /usr/bin/sed 's/^0*//; s/^$/0/')"
}

parse_apply_request() {
    local vendor_id="$1"
    local product_id="$2"
    local native_resolution="$3"
    local vendor_decimal
    local product_decimal

    vendor_id="$(normalize_hex_id "$vendor_id")" || return 1
    product_id="$(normalize_hex_id "$product_id")" || return 1
    vendor_decimal="$(decimal_from_hex "$vendor_id")" || return 1
    product_decimal="$(decimal_from_hex "$product_id")" || return 1
    parse_resolution "$native_resolution" >/dev/null || return 1
    printf '%s|%s|%s|%s\n' "$vendor_id" "$product_id" "$vendor_decimal" "$product_decimal"
}

path_for_display() {
    local root="$1"
    local vendor_id="$2"
    local product_id="$3"

    printf '%s/DisplayVendorID-%s/DisplayProductID-%s\n' "$root" "$vendor_id" "$product_id"
}

state_dir_for_display() {
    local state_root="$1"
    local vendor_id="$2"
    local product_id="$3"

    printf '%s/DisplayVendorID-%s/DisplayProductID-%s\n' "$state_root" "$vendor_id" "$product_id"
}

create_temporary_file() {
    local directory="$1"
    local label="$2"

    TEMPORARY_FILE="$(/usr/bin/mktemp "${directory}/.${label}.XXXXXX")" || return 1
    TEMPORARY_FILES+=("$TEMPORARY_FILE")
}

directory_is_empty() {
    local directory="$1"
    local first_entry

    [[ ! -e "$directory" ]] && return 0
    [[ -d "$directory" ]] || return 1
    first_entry="$(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" || return 1
    [[ -z "$first_entry" ]]
}

require_root_for_system_paths() {
    local overrides_root="$1"
    local state_root="$2"

    if [[ "$overrides_root" == "$DEFAULT_OVERRIDES_ROOT" || "$state_root" == "$DEFAULT_STATE_ROOT" ]]; then
        ((EUID == 0)) || fail "writing default system paths requires root; rerun explicitly with sudo"
    fi
}

set_written_file_permissions() {
    local path="$1"
    local system_path="$2"

    /bin/chmod 0644 "$path" || return 1
    if [[ "$system_path" == true ]]; then
        /usr/sbin/chown root:wheel "$path" || return 1
    fi
}

valid_sha256() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

payloads_for_resolution() {
    local native_resolution="$1"
    local framebuffer_limit="$2"
    local preview_output

    preview_output="$(preview "$native_resolution" "$framebuffer_limit")" || return 1
    printf '%s\n' "$preview_output" | /usr/bin/sed -n 's/.* payload=\([A-Za-z0-9+\/]*=*\)$/\1/p'
}

ensure_scale_resolutions_array() {
    local candidate_path="$1"

    if /usr/bin/plutil -extract scale-resolutions raw -expect array -o - "$candidate_path" >/dev/null 2>&1; then
        return 0
    fi
    /usr/bin/plutil -insert scale-resolutions -array "$candidate_path"
}

append_missing_payloads() {
    local candidate_path="$1"
    local native_resolution="$2"
    local framebuffer_limit="$3"
    local payload
    local generated_payloads
    local existing_payloads
    local payload_count

    generated_payloads="$(payloads_for_resolution "$native_resolution" "$framebuffer_limit")" || return 1
    ensure_scale_resolutions_array "$candidate_path" || return 1
    existing_payloads="$(scale_payloads_from_override "$candidate_path")" || return 1
    payload_count="$(/usr/bin/plutil -extract scale-resolutions raw -expect array -o - "$candidate_path")" || return 1

    while IFS= read -r payload; do
        [[ -n "$payload" ]] || continue
        if ! printf '%s\n' "$existing_payloads" | /usr/bin/grep -Fqx "$payload"; then
            /usr/bin/plutil -insert "scale-resolutions.${payload_count}" -data "$payload" "$candidate_path" || return 1
            existing_payloads="${existing_payloads}${existing_payloads:+$'\n'}${payload}"
            payload_count=$((payload_count + 1))
        fi
    done <<< "$generated_payloads"
}

create_base_override() {
    local target_path="$1"
    local vendor_decimal="$2"
    local product_decimal="$3"

    /usr/bin/plutil -create xml1 "$target_path" || return 1
    /usr/bin/plutil -insert DisplayVendorID -integer "$vendor_decimal" "$target_path" || return 1
    /usr/bin/plutil -insert DisplayProductID -integer "$product_decimal" "$target_path" || return 1
    /usr/bin/plutil -insert scale-resolutions -array "$target_path"
}

validate_candidate_override() {
    local candidate_path="$1"
    local vendor_decimal="$2"
    local product_decimal="$3"
    local payload_count

    /usr/bin/plutil -lint "$candidate_path" >/dev/null || return 1
    [[ "$(/usr/bin/plutil -extract DisplayVendorID raw -expect integer -o - "$candidate_path")" == "$vendor_decimal" ]] || return 1
    [[ "$(/usr/bin/plutil -extract DisplayProductID raw -expect integer -o - "$candidate_path")" == "$product_decimal" ]] || return 1
    payload_count="$(/usr/bin/plutil -extract scale-resolutions raw -expect array -o - "$candidate_path")" || return 1
    [[ "$payload_count" =~ ^[1-9][0-9]*$ ]]
}

insert_manifest_payloads() {
    local manifest_path="$1"
    local candidate_path="$2"
    local payloads
    local payload
    local payload_count=0

    /usr/bin/plutil -insert payloads -array "$manifest_path" || return 1
    payloads="$(scale_payloads_from_override "$candidate_path")" || return 1

    while IFS= read -r payload; do
        [[ -n "$payload" ]] || continue
        /usr/bin/plutil -insert "payloads.${payload_count}" -string "$payload" "$manifest_path" || return 1
        payload_count=$((payload_count + 1))
    done <<< "$payloads"

    ((payload_count > 0))
}

write_manifest() {
    local manifest_path="$1"
    local candidate_path="$2"
    local target_relative="$3"
    local target_existed="$4"
    local vendor_id="$5"
    local product_id="$6"
    local native_resolution="$7"
    local original_hash="$8"
    local candidate_hash="$9"

    /usr/bin/plutil -create xml1 "$manifest_path" || return 1
    # shellcheck disable=SC2153
    /usr/bin/plutil -insert manifest-version -integer "$MANIFEST_VERSION" "$manifest_path" || return 1
    /usr/bin/plutil -insert target-relative-path -string "$target_relative" "$manifest_path" || return 1
    /usr/bin/plutil -insert target-existed -bool "$target_existed" "$manifest_path" || return 1
    /usr/bin/plutil -insert vendor-id -string "$vendor_id" "$manifest_path" || return 1
    /usr/bin/plutil -insert product-id -string "$product_id" "$manifest_path" || return 1
    /usr/bin/plutil -insert native-resolution -string "$native_resolution" "$manifest_path" || return 1
    /usr/bin/plutil -insert original-sha256 -string "$original_hash" "$manifest_path" || return 1
    /usr/bin/plutil -insert candidate-sha256 -string "$candidate_hash" "$manifest_path" || return 1
    insert_manifest_payloads "$manifest_path" "$candidate_path" || return 1
    /usr/bin/plutil -lint "$manifest_path" >/dev/null
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

target_matches_pre_apply_state() {
    local target_path="$1"
    local target_existed="$2"
    local original_hash="$3"
    local current_hash

    if [[ "$target_existed" == true ]]; then
        [[ -f "$target_path" ]] || return 1
        current_hash="$(sha256_file "$target_path")" || return 1
        [[ "$current_hash" == "$original_hash" ]]
    else
        [[ ! -e "$target_path" ]]
    fi
}

remove_apply_state() {
    local manifest_path="$1"
    local original_path="$2"
    local state_dir="$3"
    local cleanup_failed=false

    if [[ -e "$manifest_path" ]] && ! /bin/rm -f "$manifest_path"; then
        cleanup_failed=true
    fi
    if [[ -e "$original_path" ]] && ! /bin/rm -f "$original_path"; then
        cleanup_failed=true
    fi
    /bin/rmdir "$state_dir" 2>/dev/null || true
    /bin/rmdir "$(/usr/bin/dirname "$state_dir")" 2>/dev/null || true
    [[ "$cleanup_failed" == false ]]
}

commit_apply_state() {
    local target_path="$1"
    local candidate_path="$2"
    local target_existed="$3"
    local original_hash="$4"
    local backup_candidate_path="$5"
    local original_path="$6"
    local manifest_candidate_path="$7"
    local manifest_path="$8"
    local state_dir="$9"

    if [[ "$target_existed" == true ]] && ! /bin/mv -f "$backup_candidate_path" "$original_path"; then
        printf 'error: could not store exact original backup\n' >&2
        return 1
    fi
    if ! /bin/mv -f "$manifest_candidate_path" "$manifest_path"; then
        remove_apply_state "$manifest_path" "$original_path" "$state_dir" || printf 'error: could not install manifest and could not clean up state\n' >&2
        return 1
    fi
    if ! target_matches_pre_apply_state "$target_path" "$target_existed" "$original_hash"; then
        remove_apply_state "$manifest_path" "$original_path" "$state_dir" || printf 'error: target changed before apply and state cleanup failed\n' >&2
        printf 'error: target changed after validation; no override was written\n' >&2
        return 1
    fi
    if ! /bin/mv -f "$candidate_path" "$target_path"; then
        remove_apply_state "$manifest_path" "$original_path" "$state_dir" || printf 'error: could not replace target and state cleanup failed\n' >&2
        printf 'error: could not atomically replace target override\n' >&2
        return 1
    fi
}

read_revert_manifest() {
    local manifest_path="$1"
    local vendor_id="$2"
    local product_id="$3"
    local target_relative="$4"
    local manifest_version
    local manifest_vendor
    local manifest_product
    local manifest_relative
    local manifest_native_resolution
    local target_existed
    local candidate_hash
    local original_hash
    local payload_count

    /usr/bin/plutil -lint "$manifest_path" >/dev/null || return 1
    manifest_version="$(/usr/bin/plutil -extract manifest-version raw -expect integer -o - "$manifest_path")" || return 1
    manifest_vendor="$(/usr/bin/plutil -extract vendor-id raw -expect string -o - "$manifest_path")" || return 1
    manifest_product="$(/usr/bin/plutil -extract product-id raw -expect string -o - "$manifest_path")" || return 1
    manifest_relative="$(/usr/bin/plutil -extract target-relative-path raw -expect string -o - "$manifest_path")" || return 1
    manifest_native_resolution="$(/usr/bin/plutil -extract native-resolution raw -expect string -o - "$manifest_path")" || return 1
    target_existed="$(/usr/bin/plutil -extract target-existed raw -expect bool -o - "$manifest_path")" || return 1
    candidate_hash="$(/usr/bin/plutil -extract candidate-sha256 raw -expect string -o - "$manifest_path")" || return 1
    original_hash="$(/usr/bin/plutil -extract original-sha256 raw -expect string -o - "$manifest_path")" || return 1
    payload_count="$(/usr/bin/plutil -extract payloads raw -expect array -o - "$manifest_path")" || return 1

    [[ "$manifest_version" == "$MANIFEST_VERSION" ]] || return 1
    [[ "$manifest_vendor" == "$vendor_id" && "$manifest_product" == "$product_id" ]] || return 1
    [[ "$manifest_relative" == "$target_relative" ]] || return 1
    parse_resolution "$manifest_native_resolution" >/dev/null || return 1
    [[ "$target_existed" == true || "$target_existed" == false ]] || return 1
    valid_sha256 "$candidate_hash" || return 1
    [[ "$payload_count" =~ ^[1-9][0-9]*$ ]] || return 1

    if [[ "$target_existed" == true ]]; then
        valid_sha256 "$original_hash" || return 1
    else
        [[ -z "$original_hash" ]] || return 1
    fi

    printf '%s|%s|%s\n' "$target_existed" "$candidate_hash" "$original_hash"
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
    local candidate_hash
    local overrides_are_system_paths=false
    local state_is_system_path=false

    [[ "$confirmed" == true ]] || fail "apply requires --confirm"
    apply_request="$(parse_apply_request "$vendor_id" "$product_id" "$native_resolution")" || fail "vendor id, product id, or native resolution is invalid"
    IFS='|' read -r vendor_id product_id vendor_decimal product_decimal <<< "$apply_request"
    require_root_for_system_paths "$overrides_root" "$state_root"
    [[ "$overrides_root" == "$DEFAULT_OVERRIDES_ROOT" ]] && overrides_are_system_paths=true
    [[ "$state_root" == "$DEFAULT_STATE_ROOT" ]] && state_is_system_path=true

    target_path="$(path_for_display "$overrides_root" "$vendor_id" "$product_id")"
    target_relative="DisplayVendorID-${vendor_id}/DisplayProductID-${product_id}"
    target_dir="$(/usr/bin/dirname "$target_path")"
    state_dir="$(state_dir_for_display "$state_root" "$vendor_id" "$product_id")"
    original_path="${state_dir}/original.plist"
    manifest_path="${state_dir}/manifest.plist"

    [[ ! -e "$manifest_path" && ! -e "$original_path" ]] || fail "existing state requires manual inspection before another apply"
    directory_is_empty "$state_dir" || fail "state directory must be empty before apply"
    /bin/mkdir -p "$target_dir" "$state_dir" || fail "could not create target or state directory"
    create_temporary_file "$target_dir" "DisplayProductID-${product_id}.candidate" || fail "could not create target candidate"
    candidate_path="$TEMPORARY_FILE"

    if [[ -f "$target_path" ]]; then
        target_existed=true
        create_temporary_file "$state_dir" "original.plist" || fail "could not create original backup candidate"
        backup_candidate_path="$TEMPORARY_FILE"
        /bin/cp -p "$target_path" "$backup_candidate_path" || fail "could not create exact original backup"
        set_written_file_permissions "$backup_candidate_path" "$state_is_system_path" || fail "could not set original backup permissions"
        original_hash="$(sha256_file "$backup_candidate_path")" || fail "could not hash original override"
        /bin/cp "$target_path" "$candidate_path" || fail "could not create candidate override"
    elif [[ -e "$target_path" ]]; then
        fail "target override exists but is not a regular file"
    else
        create_base_override "$candidate_path" "$vendor_decimal" "$product_decimal" || fail "could not create base override"
    fi

    append_missing_payloads "$candidate_path" "$native_resolution" "$DEFAULT_FRAMEBUFFER_LIMIT" || fail "could not merge generated modes"
    validate_candidate_override "$candidate_path" "$vendor_decimal" "$product_decimal" || fail "candidate override did not validate"
    set_written_file_permissions "$candidate_path" "$overrides_are_system_paths" || fail "could not set candidate permissions"
    candidate_hash="$(sha256_file "$candidate_path")" || fail "could not hash candidate override"
    create_temporary_file "$state_dir" "manifest.plist" || fail "could not create manifest candidate"
    manifest_candidate_path="$TEMPORARY_FILE"
    write_manifest "$manifest_candidate_path" "$candidate_path" "$target_relative" "$target_existed" "$vendor_id" "$product_id" "$native_resolution" "$original_hash" "$candidate_hash" || fail "could not write manifest"
    set_written_file_permissions "$manifest_candidate_path" "$state_is_system_path" || fail "could not set manifest permissions"
    commit_apply_state "$target_path" "$candidate_path" "$target_existed" "$original_hash" "$backup_candidate_path" "$original_path" "$manifest_candidate_path" "$manifest_path" "$state_dir" || fail "apply did not complete; target override was not replaced"

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
    local candidate_hash
    local original_hash
    local current_hash
    local backup_hash
    local restore_candidate_path
    local overrides_are_system_paths=false

    [[ "$confirmed" == true ]] || fail "revert requires --confirm"
    vendor_id="$(normalize_hex_id "$vendor_id")" || fail "vendor id must be hexadecimal"
    product_id="$(normalize_hex_id "$product_id")" || fail "product id must be hexadecimal"
    require_root_for_system_paths "$overrides_root" "$state_root"
    [[ "$overrides_root" == "$DEFAULT_OVERRIDES_ROOT" ]] && overrides_are_system_paths=true
    target_path="$(path_for_display "$overrides_root" "$vendor_id" "$product_id")"
    target_dir="$(/usr/bin/dirname "$target_path")"
    target_relative="DisplayVendorID-${vendor_id}/DisplayProductID-${product_id}"
    state_dir="$(state_dir_for_display "$state_root" "$vendor_id" "$product_id")"
    manifest_path="${state_dir}/manifest.plist"
    original_path="${state_dir}/original.plist"

    [[ -f "$manifest_path" ]] || fail "no manifest exists for this target"
    manifest_metadata="$(read_revert_manifest "$manifest_path" "$vendor_id" "$product_id" "$target_relative")" || fail "manifest is invalid or does not match this display"
    IFS='|' read -r target_existed candidate_hash original_hash <<< "$manifest_metadata"
    [[ -f "$target_path" ]] || fail "target override is missing; refusing to alter state"
    current_hash="$(sha256_file "$target_path")" || fail "could not hash current target override"
    [[ "$current_hash" == "$candidate_hash" ]] || fail "target override changed after apply; refusing to overwrite it"

    if [[ "$target_existed" == true ]]; then
        [[ -f "$original_path" ]] || fail "original backup is missing"
        /usr/bin/plutil -lint "$original_path" >/dev/null || fail "original backup is invalid"
        backup_hash="$(sha256_file "$original_path")" || fail "could not hash original backup"
        [[ "$backup_hash" == "$original_hash" ]] || fail "original backup changed after apply; refusing to restore it"
        create_temporary_file "$target_dir" "DisplayProductID-${product_id}.restore" || fail "could not create restore candidate"
        restore_candidate_path="$TEMPORARY_FILE"
        /bin/cp -p "$original_path" "$restore_candidate_path" || fail "could not prepare exact restore candidate"
        set_written_file_permissions "$restore_candidate_path" "$overrides_are_system_paths" || fail "could not set restore candidate permissions"
        /bin/mv -f "$restore_candidate_path" "$target_path" || fail "could not atomically restore original override"
    elif [[ "$target_existed" == false ]]; then
        /bin/rm -f "$target_path" || fail "could not remove created target override"
    else
        fail "manifest target state is invalid"
    fi

    if [[ "$target_existed" == true ]] && ! /bin/rm -f "$original_path"; then
        fail "override was restored but original backup could not be removed"
    fi
    /bin/rm -f "$manifest_path" || fail "override was reverted but manifest could not be removed"
    /bin/rmdir "$state_dir" 2>/dev/null || true
    /bin/rmdir "$(/usr/bin/dirname "$state_dir")" 2>/dev/null || true

    printf 'reverted=%s\n' "$target_relative"
}
