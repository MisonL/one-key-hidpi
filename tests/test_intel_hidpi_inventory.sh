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

invalid_ioreg_file="$(mktemp "${TMPDIR:-/tmp}/one-key-hidpi-invalid-edid.XXXXXX")"
trap '/bin/rm -f "$invalid_ioreg_file"' EXIT
printf '    | | "IODisplayEDID" = <%s>\n' "$invalid_header_edid" > "$invalid_ioreg_file"
if "${repo_dir}/intel-hidpi.sh" inventory \
    --ioreg-file "$invalid_ioreg_file" \
    --overrides-root "${fixture_dir}/overrides" >/dev/null 2>&1; then
    fail "inventory must reject EDID without the standard header"
fi

printf 'PASS: Intel HiDPI inventory\n'
