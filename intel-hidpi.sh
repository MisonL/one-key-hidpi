#!/bin/bash

set -u
set -o pipefail

readonly DEFAULT_OVERRIDES_ROOT="/Library/Displays/Contents/Resources/Overrides"

usage() {
    cat <<'EOF'
Usage:
  intel-hidpi.sh inventory [--ioreg-file PATH] [--overrides-root PATH]

Commands:
  inventory  Read connected Intel-compatible external display metadata and
             existing EDID override modes. This command never writes files.
EOF
}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

decimal_from_hex() {
    local value="$1"

    [[ "$value" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    printf '%d\n' "$((16#$value))"
}

display_name_from_edid() {
    local edid="$1"
    local name_hex
    local name

    case "$edid" in
    *000000fc00*)
        name_hex="${edid#*000000fc00}"
        name_hex="${name_hex:0:26}"
        name="$(printf '%s' "$name_hex" | /usr/bin/xxd -r -p 2>/dev/null | /usr/bin/tr -d '\r\n' | /usr/bin/sed 's/[[:space:]]*$//')"
        if [[ -n "$name" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
        ;;
    esac

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

    vendor_hex="$(printf '%s' "${edid:16:4}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    product_hex="$(printf '%s%s' "${edid:22:2}" "${edid:20:2}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
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

    if [[ -f "$override_path" ]]; then
        printf '  override=%s (present)\n' "$override_relative"
        print_override_modes "$override_path"
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
        edid_source="$(ioreg -lw0)" || fail "unable to read IODisplayEDID from ioreg"
    fi

    while IFS= read -r edid; do
        normalized_edid="$(printf '%s' "$edid" | /usr/bin/tr '[:upper:]' '[:lower:]')"
        [[ "$normalized_edid" =~ ^[0-9a-f]+$ ]] || continue
        (( ${#normalized_edid} >= 128 )) || continue

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

main() {
    local command="${1:-}"
    local ioreg_file=""
    local overrides_root="$DEFAULT_OVERRIDES_ROOT"

    case "$command" in
    inventory)
        shift
        ;;
    -h|--help|help|"")
        usage
        return 0
        ;;
    *)
        usage >&2
        return 2
        ;;
    esac

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

main "$@"
