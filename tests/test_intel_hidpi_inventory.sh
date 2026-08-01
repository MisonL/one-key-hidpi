#!/bin/bash

set -u

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="${repo_dir}/tests/fixtures"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local expected="$2"

    if ! printf '%s\n' "$haystack" | /usr/bin/grep -Fqx "$expected"; then
        fail "missing expected line: ${expected}"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local unexpected="$2"

    if printf '%s\n' "$haystack" | /usr/bin/grep -Fq "$unexpected"; then
        fail "unexpected text: ${unexpected}"
    fi
}

with_recalculated_base_checksum() {
    local edid="$1"
    local base_without_checksum="${edid:0:254}"
    local checksum=0
    local index
    local byte_hex

    for ((index = 0; index < ${#base_without_checksum}; index += 2)); do
        byte_hex="${base_without_checksum:index:2}"
        checksum=$((checksum + 16#$byte_hex))
    done

    printf '%s%02x\n' "$base_without_checksum" "$(((256 - checksum % 256) % 256))"
}

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-inventory.XXXXXX")" || fail "could not create scratch directory"

cleanup() {
    /bin/rm -rf "$scratch_dir"
}

trap cleanup EXIT

output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/ioreg-displays.txt" \
    --overrides-root "${fixture_dir}/overrides")" || fail "inventory command should succeed"

first_edid="$(/usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p' "${fixture_dir}/ioreg-displays.txt" | /usr/bin/sed -n '1p')"
native_resolution="$("${repo_dir}/intel-hidpi.sh" native-resolution --edid "$first_edid")" || fail "native-resolution command should succeed"
[[ "$native_resolution" == "1920x1080" ]] || fail "expected 1920x1080 native resolution, got ${native_resolution}"

assert_contains "$output" "display[1]"
assert_contains "$output" "  name=Test-1080p"
assert_contains "$output" "  vendor-id=0x30ae (12462)"
assert_contains "$output" "  product-id=0x62a5 (25253)"
assert_contains "$output" "  native-resolution=1920x1080"
assert_contains "$output" "  override=DisplayVendorID-30ae/DisplayProductID-62a5 (present)"
assert_contains "$output" "    3712x2088 (16-byte payload)"
assert_contains "$output" "    3328x1872 (8-byte payload)"
assert_contains "$output" "display[2]"
assert_contains "$output" "  name=Test-4K"
assert_contains "$output" "  vendor-id=0x4c2d (19501)"
assert_contains "$output" "  product-id=0x7668 (30312)"
assert_contains "$output" "  native-resolution=3840x2160"
assert_contains "$output" "  override=DisplayVendorID-4c2d/DisplayProductID-7668 (absent)"
assert_contains "$output" "  scale-resolutions=none"

if "${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/empty-ioreg.txt" \
    --overrides-root "${fixture_dir}/overrides" >/dev/null 2>&1; then
    fail "missing input fixture should fail explicitly"
fi

if "${repo_dir}/intel-hidpi.sh" native-resolution --edid invalid >/dev/null 2>&1; then
    fail "invalid EDID must fail explicitly"
fi

invalid_header_edid="01${first_edid:2}"
if "${repo_dir}/intel-hidpi.sh" native-resolution --edid "$invalid_header_edid" >/dev/null 2>&1; then
    fail "EDID without the standard header must fail explicitly"
fi

odd_length_edid="${first_edid%?}"
if "${repo_dir}/intel-hidpi.sh" native-resolution --edid "$odd_length_edid" >/dev/null 2>&1; then
    fail "odd-length EDID must fail explicitly"
fi

truncated_edid="${first_edid:0:144}"
if "${repo_dir}/intel-hidpi.sh" native-resolution --edid "$truncated_edid" >/dev/null 2>&1; then
    fail "EDID shorter than one base block must fail explicitly"
fi

checksum_invalid_edid="${first_edid:0:254}00"
if "${repo_dir}/intel-hidpi.sh" native-resolution --edid "$checksum_invalid_edid" >/dev/null 2>&1; then
    fail "EDID with an invalid base-block checksum must fail explicitly"
fi

invalid_ioreg_file="${scratch_dir}/invalid-edid.txt"
printf '    | | "IODisplayEDID" = <%s>\n' "$invalid_header_edid" > "$invalid_ioreg_file"
if "${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "$invalid_ioreg_file" \
    --overrides-root "${fixture_dir}/overrides" >/dev/null 2>&1; then
    fail "inventory must reject EDID without the standard header"
fi

printf '    | | "IODisplayEDID" = <%s>\n' "$checksum_invalid_edid" > "$invalid_ioreg_file"
if "${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "$invalid_ioreg_file" \
    --overrides-root "${fixture_dir}/overrides" >/dev/null 2>&1; then
    fail "inventory must reject EDID with an invalid base-block checksum"
fi

name_marker="000000fc00"
name_prefix="${first_edid%%"${name_marker}"*}"
name_suffix="${first_edid#*"${name_marker}"}"
control_name_edid="${name_prefix}${name_marker}4261641b5b324a0a2020202020${name_suffix:26}"
control_name_edid="$(with_recalculated_base_checksum "$control_name_edid")"
printf '    | | "IODisplayEDID" = <%s>\n' "$control_name_edid" > "$invalid_ioreg_file"
control_name_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "$invalid_ioreg_file" \
    --overrides-root "${fixture_dir}/overrides")" || fail "inventory with a control-character name should succeed"
assert_contains "$control_name_output" "  name=Bad[2J"
assert_not_contains "$control_name_output" $'\033'

leading_zero_edid="${first_edid:0:16}00011000${first_edid:24}"
leading_zero_edid="$(with_recalculated_base_checksum "$leading_zero_edid")"
leading_zero_ioreg_file="${scratch_dir}/leading-zero-ioreg.txt"
leading_zero_overrides_root="${scratch_dir}/leading-zero-overrides"
/bin/mkdir -p "${leading_zero_overrides_root}/DisplayVendorID-1"
/bin/cp "${fixture_dir}/overrides/DisplayVendorID-30ae/DisplayProductID-62a5" \
    "${leading_zero_overrides_root}/DisplayVendorID-1/DisplayProductID-10"
printf '    | | "IODisplayEDID" = <%s>\n' "$leading_zero_edid" > "$leading_zero_ioreg_file"
leading_zero_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "$leading_zero_ioreg_file" \
    --overrides-root "$leading_zero_overrides_root")" || fail "inventory with leading-zero IDs should succeed"
assert_contains "$leading_zero_output" "  vendor-id=0x1 (1)"
assert_contains "$leading_zero_output" "  product-id=0x10 (16)"
assert_contains "$leading_zero_output" "  override=DisplayVendorID-1/DisplayProductID-10 (present)"

invalid_override_root="${scratch_dir}/invalid-overrides"
/bin/mkdir -p "${invalid_override_root}/DisplayVendorID-30ae"
printf 'not a plist\n' > "${invalid_override_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
invalid_override_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/ioreg-displays.txt" \
    --overrides-root "$invalid_override_root")" || fail "inventory with an invalid override should succeed"
assert_contains "$invalid_override_output" "  override=DisplayVendorID-30ae/DisplayProductID-62a5 (invalid)"
assert_contains "$invalid_override_output" "  scale-resolutions=unavailable"

missing_scale_override_root="${scratch_dir}/missing-scale-overrides"
missing_scale_override_path="${missing_scale_override_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
/bin/mkdir -p "$(/usr/bin/dirname "$missing_scale_override_path")" || fail "could not create missing-scale override fixture"
/usr/bin/plutil -create xml1 "$missing_scale_override_path" || fail "could not initialize missing-scale override fixture"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$missing_scale_override_path" || fail "could not write missing-scale vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$missing_scale_override_path" || fail "could not write missing-scale product id"
missing_scale_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/ioreg-displays.txt" \
    --overrides-root "$missing_scale_override_root")" || fail "valid override without scale-resolutions should be reported"
assert_contains "$missing_scale_output" "  override=DisplayVendorID-30ae/DisplayProductID-62a5 (present)"
assert_contains "$missing_scale_output" "  scale-resolutions=none"

wrong_scale_override_root="${scratch_dir}/wrong-scale-overrides"
wrong_scale_override_path="${wrong_scale_override_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
/bin/mkdir -p "$(/usr/bin/dirname "$wrong_scale_override_path")" || fail "could not create wrong-scale override fixture"
/usr/bin/plutil -create xml1 "$wrong_scale_override_path" || fail "could not initialize wrong-scale override fixture"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$wrong_scale_override_path" || fail "could not write wrong-scale vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$wrong_scale_override_path" || fail "could not write wrong-scale product id"
/usr/bin/plutil -insert scale-resolutions -string wrong-type "$wrong_scale_override_path" || fail "could not write wrong-scale fixture"
wrong_scale_output=""
if wrong_scale_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/ioreg-displays.txt" \
    --overrides-root "$wrong_scale_override_root" 2>&1)"; then
    fail "override with a non-array scale-resolutions value must fail explicitly"
fi
assert_contains "$wrong_scale_output" "error: could not parse display 1"

long_override_root="${scratch_dir}/long-overrides"
long_override_vendor_root="${long_override_root}/DisplayVendorID-30ae"
long_override_path="${long_override_vendor_root}/DisplayProductID-62a5"
long_payload_binary="${scratch_dir}/long-payload.bin"
long_payload=""
/bin/mkdir -p "$long_override_vendor_root"
/usr/bin/plutil -create xml1 "$long_override_path" || fail "could not initialize long-payload override"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$long_override_path" || fail "could not write long-payload vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$long_override_path" || fail "could not write long-payload product id"
/usr/bin/plutil -insert scale-resolutions -array "$long_override_path" || fail "could not initialize long-payload mode array"
printf '0000078000000438' | /usr/bin/xxd -r -p > "$long_payload_binary" || fail "could not create long-payload header"
/usr/bin/head -c 96 /dev/zero >> "$long_payload_binary" || fail "could not create long-payload body"
long_payload="$(/usr/bin/base64 < "$long_payload_binary" | /usr/bin/tr -d '\n')" || fail "could not encode long payload"
/usr/bin/plutil -insert scale-resolutions.0 -data "$long_payload" "$long_override_path" || fail "could not write long payload"
long_override_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/ioreg-displays.txt" \
    --overrides-root "$long_override_root")" || fail "inventory with a long payload should succeed"
assert_contains "$long_override_output" "    1920x1080 (104-byte payload)"

ioreg_link_target="${scratch_dir}/ioreg-link-target.txt"
ioreg_link="${scratch_dir}/ioreg-link.txt"
/bin/cp "${fixture_dir}/ioreg-displays.txt" "$ioreg_link_target" || fail "could not create ioreg link target"
/bin/ln -s "$ioreg_link_target" "$ioreg_link" || fail "could not create ioreg link"
ioreg_link_output=""
if ioreg_link_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "$ioreg_link" \
    --overrides-root "${fixture_dir}/overrides" 2>&1)"; then
    fail "inventory must reject a symbolic-link ioreg fixture"
fi
assert_contains "$ioreg_link_output" "error: ioreg fixture path is invalid or traverses a symbolic link"

linked_overrides_root="${scratch_dir}/linked-overrides"
/bin/ln -s "${fixture_dir}/overrides" "$linked_overrides_root" || fail "could not create overrides root link"
linked_root_output=""
if linked_root_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/ioreg-displays.txt" \
    --overrides-root "$linked_overrides_root" 2>&1)"; then
    fail "inventory must reject a symbolic-link overrides root"
fi
assert_contains "$linked_root_output" "error: overrides root is invalid or traverses a symbolic link"

target_symlink_root="${scratch_dir}/target-symlink-overrides"
target_symlink_vendor_root="${target_symlink_root}/DisplayVendorID-30ae"
target_symlink_outside="${scratch_dir}/target-symlink-outside.plist"
target_symlink_path="${target_symlink_vendor_root}/DisplayProductID-62a5"
/bin/mkdir -p "$target_symlink_vendor_root" || fail "could not create target symlink root"
printf 'outside target\n' > "$target_symlink_outside" || fail "could not create target symlink outside file"
/bin/ln -s "$target_symlink_outside" "$target_symlink_path" || fail "could not create target override symlink"
target_symlink_output=""
if target_symlink_output="$("${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "${fixture_dir}/ioreg-displays.txt" \
    --overrides-root "$target_symlink_root" 2>&1)"; then
    fail "inventory must reject a symbolic-link override target"
fi
assert_contains "$target_symlink_output" "error: override target must be a regular non-symbolic-link file"
[[ "$(/bin/cat "$target_symlink_outside")" == "outside target" ]] || fail "symbolic-link target outside file must remain unchanged"

printf 'PASS: Intel HiDPI inventory\n'
