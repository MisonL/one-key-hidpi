# shellcheck shell=bash

print_payload_set_difference() {
    local label="$1"
    local source_payloads="$2"
    local comparison_payloads="$3"
    local payload

    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        data_payload_list_has_value "$comparison_payloads" "$payload" || printf '%s=%s\n' "$label" "$payload"
    done <<< "$source_payloads"
}

data_payload_entry_count() {
    local payloads="$1"
    local payload
    local payload_count=0

    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        payload_count=$((payload_count + 1))
    done <<< "$payloads"

    printf '%s\n' "$payload_count"
}

summarize_override_payload_set() {
    local expected_payloads="$1"
    local observed_payloads="$2"
    local expected_entry_count="$3"
    local observed_entry_count="$4"
    local expected_count=0
    local observed_count=0
    local matched_count=0
    local missing_count=0
    local extra_count=0
    local duplicate_count
    local payload_set_status
    local payload

    [[ "$expected_entry_count" =~ ^[0-9]+$ && "$observed_entry_count" =~ ^[0-9]+$ ]] || return 1
    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        expected_count=$((expected_count + 1))
        if data_payload_list_has_value "$observed_payloads" "$payload"; then
            matched_count=$((matched_count + 1))
        else
            missing_count=$((missing_count + 1))
        fi
    done <<< "$expected_payloads"
    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        observed_count=$((observed_count + 1))
        data_payload_list_has_value "$expected_payloads" "$payload" || extra_count=$((extra_count + 1))
    done <<< "$observed_payloads"
    [[ "$expected_entry_count" == "$expected_count" ]] || return 1
    duplicate_count=$((observed_entry_count - observed_count))

    if ((missing_count == 0 && extra_count == 0)); then
        payload_set_status="exact"
    elif ((missing_count == 0)); then
        payload_set_status="superset"
    else
        payload_set_status="partial"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$payload_set_status" "$expected_count" "$observed_count" "$matched_count" \
        "$missing_count" "$extra_count" "$duplicate_count"
}

read_verified_override_payloads() {
    local target_path="$1"
    local vendor_decimal="$2"
    local product_decimal="$3"
    local target_snapshot
    local target_hash
    local target_identity
    local observed_payloads

    path_has_disallowed_symbolic_link "$target_path" && {
        printf 'error: target path traverses a symbolic link\n' >&2
        return 1
    }
    [[ -f "$target_path" && ! -L "$target_path" ]] || {
        printf 'error: target override is not a regular file\n' >&2
        return 1
    }
    target_snapshot="$(darwin_file_snapshot "$target_path")" || {
        printf 'error: could not snapshot target override\n' >&2
        return 1
    }
    IFS='|' read -r target_hash target_identity <<< "$target_snapshot"
    if ! valid_sha256 "$target_hash" || ! valid_file_identity "$target_identity"; then
        printf 'error: could not snapshot target override\n' >&2
        return 1
    fi
    plist_file_is_valid "$target_path" "$target_hash" "$target_identity" || {
        printf 'error: target override is invalid or changed while it was read\n' >&2
        return 1
    }
    if [[ "$(plist_raw_value "$target_path" "$target_hash" "$target_identity" DisplayVendorID integer)" != "$vendor_decimal" ]] ||
        [[ "$(plist_raw_value "$target_path" "$target_hash" "$target_identity" DisplayProductID integer)" != "$product_decimal" ]]; then
        printf 'error: override display identifiers do not match the requested target\n' >&2
        return 1
    fi
    observed_payloads="$(verified_scale_payloads_from_override "$target_path" "$target_hash" "$target_identity")" || {
        printf 'error: could not read target override payloads safely\n' >&2
        return 1
    }
    file_matches_snapshot "$target_path" "$target_hash" "$target_identity" || {
        printf 'error: target override changed while it was read\n' >&2
        return 1
    }
    printf '%s' "$observed_payloads"
}

