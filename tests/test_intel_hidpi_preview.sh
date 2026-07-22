#!/bin/bash

set -u

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

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

assert_starts_with() {
    local haystack="$1"
    local expected_prefix="$2"

    if ! printf '%s\n' "$haystack" | /usr/bin/grep -Fq "${expected_prefix}"; then
        fail "missing expected prefix: ${expected_prefix}"
    fi
}

assert_line_count() {
    local haystack="$1"
    local expected_count="$2"
    local actual_count

    actual_count="$(printf '%s\n' "$haystack" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$actual_count" == "$expected_count" ]] || fail "expected ${expected_count} modes, got ${actual_count}"
}

preview="$("${repo_dir}/intel-hidpi.sh" preview --native-resolution 3840x2160)" || fail "4K preview should succeed"
assert_line_count "$preview" 5
assert_contains "$preview" "compact: 1920x1080 framebuffer=3840x2160 payload=AAAPAAAACHAAAAABACAAAA=="
assert_contains "$preview" "balanced: 2304x1296 framebuffer=4608x2592 payload=AAASAAAACiAAAAABACAAAA=="
assert_contains "$preview" "spacious: 2560x1440 framebuffer=5120x2880 payload=AAAUAAAAC0AAAAABACAAAA=="
assert_contains "$preview" "dense: 2880x1620 framebuffer=5760x3240 payload=AAAWgAAADKgAAAABACAAAA=="
assert_contains "$preview" "native: 3840x2160 framebuffer=7680x4320 payload=AAAeAAAAEOAAAAABACAAAA=="

legacy_payload="$(printf '%08x %08x' 3840 2160 | /usr/bin/xxd -r -p | /usr/bin/base64 | /usr/bin/tr -d '\n')"
legacy_payload="${legacy_payload:0:11}AAAABACAAAA=="
[[ "$legacy_payload" == "AAAPAAAACHAAAAABACAAAA==" ]] || fail "new payload must match the legacy 16-byte HiDPI encoding"

ultrawide_preview="$("${repo_dir}/intel-hidpi.sh" preview --native-resolution 3440x1440)" || fail "ultrawide preview should succeed"
assert_starts_with "$ultrawide_preview" "compact: 1720x720 framebuffer=3440x1440 payload="
assert_starts_with "$ultrawide_preview" "spacious: 2292x960 framebuffer=4584x1920 payload="

tiny_preview="$("${repo_dir}/intel-hidpi.sh" preview --native-resolution 4x4)" || fail "tiny preview should succeed"
assert_line_count "$tiny_preview" 2
assert_starts_with "$tiny_preview" "compact: 2x2 framebuffer=4x4 payload="
assert_starts_with "$tiny_preview" "native: 4x4 framebuffer=8x8 payload="

limited_output=""
if limited_output="$("${repo_dir}/intel-hidpi.sh" preview --native-resolution 3840x2160 --framebuffer-limit 7000 2>/dev/null)"; then
    fail "preview must reject a limit that excludes a generated mode"
fi
[[ -z "$limited_output" ]] || fail "rejected preview must not emit a partial mode list"

if "${repo_dir}/intel-hidpi.sh" preview --native-resolution invalid >/dev/null 2>&1; then
    fail "invalid native resolution must fail explicitly"
fi

if "${repo_dir}/intel-hidpi.sh" preview --native-resolution 1x1080 >/dev/null 2>&1; then
    fail "odd or non-positive generated dimensions must fail explicitly"
fi

printf 'PASS: Intel HiDPI preview\n'
