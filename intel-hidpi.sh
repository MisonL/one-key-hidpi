#!/bin/bash

set -u
set -o pipefail

readonly DEFAULT_OVERRIDES_ROOT="/Library/Displays/Contents/Resources/Overrides"
readonly DEFAULT_STATE_ROOT="/Library/Application Support/one-key-hidpi"
readonly DEFAULT_FRAMEBUFFER_LIMIT=8192
readonly MAX_NATIVE_DIMENSION=$((DEFAULT_FRAMEBUFFER_LIMIT / 2))
readonly MAX_RUNTIME_MODE_DIMENSION=9999999999
readonly MAX_OFFLINE_MODE_CAPTURE_BYTES=1048576
readonly PRESET_NAMES=("compact" "balanced" "spacious" "dense" "native")
readonly PRESET_NUMERATORS=(1 3 2 3 1)
readonly PRESET_DENOMINATORS=(2 5 3 4 1)

usage() {
    /bin/cat <<'EOF'
Usage:
  intel-hidpi.sh inventory [--ioreg-file PATH] [--overrides-root PATH]
  intel-hidpi.sh native-resolution --edid HEX
  intel-hidpi.sh preview --native-resolution WIDTHxHEIGHT [--framebuffer-limit PIXELS] [--mode-set preset|smooth] [--include-near-native] [--include-similar-resolutions]
  intel-hidpi.sh verify-modes --vendor-id HEX --product-id HEX --native-resolution WIDTHxHEIGHT [--mode-set preset|smooth] [--include-near-native] [--include-similar-resolutions] [--modes-file PATH]
  intel-hidpi.sh verify-override --vendor-id HEX --product-id HEX --native-resolution WIDTHxHEIGHT [--mode-set preset|smooth] [--include-near-native] [--include-similar-resolutions] [--overrides-root PATH]
  intel-hidpi.sh apply --vendor-id HEX --product-id HEX --native-resolution WIDTHxHEIGHT [--mode-set preset|smooth] [--include-near-native] [--include-similar-resolutions] [--overrides-root PATH] [--state-root PATH] --confirm
  intel-hidpi.sh revert --vendor-id HEX --product-id HEX [--overrides-root PATH] [--state-root PATH] [--migrate-v4] --confirm

Commands:
  inventory  Read connected Intel-compatible external display metadata and
             existing EDID override modes. This command never writes files.
  native-resolution  Read one EDID and print its preferred panel resolution.
  preview    Generate candidate 2x HiDPI modes without writing an override.
  verify-modes  Read modes for exactly one connected display and report whether
                every generated candidate is exposed with its 2x framebuffer.
  verify-override  Read one target override and report whether its payload set
                   contains every generated candidate. This command never writes files.
  apply      Merge generated modes into one target override after confirmation.
  revert     Restore or remove only the target override recorded by apply.
             Legacy v4 state requires the explicit --migrate-v4 acknowledgment.
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

[[ ! -L "${BASH_SOURCE[0]}" ]] || fail "Intel HiDPI requires a regular local checkout entrypoint"

decimal_from_hex() {
    local value="$1"

    [[ "$value" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    printf '%d\n' "$((16#$value))"
}

decimal_at_most() {
    local value="$1"
    local limit="$2"

    [[ "$value" =~ ^[1-9][0-9]*$ && "$limit" =~ ^[1-9][0-9]*$ ]] || return 1
    if ((${#value} < ${#limit})); then
        return 0
    fi
    if ((${#value} > ${#limit})); then
        return 1
    fi
    [[ "$value" == "$limit" || "$value" < "$limit" ]]
}

parse_resolution() {
    local resolution="$1"
    local width
    local height

    [[ "$resolution" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]] || return 1
    width="${BASH_REMATCH[1]}"
    height="${BASH_REMATCH[2]}"
    decimal_at_most "$width" "$MAX_NATIVE_DIMENSION" || return 1
    decimal_at_most "$height" "$MAX_NATIVE_DIMENSION" || return 1
    printf '%s:%s\n' "$width" "$height"
}

normalize_edid() {
    local edid="$1"
    local normalized_edid
    local checksum=0
    local index
    local byte_hex

    [[ "$edid" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    (( ${#edid} >= 256 && ${#edid} % 256 == 0 )) || return 1
    normalized_edid="$(printf '%s' "$edid" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    [[ "${normalized_edid:0:16}" == "00ffffffffffff00" ]] || return 1

    for ((index = 0; index < 256; index += 2)); do
        byte_hex="${normalized_edid:index:2}"
        checksum=$((checksum + 16#$byte_hex))
    done
    ((checksum % 256 == 0)) || return 1

    printf '%s\n' "$normalized_edid"
}

scale_dimension_to_even() {
    local input_dimension="$1"
    local numerator="$2"
    local denominator="$3"
    local scaled_dimension

    scaled_dimension=$(((input_dimension * numerator + denominator / 2) / denominator))
    scaled_dimension=$((scaled_dimension - scaled_dimension % 2))
    ((scaled_dimension > 0)) || return 1
    printf '%s\n' "$scaled_dimension"
}

greatest_common_divisor() {
    local left="$1"
    local right="$2"
    local remainder

    [[ "$left" =~ ^[1-9][0-9]*$ && "$right" =~ ^[1-9][0-9]*$ ]] || return 1
    while ((right > 0)); do
        remainder=$((left % right))
        left="$right"
        right="$remainder"
    done
    printf '%s\n' "$left"
}

hidpi_payload() {
    local framebuffer_width="$1"
    local framebuffer_height="$2"

    printf '%08x%08x0000000100200000' "$framebuffer_width" "$framebuffer_height" |
        /usr/bin/xxd -r -p |
        /usr/bin/base64 |
        /usr/bin/tr -d '\n'
}

SCRIPT_DIR="$(builtin cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd)" || fail "could not resolve script directory"
readonly SCRIPT_DIR

require_complete_local_checkout() {
    local required_path

    [[ -d "${SCRIPT_DIR}/lib" && ! -L "${SCRIPT_DIR}/lib" ]] ||
        fail "Intel HiDPI requires a complete local checkout"

    for required_path in \
        "${SCRIPT_DIR}/lib/intel_hidpi_storage.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_storage_support.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_mode_configuration.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_darwin_fs.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_plist_arrays.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_manifest.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_similar_resolutions.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_verify_override.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_verify_modes.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_runtime_modes.swift"; do
        [[ -f "$required_path" && ! -L "$required_path" && -r "$required_path" ]] ||
            fail "Intel HiDPI requires a complete local checkout"
    done
}

require_complete_local_checkout
# shellcheck source=lib/intel_hidpi_storage.sh
source "${SCRIPT_DIR}/lib/intel_hidpi_storage.sh" || fail "could not load Intel HiDPI storage helpers"
# shellcheck source=lib/intel_hidpi_verify_modes.sh
source "${SCRIPT_DIR}/lib/intel_hidpi_verify_modes.sh" || fail "could not load Intel HiDPI runtime verification helpers"
# shellcheck source=lib/intel_hidpi_verify_override.sh
source "${SCRIPT_DIR}/lib/intel_hidpi_verify_override.sh" || fail "could not load Intel HiDPI override verification helpers"

print_hidpi_preview_mode() {
    local name="$1"
    local logical_width="$2"
    local logical_height="$3"
    local framebuffer_limit="$4"
    local framebuffer_width
    local framebuffer_height
    local payload

    [[ "$logical_width" =~ ^[1-9][0-9]*$ && "$logical_height" =~ ^[1-9][0-9]*$ ]] || return 1
    framebuffer_width=$((logical_width * 2))
    framebuffer_height=$((logical_height * 2))

    if ((framebuffer_width > framebuffer_limit || framebuffer_height > framebuffer_limit)); then
        fail "${name} mode framebuffer ${framebuffer_width}x${framebuffer_height} exceeds ${framebuffer_limit}x${framebuffer_limit}"
    fi

    payload="$(hidpi_payload "$framebuffer_width" "$framebuffer_height")" || return 1
    printf '%s: %sx%s framebuffer=%sx%s payload=%s\n' \
        "$name" "$logical_width" "$logical_height" "$framebuffer_width" "$framebuffer_height" "$payload"
}

# shellcheck source=lib/intel_hidpi_similar_resolutions.sh
source "${SCRIPT_DIR}/lib/intel_hidpi_similar_resolutions.sh" || fail "could not load Intel HiDPI similar-resolution helpers"

print_preview_mode() {
    local name="$1"
    local native_width="$2"
    local native_height="$3"
    local numerator="$4"
    local denominator="$5"
    local framebuffer_limit="$6"
    local logical_width
    local logical_height

    logical_width="$(scale_dimension_to_even "$native_width" "$numerator" "$denominator")" || return 1
    logical_height="$(scale_dimension_to_even "$native_height" "$numerator" "$denominator")" || return 1
    print_hidpi_preview_mode "$name" "$logical_width" "$logical_height" "$framebuffer_limit"
}

generate_preset_preview_modes() {
    local native_width="$1"
    local native_height="$2"
    local framebuffer_limit="$3"
    local index
    local previous_mode=""
    local output
    local logical_resolution
    local output_lines=()

    for ((index = 0; index < ${#PRESET_NAMES[@]}; index++)); do
        output="$(print_preview_mode \
            "${PRESET_NAMES[$index]}" \
            "$native_width" \
            "$native_height" \
            "${PRESET_NUMERATORS[$index]}" \
            "${PRESET_DENOMINATORS[$index]}" \
            "$framebuffer_limit")" || return 1
        logical_resolution="${output#*: }"
        logical_resolution="${logical_resolution%% framebuffer=*}"

        if [[ "$logical_resolution" == "$previous_mode" ]]; then
            continue
        fi
        previous_mode="$logical_resolution"
        output_lines+=("$output")
    done

    printf '%s\n' "${output_lines[@]}"
}

generate_smooth_preview_modes() {
    local native_width="$1"
    local native_height="$2"
    local framebuffer_limit="$3"
    local include_near_native="$4"
    local sample
    local mode_name
    local output_index
    local smooth_divisor
    local smooth_width_step
    local smooth_height_step
    local smooth_first_sample
    local smooth_available_count
    local smooth_mode_count
    local smooth_sample_offset

    if [[ "$include_near_native" == true ]]; then
        ((native_height > 1)) || fail "near-native mode requires a native height greater than one"
    fi
    smooth_divisor="$(greatest_common_divisor "$native_width" "$native_height")" || return 1
    smooth_width_step=$((native_width / smooth_divisor))
    smooth_height_step=$((native_height / smooth_divisor))
    smooth_first_sample=$(((smooth_divisor * SMOOTH_LOWER_NUMERATOR + SMOOTH_LOWER_DENOMINATOR - 1) / SMOOTH_LOWER_DENOMINATOR))
    smooth_available_count=$((smooth_divisor - smooth_first_sample + 1))
    ((smooth_available_count >= 2)) ||
        fail "native resolution has fewer than two integer exact-aspect-ratio candidates from 2/3 through native; use --mode-set preset"
    if ((smooth_available_count > SMOOTH_MAX_MODE_COUNT)); then
        smooth_mode_count="$SMOOTH_MAX_MODE_COUNT"
    else
        smooth_mode_count="$smooth_available_count"
    fi
    for ((output_index = 0; output_index < smooth_mode_count; output_index++)); do
        smooth_sample_offset=$((output_index * (smooth_available_count - 1) / (smooth_mode_count - 1)))
        sample=$((smooth_first_sample + smooth_sample_offset))
        if ((output_index == smooth_mode_count - 1)); then
            mode_name="native"
        else
            printf -v mode_name 'smooth-%02d' "$((output_index + 1))"
        fi
        print_hidpi_preview_mode \
            "$mode_name" \
            "$((smooth_width_step * sample))" \
            "$((smooth_height_step * sample))" \
            "$framebuffer_limit" || return 1
    done
    if [[ "$include_near_native" == true ]]; then
        print_hidpi_preview_mode near-native "$native_width" "$((native_height - 1))" "$framebuffer_limit"
    fi
}

preview() {
    local native_resolution="$1"
    local framebuffer_limit="$2"
    local mode_set="${3:-$MODE_SET_PRESET}"
    local include_near_native="${4:-false}"
    local include_similar_resolutions="${5:-false}"
    local parsed_resolution
    local native_width
    local native_height
    local preview_output

    decimal_at_most "$framebuffer_limit" "$DEFAULT_FRAMEBUFFER_LIMIT" || fail "framebuffer limit must be a positive integer no greater than ${DEFAULT_FRAMEBUFFER_LIMIT}"
    parsed_resolution="$(parse_resolution "$native_resolution")" || fail "native resolution must use positive WIDTHxHEIGHT values"
    validate_mode_configuration "$mode_set" "$include_near_native" "$include_similar_resolutions" || fail "mode set or compatibility configuration is invalid"
    native_width="${parsed_resolution%%:*}"
    native_height="${parsed_resolution##*:}"

    case "$mode_set" in
    "$MODE_SET_PRESET")
        preview_output="$(generate_preset_preview_modes "$native_width" "$native_height" "$framebuffer_limit")" || return 1
        ;;
    "$MODE_SET_SMOOTH")
        preview_output="$(generate_smooth_preview_modes "$native_width" "$native_height" "$framebuffer_limit" "$include_near_native")" || return 1
        ;;
    esac

    if [[ "$include_similar_resolutions" == true ]]; then
        preview_output="$(append_similar_resolution_preview_modes "$preview_output")" || return 1
    fi

    printf '%s\n' "$preview_output"
}

display_name_from_edid() {
    local edid="$1"
    local descriptor_start
    local descriptor
    local name_hex
    local name
    local index

    for ((index = 0; index < 4; index++)); do
        descriptor_start=$((108 + (index * 36)))
        descriptor="${edid:descriptor_start:36}"
        [[ ${#descriptor} -eq 36 ]] || break
        [[ "${descriptor:0:10}" == "000000fc00" ]] || continue

        name_hex="${descriptor:10:26}"
        name="$(printf '%s' "$name_hex" | /usr/bin/xxd -r -p 2>/dev/null | LC_ALL=C /usr/bin/tr -cd '[:print:]' | /usr/bin/sed 's/[[:space:]]*$//')"
        if [[ -n "$name" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done

    printf '%s\n' "Unknown"
}

preferred_resolution_from_edid() {
    local edid="$1"
    local descriptor_start
    local descriptor
    local pixel_clock
    local width_low
    local width_high
    local height_low
    local height_high
    local width
    local height
    local index

    for ((index = 0; index < 4; index++)); do
        descriptor_start=$((108 + (index * 36)))
        descriptor="${edid:descriptor_start:36}"
        [[ ${#descriptor} -eq 36 ]] || break

        pixel_clock="${descriptor:0:4}"
        [[ "$pixel_clock" != "0000" ]] || continue

        width_low="${descriptor:4:2}"
        width_high="${descriptor:8:1}"
        height_low="${descriptor:10:2}"
        height_high="${descriptor:14:1}"

        width=$((16#$width_low + (16#$width_high * 256)))
        height=$((16#$height_low + (16#$height_high * 256)))

        if ((width > 0 && height > 0)); then
            printf '%sx%s\n' "$width" "$height"
            return 0
        fi
    done

    return 1
}

native_resolution_from_edid() {
    local edid="$1"
    local normalized_edid

    normalized_edid="$(normalize_edid "$edid")" || return 1
    preferred_resolution_from_edid "$normalized_edid"
}

scale_payloads_from_override() {
    local override_path="$1"

    /usr/bin/plutil -extract scale-resolutions xml1 -o - "$override_path" 2>/dev/null |
        /usr/bin/perl -0ne '
            while (m{<data>(.*?)</data>}sg) {
                $value = $1;
                $value =~ s/\s+//g;
                print "$value\n" if length $value;
            }
        '
}

payload_dimensions() {
    local payload="$1"
    local payload_hex
    local width_hex
    local height_hex
    local width
    local height

    payload_hex="$(printf '%s' "$payload" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/xxd -p -c 100)" || return 1
    [[ "$payload_hex" =~ ^[0-9A-Fa-f]{16,}$ ]] || return 1

    width_hex="${payload_hex:0:8}"
    height_hex="${payload_hex:8:8}"
    width="$(decimal_from_hex "$width_hex")" || return 1
    height="$(decimal_from_hex "$height_hex")" || return 1

    printf '%sx%s:%s\n' "$width" "$height" "$(( ${#payload_hex} / 2 ))"
}

print_override_modes() {
    local override_path="$1"
    local payload
    local dimensions
    local resolution
    local payload_bytes
    local count=0

    while IFS= read -r payload; do
        [[ -n "$payload" ]] || continue

        dimensions="$(payload_dimensions "$payload")" || {
            printf '    invalid payload\n'
            continue
        }
        resolution="${dimensions%%:*}"
        payload_bytes="${dimensions##*:}"
        printf '    %s (%s-byte payload)\n' "$resolution" "$payload_bytes"
        count=$((count + 1))
    done < <(scale_payloads_from_override "$override_path")

    if ((count == 0)); then
        printf '  scale-resolutions=none\n'
    fi
}

print_inventory_entry() {
    local display_index="$1"
    local edid="$2"
    local overrides_root="$3"
    local vendor_hex
    local product_hex
    local vendor_decimal
    local product_decimal
    local display_name
    local native_resolution
    local override_relative
    local override_path

    vendor_hex="$(normalize_hex_id "${edid:16:4}")" || return 1
    product_hex="$(normalize_hex_id "${edid:22:2}${edid:20:2}")" || return 1
    vendor_decimal="$(decimal_from_hex "$vendor_hex")" || return 1
    product_decimal="$(decimal_from_hex "$product_hex")" || return 1
    display_name="$(display_name_from_edid "$edid")"
    native_resolution="$(preferred_resolution_from_edid "$edid")" || native_resolution="unavailable"
    override_relative="DisplayVendorID-${vendor_hex}/DisplayProductID-${product_hex}"
    override_path="${overrides_root}/${override_relative}"

    printf 'display[%d]\n' "$display_index"
    printf '  name=%s\n' "$display_name"
    printf '  vendor-id=0x%s (%s)\n' "$vendor_hex" "$vendor_decimal"
    printf '  product-id=0x%s (%s)\n' "$product_hex" "$product_decimal"
    printf '  native-resolution=%s\n' "$native_resolution"

    if [[ -f "$override_path" ]] && /usr/bin/plutil -lint "$override_path" >/dev/null 2>&1; then
        printf '  override=%s (present)\n' "$override_relative"
        print_override_modes "$override_path"
    elif [[ -f "$override_path" ]]; then
        printf '  override=%s (invalid)\n' "$override_relative"
        printf '  scale-resolutions=unavailable\n'
    else
        printf '  override=%s (absent)\n' "$override_relative"
        printf '  scale-resolutions=none\n'
    fi
}

inventory() {
    local ioreg_file="$1"
    local overrides_root="$2"
    local edid_source
    local edid
    local normalized_edid
    local display_index=0
    local seen_edids=""

    if [[ -n "$ioreg_file" ]]; then
        [[ -f "$ioreg_file" ]] || fail "ioreg fixture does not exist: ${ioreg_file}"
        edid_source="$(/bin/cat "$ioreg_file")"
    else
        edid_source="$(/usr/sbin/ioreg -lw0)" || fail "unable to read IODisplayEDID from ioreg"
    fi

    while IFS= read -r edid; do
        normalized_edid="$(normalize_edid "$edid")" || continue

        case ":${seen_edids}:" in
        *":${normalized_edid}:"*)
            continue
            ;;
        esac
        seen_edids="${seen_edids}:${normalized_edid}"
        display_index=$((display_index + 1))
        print_inventory_entry "$display_index" "$normalized_edid" "$overrides_root" || fail "could not parse display ${display_index}"
    done < <(printf '%s\n' "$edid_source" | /usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p')

    ((display_index > 0)) || fail "no valid IODisplayEDID entries found"
}

run_inventory_command() {
    local ioreg_file=""
    local overrides_root="$DEFAULT_OVERRIDES_ROOT"

    while (($# > 0)); do
        case "$1" in
        --ioreg-file)
            (($# >= 2)) || fail "--ioreg-file requires a path"
            ioreg_file="$2"
            shift 2
            ;;
        --overrides-root)
            (($# >= 2)) || fail "--overrides-root requires a path"
            overrides_root="$2"
            shift 2
            ;;
        *)
            fail "unknown inventory option: $1"
            ;;
        esac
    done

    inventory "$ioreg_file" "$overrides_root"
}

run_preview_command() {
    local native_resolution=""
    local framebuffer_limit="$DEFAULT_FRAMEBUFFER_LIMIT"
    local mode_set="$MODE_SET_PRESET"
    local include_near_native=false
    local include_similar_resolutions=false
    local mode_set_provided=false
    local near_native_provided=false
    local similar_resolutions_provided=false

    while (($# > 0)); do
        case "$1" in
        --native-resolution)
            (($# >= 2)) || fail "--native-resolution requires WIDTHxHEIGHT"
            native_resolution="$2"
            shift 2
            ;;
        --framebuffer-limit)
            (($# >= 2)) || fail "--framebuffer-limit requires a positive integer"
            framebuffer_limit="$2"
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
            fail "unknown preview option: $1"
            ;;
        esac
    done

    [[ -n "$native_resolution" ]] || fail "--native-resolution is required"
    preview "$native_resolution" "$framebuffer_limit" "$mode_set" "$include_near_native" "$include_similar_resolutions"
}

run_native_resolution_command() {
    local edid=""

    while (($# > 0)); do
        case "$1" in
        --edid)
            (($# >= 2)) || fail "--edid requires a hexadecimal value"
            edid="$2"
            shift 2
            ;;
        *)
            fail "unknown native-resolution option: $1"
            ;;
        esac
    done

    [[ -n "$edid" ]] || fail "--edid is required"
    native_resolution_from_edid "$edid" || fail "could not read a preferred resolution from EDID"
}

run_apply_command() {
    local vendor_id=""
    local product_id=""
    local native_resolution=""
    local overrides_root="$DEFAULT_OVERRIDES_ROOT"
    local state_root="$DEFAULT_STATE_ROOT"
    local confirmed=false
    local mode_set="$MODE_SET_PRESET"
    local include_near_native=false
    local include_similar_resolutions=false
    local mode_set_provided=false
    local near_native_provided=false
    local similar_resolutions_provided=false

    while (($# > 0)); do
        case "$1" in
        --vendor-id)
            (($# >= 2)) || fail "--vendor-id requires a hexadecimal value"
            vendor_id="$2"
            shift 2
            ;;
        --product-id)
            (($# >= 2)) || fail "--product-id requires a hexadecimal value"
            product_id="$2"
            shift 2
            ;;
        --native-resolution)
            (($# >= 2)) || fail "--native-resolution requires WIDTHxHEIGHT"
            native_resolution="$2"
            shift 2
            ;;
        --overrides-root)
            (($# >= 2)) || fail "--overrides-root requires a path"
            overrides_root="$2"
            shift 2
            ;;
        --state-root)
            (($# >= 2)) || fail "--state-root requires a path"
            state_root="$2"
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
        --confirm)
            confirmed=true
            shift
            ;;
        *)
            fail "unknown apply option: $1"
            ;;
        esac
    done

    [[ -n "$vendor_id" && -n "$product_id" && -n "$native_resolution" ]] || fail "apply requires vendor id, product id, and native resolution"
    validate_mode_configuration "$mode_set" "$include_near_native" "$include_similar_resolutions" || fail "mode set or compatibility configuration is invalid"
    apply_override "$vendor_id" "$product_id" "$native_resolution" "$overrides_root" "$state_root" "$confirmed" "$mode_set" "$include_near_native" "$include_similar_resolutions"
}

run_revert_command() {
    local vendor_id=""
    local product_id=""
    local overrides_root="$DEFAULT_OVERRIDES_ROOT"
    local state_root="$DEFAULT_STATE_ROOT"
    local confirmed=false
    local migrate_v4=false

    while (($# > 0)); do
        case "$1" in
        --vendor-id)
            (($# >= 2)) || fail "--vendor-id requires a hexadecimal value"
            vendor_id="$2"
            shift 2
            ;;
        --product-id)
            (($# >= 2)) || fail "--product-id requires a hexadecimal value"
            product_id="$2"
            shift 2
            ;;
        --overrides-root)
            (($# >= 2)) || fail "--overrides-root requires a path"
            overrides_root="$2"
            shift 2
            ;;
        --state-root)
            (($# >= 2)) || fail "--state-root requires a path"
            state_root="$2"
            shift 2
            ;;
        --confirm)
            confirmed=true
            shift
            ;;
        --migrate-v4)
            migrate_v4=true
            shift
            ;;
        *)
            fail "unknown revert option: $1"
            ;;
        esac
    done

    [[ -n "$vendor_id" && -n "$product_id" ]] || fail "revert requires vendor id and product id"
    revert_override "$vendor_id" "$product_id" "$overrides_root" "$state_root" "$confirmed" "$migrate_v4"
}

main() {
    local command="${1:-}"

    case "$command" in
    inventory)
        shift
        run_inventory_command "$@"
        ;;
    preview)
        shift
        run_preview_command "$@"
        ;;
    verify-modes)
        shift
        run_verify_modes_command "$@"
        ;;
    verify-override)
        shift
        run_verify_override_command "$@"
        ;;
    native-resolution)
        shift
        run_native_resolution_command "$@"
        ;;
    apply)
        shift
        run_apply_command "$@"
        ;;
    revert)
        shift
        run_revert_command "$@"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        usage >&2
        return 2
        ;;
    esac
}

main "$@"