verify_override_payload_set() {
    local vendor_id="$1"
    local product_id="$2"
    local native_resolution="$3"
    local overrides_root="$4"
    local mode_set="${5:-$MODE_SET_PRESET}"
    local include_near_native="${6:-false}"
    local include_similar_resolutions="${7:-false}"
    local target_path
    local target_relative
    local vendor_decimal
    local product_decimal
    local raw_expected_payloads
    local raw_observed_payloads
    local expected_payloads
    local observed_payloads
    local expected_entry_count
    local observed_entry_count
    local payload_set_summary
    local payload_set_status
    local expected_count
    local observed_count
    local matched_count
    local missing_count
    local extra_count
    local duplicate_count

    validate_mode_configuration "$mode_set" "$include_near_native" "$include_similar_resolutions" || fail "mode set or compatibility configuration is invalid"
    parse_resolution "$native_resolution" >/dev/null || fail "native resolution must use positive WIDTHxHEIGHT values"
    vendor_id="$(normalize_hex_id "$vendor_id")" || fail "vendor id is invalid"
    product_id="$(normalize_hex_id "$product_id")" || fail "product id is invalid"
    vendor_decimal="$(decimal_from_hex "$vendor_id")" || fail "vendor id is invalid"
    product_decimal="$(decimal_from_hex "$product_id")" || fail "product id is invalid"
    overrides_root="$(normalize_storage_root "$overrides_root")" || fail "overrides root is invalid or traverses a symbolic link"
    target_path="$(path_for_display "$overrides_root" "$vendor_id" "$product_id")"
    target_relative="DisplayVendorID-${vendor_id}/DisplayProductID-${product_id}"
    raw_expected_payloads="$(payloads_for_resolution "$native_resolution" "$DEFAULT_FRAMEBUFFER_LIMIT" "$mode_set" "$include_near_native" "$include_similar_resolutions")" ||
        fail "could not generate override verification candidates"
    raw_observed_payloads="$(read_verified_override_payloads "$target_path" "$vendor_decimal" "$product_decimal")" || return 1
    validate_data_payload_list "$raw_expected_payloads" || fail "could not generate override verification candidates"
    expected_payloads="$(canonical_data_payload_set "$raw_expected_payloads")" || fail "could not generate override verification candidates"
    observed_payloads="$(canonical_optional_data_payload_set "$raw_observed_payloads")" || fail "target override payloads are invalid"
    expected_entry_count="$(data_payload_entry_count "$raw_expected_payloads")" || fail "could not generate override verification candidates"
    observed_entry_count="$(data_payload_entry_count "$raw_observed_payloads")" || fail "target override payloads are invalid"
    payload_set_summary="$(summarize_override_payload_set "$expected_payloads" "$observed_payloads" "$expected_entry_count" "$observed_entry_count")" ||
        fail "generated override candidates contain duplicate payloads"
    IFS='|' read -r payload_set_status expected_count observed_count matched_count missing_count extra_count duplicate_count <<< "$payload_set_summary"

    printf 'override=%s\n' "$target_relative"
    printf 'target=%s:%s\n' "$vendor_id" "$product_id"
    printf 'payload-set=%s expected=%s observed=%s missing=%s extra=%s duplicates=%s\n' \
        "$payload_set_status" "$expected_count" "$observed_count" "$missing_count" "$extra_count" "$duplicate_count"
    if ((missing_count > 0)); then
        print_payload_set_difference missing-payload "$expected_payloads" "$observed_payloads"
    fi
    if ((extra_count > 0)); then
        print_payload_set_difference extra-payload "$observed_payloads" "$expected_payloads"
    fi
    if [[ "$payload_set_status" == exact ]]; then
        printf 'verification=complete matched=%s missing=0\n' "$matched_count"
        return 0
    fi

    printf 'verification=mismatch matched=%s missing=%s extra=%s\n' "$matched_count" "$missing_count" "$extra_count"
    return 2
}

run_verify_override_command() {
    local vendor_id=""
    local product_id=""
    local native_resolution=""
    local overrides_root="$DEFAULT_OVERRIDES_ROOT"
    local mode_set="$MODE_SET_PRESET"
    local include_near_native=false
    local include_similar_resolutions=false
    local vendor_id_provided=false
    local product_id_provided=false
    local native_resolution_provided=false
    local overrides_root_provided=false
    local mode_set_provided=false
    local near_native_provided=false
    local similar_resolutions_provided=false

    while (($# > 0)); do
        case "$1" in
        --vendor-id)
            (($# >= 2)) || fail "--vendor-id requires a hexadecimal value"
            [[ "$vendor_id_provided" == false ]] || fail "--vendor-id may only be provided once"
            vendor_id="$2"
            vendor_id_provided=true
            shift 2
            ;;
        --product-id)
            (($# >= 2)) || fail "--product-id requires a hexadecimal value"
            [[ "$product_id_provided" == false ]] || fail "--product-id may only be provided once"
            product_id="$2"
            product_id_provided=true
            shift 2
            ;;
        --native-resolution)
            (($# >= 2)) || fail "--native-resolution requires WIDTHxHEIGHT"
            [[ "$native_resolution_provided" == false ]] || fail "--native-resolution may only be provided once"
            native_resolution="$2"
            native_resolution_provided=true
            shift 2
            ;;
        --overrides-root)
            (($# >= 2)) || fail "--overrides-root requires a path"
            [[ "$overrides_root_provided" == false ]] || fail "--overrides-root may only be provided once"
            overrides_root="$2"
            overrides_root_provided=true
            shift 2
            ;;
        --mode-set)
            (($# >= 2)) || fail "--mode-set requires preset or smooth"
            [[ "$mode_set_provided" == false ]] || fail "--mode-set may only be provided once"
            mode_set="$2"
            mode_set_provided=true
            shift 2
            ;;
        --include-near-native)
            [[ "$near_native_provided" == false ]] || fail "--include-near-native may only be provided once"
            include_near_native=true
            near_native_provided=true
            shift
            ;;
        --include-similar-resolutions)
            [[ "$similar_resolutions_provided" == false ]] || fail "--include-similar-resolutions may only be provided once"
            include_similar_resolutions=true
            similar_resolutions_provided=true
            shift
            ;;
        *)
            fail "unknown verify-override option: $1"
            ;;
        esac
    done

    [[ -n "$vendor_id" && -n "$product_id" && -n "$native_resolution" ]] ||
        fail "verify-override requires vendor id, product id, and native resolution"
    verify_override_payload_set "$vendor_id" "$product_id" "$native_resolution" "$overrides_root" \
        "$mode_set" "$include_near_native" "$include_similar_resolutions"
}
