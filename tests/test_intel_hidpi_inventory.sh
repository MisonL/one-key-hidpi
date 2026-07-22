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

printf 'PASS: Intel HiDPI inventory\n'
