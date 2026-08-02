runtime_resolution_is_valid() {
    local resolution="$1"
    local maximum_dimension="$2"
    local width
    local height

    [[ "$resolution" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]] || return 1
    width="${BASH_REMATCH[1]}"
    height="${BASH_REMATCH[2]}"
    decimal_at_most "$width" "$maximum_dimension" || return 1
    decimal_at_most "$height" "$maximum_dimension"
}

capture_runtime_modes() {
    local vendor_id="$1"
    local product_id="$2"
    local runtime_source="${SCRIPT_DIR}/lib/intel_hidpi_runtime_modes.swift"

    [[ -f "$runtime_source" && ! -L "$runtime_source" ]] || return 1
    [[ -x /usr/bin/swift ]] || return 1
    /usr/bin/swift "$runtime_source" --vendor-id "$vendor_id" --product-id "$product_id"
}

read_bounded_regular_file() {
    local input_file="$1"
    local maximum_bytes="$2"
    local normalized_input_file

    normalized_input_file="$(normalize_lexical_path "$input_file")" || return 1
    darwin_read_bounded_file "$normalized_input_file" "$maximum_bytes"
}

read_offline_mode_capture() {
    local modes_file="$1"
    local maximum_bytes="$2"

    read_bounded_regular_file "$modes_file" "$maximum_bytes"
}

parse_runtime_mode_capture() {
    local capture="$1"
    local expected_vendor_id="$2"
    local expected_product_id="$3"
    local line
    local vendor_value
    local product_value
    local captured_vendor_id
    local captured_product_id
    local logical_resolution
    local pixel_resolution
    local refresh_value
    local flags_value
    local target_seen=false
    local mode_seen=false

    RUNTIME_MODE_PAIRS=""
    [[ -n "$capture" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
        target\|*)
            [[ "$target_seen" == false ]] || return 1
            [[ "$line" =~ ^target\|vendor-id=([^|]+)\|product-id=([^|]+)$ ]] || return 1
            vendor_value="${BASH_REMATCH[1]}"
            product_value="${BASH_REMATCH[2]}"
            captured_vendor_id="$(normalize_hex_id "$vendor_value")" || return 1
            captured_product_id="$(normalize_hex_id "$product_value")" || return 1
            [[ "$captured_vendor_id" == "$expected_vendor_id" && "$captured_product_id" == "$expected_product_id" ]] || return 2
            target_seen=true
            ;;
        mode\|*)
            [[ "$target_seen" == true ]] || return 1
            [[ "$line" =~ ^mode\|logical=([^|]+)\|pixels=([^|]+)\|refresh=([^|]+)\|flags=([^|]+)$ ]] || return 1
            logical_resolution="${BASH_REMATCH[1]}"
            pixel_resolution="${BASH_REMATCH[2]}"
            refresh_value="${BASH_REMATCH[3]}"
            flags_value="${BASH_REMATCH[4]}"
            runtime_resolution_is_valid "$logical_resolution" "$MAX_RUNTIME_MODE_DIMENSION" || return 1
            runtime_resolution_is_valid "$pixel_resolution" "$MAX_RUNTIME_MODE_DIMENSION" || return 1
            [[ "$refresh_value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
            [[ "$flags_value" =~ ^[0-9]+$ ]] || return 1
            RUNTIME_MODE_PAIRS="${RUNTIME_MODE_PAIRS}${RUNTIME_MODE_PAIRS:+$'\n'}${logical_resolution}|${pixel_resolution}"
            mode_seen=true
            ;;
        *)
            return 1
            ;;
        esac
    done <<< "$capture"

    [[ "$target_seen" == true && "$mode_seen" == true ]]
}

collect_generated_mode_records() {
    local native_resolution="$1"
    local mode_set="${2:-$MODE_SET_PRESET}"
    local include_near_native="${3:-false}"
    local include_similar_resolutions="${4:-false}"
    local preview_output
    local line
    local name
    local logical_resolution
    local framebuffer_resolution
    local payload

    GENERATED_MODE_RECORDS=""
    preview_output="$(preview "$native_resolution" "$DEFAULT_FRAMEBUFFER_LIMIT" "$mode_set" "$include_near_native" "$include_similar_resolutions")" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([a-z0-9-]+):\ ([1-9][0-9]*x[1-9][0-9]*)\ framebuffer=([1-9][0-9]*x[1-9][0-9]*)\ payload=([A-Za-z0-9+/]+={0,2})$ ]] || return 1
        name="${BASH_REMATCH[1]}"
        logical_resolution="${BASH_REMATCH[2]}"
        framebuffer_resolution="${BASH_REMATCH[3]}"
        payload="${BASH_REMATCH[4]}"
        runtime_resolution_is_valid "$logical_resolution" "$DEFAULT_FRAMEBUFFER_LIMIT" || return 1
        runtime_resolution_is_valid "$framebuffer_resolution" "$DEFAULT_FRAMEBUFFER_LIMIT" || return 1
        [[ -n "$payload" ]] || return 1
        GENERATED_MODE_RECORDS="${GENERATED_MODE_RECORDS}${GENERATED_MODE_RECORDS:+$'\n'}${name}|${logical_resolution}|${framebuffer_resolution}"
    done <<< "$preview_output"

    [[ -n "$GENERATED_MODE_RECORDS" ]]
}

runtime_mode_pair_is_observed() {
    local logical_resolution="$1"
    local framebuffer_resolution="$2"
    local expected_pair
    local bounded_runtime_pairs

    expected_pair="${logical_resolution}|${framebuffer_resolution}"
    bounded_runtime_pairs=$'\n'"${RUNTIME_MODE_PAIRS}"$'\n'
    [[ "$bounded_runtime_pairs" == *$'\n'"${expected_pair}"$'\n'* ]]
}

verify_mode_capture() {
    local vendor_id="$1"
    local product_id="$2"
    local native_resolution="$3"
    local capture="$4"
    local capture_source="$5"
    local mode_set="${6:-$MODE_SET_PRESET}"
    local include_near_native="${7:-false}"
    local include_similar_resolutions="${8:-false}"
    local capture_status=0
    local name
    local logical_resolution
    local framebuffer_resolution
    local observed_count=0
    local missing_count=0

    case "$capture_source" in
    live-coregraphics|offline-file)
        ;;
    *)
        fail "runtime mode capture source is invalid"
        ;;
    esac

    validate_mode_configuration "$mode_set" "$include_near_native" "$include_similar_resolutions" || fail "mode set or compatibility configuration is invalid"
    collect_generated_mode_records "$native_resolution" "$mode_set" "$include_near_native" "$include_similar_resolutions" || fail "could not generate runtime verification candidates"
    parse_runtime_mode_capture "$capture" "$vendor_id" "$product_id" || capture_status=$?
    case "$capture_status" in
    0)
        ;;
    1)
        fail "runtime mode capture is invalid"
        ;;
    2)
        fail "runtime mode target does not match requested display"
        ;;
    *)
        fail "could not parse runtime mode capture"
        ;;
    esac

    printf 'capture-source=%s\n' "$capture_source"
    printf 'target=%s:%s\n' "$vendor_id" "$product_id"
    while IFS='|' read -r name logical_resolution framebuffer_resolution; do
        if runtime_mode_pair_is_observed "$logical_resolution" "$framebuffer_resolution"; then
            printf '%s: %s framebuffer=%s status=observed\n' "$name" "$logical_resolution" "$framebuffer_resolution"
            observed_count=$((observed_count + 1))
        else
            printf '%s: %s framebuffer=%s status=missing\n' "$name" "$logical_resolution" "$framebuffer_resolution"
            missing_count=$((missing_count + 1))
        fi
    done <<< "$GENERATED_MODE_RECORDS"

    if ((missing_count == 0)); then
        printf 'verification=complete observed=%s missing=0\n' "$observed_count"
        return 0
    fi

    printf 'verification=partial observed=%s missing=%s\n' "$observed_count" "$missing_count"
    return 2
}

run_verify_modes_command() {
    local vendor_id=""
    local product_id=""
    local native_resolution=""
    local modes_file=""
    local mode_set="$MODE_SET_PRESET"
    local include_near_native=false
    local include_similar_resolutions=false
    local vendor_id_provided=false
    local product_id_provided=false
    local native_resolution_provided=false
    local modes_file_provided=false
    local mode_set_provided=false
    local near_native_provided=false
    local similar_resolutions_provided=false
    local capture
    local capture_source="live-coregraphics"
    local capture_status=0

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
        --modes-file)
            (($# >= 2)) || fail "--modes-file requires a regular file path"
            [[ "$modes_file_provided" == false ]] || fail "--modes-file may only be provided once"
            modes_file="$2"
            modes_file_provided=true
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
            fail "unknown verify-modes option: $1"
            ;;
        esac
    done

    [[ -n "$vendor_id" && -n "$product_id" && -n "$native_resolution" ]] || fail "verify-modes requires vendor id, product id, and native resolution"
    vendor_id="$(normalize_hex_id "$vendor_id")" || fail "vendor id is invalid"
    product_id="$(normalize_hex_id "$product_id")" || fail "product id is invalid"
    parse_resolution "$native_resolution" >/dev/null || fail "native resolution must use positive WIDTHxHEIGHT values"
    validate_mode_configuration "$mode_set" "$include_near_native" "$include_similar_resolutions" || fail "mode set or compatibility configuration is invalid"

    if [[ "$modes_file_provided" == true ]]; then
        [[ -n "$modes_file" ]] || fail "--modes-file requires a regular file path"
        capture="$(read_offline_mode_capture "$modes_file" "$MAX_OFFLINE_MODE_CAPTURE_BYTES")" || capture_status=$?
        case "$capture_status" in
        0)
            ;;
        1)
            fail "could not open modes file"
            ;;
        2)
            fail "modes file must be a regular non-symbolic-link text file"
            ;;
        3)
            fail "could not read modes file"
            ;;
        4)
            fail "modes file contains NUL bytes"
            ;;
        5)
            fail "modes file exceeds ${MAX_OFFLINE_MODE_CAPTURE_BYTES} bytes"
            ;;
        7)
            fail "modes file must be a regular non-symbolic-link text file"
            ;;
        *)
            fail "could not read modes file"
            ;;
        esac
        capture_source="offline-file"
    else
        capture="$(capture_runtime_modes "$vendor_id" "$product_id")" || fail "could not capture target display modes"
    fi

    verify_mode_capture "$vendor_id" "$product_id" "$native_resolution" "$capture" "$capture_source" "$mode_set" "$include_near_native" "$include_similar_resolutions"
}
