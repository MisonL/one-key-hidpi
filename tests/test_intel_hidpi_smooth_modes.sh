#!/bin/bash

set -u

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
betterdisplay_payload_fixture="${repo_dir}/tests/fixtures/betterdisplay-1920x1080-payloads.txt"

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

assert_document_contains() {
    local document_path="$1"
    local expected="$2"

    /usr/bin/grep -Fq -- "$expected" "$document_path" || fail "missing documentation text in ${document_path}: ${expected}"
}

assert_not_contains() {
    local haystack="$1"
    local unexpected="$2"

    if printf '%s\n' "$haystack" | /usr/bin/grep -Fqx "$unexpected"; then
        fail "unexpected line: ${unexpected}"
    fi
}

assert_line_count() {
    local haystack="$1"
    local expected_count="$2"
    local actual_count

    actual_count="$(printf '%s\n' "$haystack" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$actual_count" == "$expected_count" ]] || fail "expected ${expected_count} modes, got ${actual_count}"
}

assert_exact_aspect_ratio() {
    local preview="$1"
    local native_width="$2"
    local native_height="$3"
    local line
    local logical_width
    local logical_height

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[a-z0-9-]+:\ ([1-9][0-9]*)x([1-9][0-9]*)\ framebuffer= ]] || fail "could not parse smooth mode: ${line}"
        logical_width="${BASH_REMATCH[1]}"
        logical_height="${BASH_REMATCH[2]}"
        ((logical_width * native_height == logical_height * native_width)) || fail "smooth mode does not preserve the native aspect ratio: ${line}"
    done <<< "$preview"
}

assert_unique_logical_resolutions() {
    local preview="$1"
    local mode_count
    local unique_count

    mode_count="$(printf '%s\n' "$preview" | /usr/bin/sed -n 's/^[^:]*: \([1-9][0-9]*x[1-9][0-9]*\) framebuffer=.*/\1/p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    unique_count="$(printf '%s\n' "$preview" | /usr/bin/sed -n 's/^[^:]*: \([1-9][0-9]*x[1-9][0-9]*\) framebuffer=.*/\1/p' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$mode_count" == "$unique_count" ]] || fail "smooth mode generation must not duplicate logical resolutions"
}

assert_unique_payloads() {
    local preview="$1"
    local expected_count="$2"
    local payload_count
    local unique_count

    payload_count="$(printf '%s\n' "$preview" | /usr/bin/sed -n 's/.* payload=\([A-Za-z0-9+\/]*=*\)$/\1/p' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    unique_count="$(printf '%s\n' "$preview" | /usr/bin/sed -n 's/.* payload=\([A-Za-z0-9+\/]*=*\)$/\1/p' | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$payload_count" == "$expected_count" ]] || fail "expected ${expected_count} payloads, got ${payload_count}"
    [[ "$payload_count" == "$unique_count" ]] || fail "generated payloads must be unique"
}

assert_payload_set_sha256() {
    local preview="$1"
    local expected_hash="$2"
    local actual_hash

    actual_hash="$(printf '%s\n' "$preview" | /usr/bin/sed -n 's/.* payload=\([A-Za-z0-9+\/]*=*\)$/\1/p' | /usr/bin/sort -u | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || fail "unexpected normalized payload set SHA-256: ${actual_hash}"
}

assert_payload_set_matches_fixture() {
    local preview="$1"
    local actual_payloads

    [[ -f "$betterdisplay_payload_fixture" && ! -L "$betterdisplay_payload_fixture" ]] || fail "missing BetterDisplay payload fixture"
    actual_payloads="$(printf '%s\n' "$preview" | /usr/bin/sed -n 's/.* payload=\([A-Za-z0-9+\/]*=*\)$/\1/p' | /usr/bin/sort -u)"
    /usr/bin/diff -u "$betterdisplay_payload_fixture" <(printf '%s\n' "$actual_payloads") || fail "generated payload set differs from the BetterDisplay fixture"
}

smooth_preview="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth)" || fail "smooth preview should succeed"
assert_line_count "$smooth_preview" 41
assert_contains "$smooth_preview" "smooth-01: 1280x720 framebuffer=2560x1440 payload=AAAKAAAABaAAAAABACAAAA=="
assert_contains "$smooth_preview" "smooth-21: 1600x900 framebuffer=3200x1800 payload=AAAMgAAABwgAAAABACAAAA=="
assert_contains "$smooth_preview" "native: 1920x1080 framebuffer=3840x2160 payload=AAAPAAAACHAAAAABACAAAA=="
assert_not_contains "$smooth_preview" "near-native: 1920x1079 framebuffer=3840x2158 payload=AAAPAAAACG4AAAABACAAAA=="
assert_exact_aspect_ratio "$smooth_preview" 1920 1080
assert_unique_logical_resolutions "$smooth_preview"

near_native_preview="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native)" || fail "smooth preview with near-native mode should succeed"
assert_line_count "$near_native_preview" 42
assert_contains "$near_native_preview" "near-native: 1920x1079 framebuffer=3840x2158 payload=AAAPAAAACG4AAAABACAAAA=="

similar_preview="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions)" || fail "smooth preview with BetterDisplay-compatible similar resolutions should succeed"
assert_line_count "$similar_preview" 126
assert_contains "$similar_preview" "smooth-01: 1280x720 framebuffer=2560x1440 payload=AAAKAAAABaAAAAABACAAAA=="
assert_contains "$similar_preview" "near-native: 1920x1079 framebuffer=3840x2158 payload=AAAPAAAACG4AAAABACAAAA=="
assert_contains "$similar_preview" "similar-logical-smooth-01: 1280x720 framebuffer=1280x720 payload=AAAFAAAAAtA="
assert_contains "$similar_preview" "similar-framebuffer-smooth-01: 2560x1440 framebuffer=2560x1440 payload=AAAKAAAABaA="
assert_contains "$similar_preview" "similar-logical-near-native: 1920x1079 framebuffer=1920x1079 payload=AAAHgAAABDc="
assert_contains "$similar_preview" "similar-framebuffer-near-native: 3840x2158 framebuffer=3840x2158 payload=AAAPAAAACG4="
assert_unique_payloads "$similar_preview" 126
assert_payload_set_sha256 "$similar_preview" "cf26372047fc80933bd980571ada7eaf30d9c7ac9114a3b6fc98e83a3b161c0b"
assert_payload_set_matches_fixture "$similar_preview"
assert_document_contains "${repo_dir}/README.md" "--include-similar-resolutions"
assert_document_contains "${repo_dir}/README-zh.md" "--include-similar-resolutions"

ultrawide_preview="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 3440x1440 \
    --mode-set smooth)" || fail "ultrawide smooth preview should succeed"
assert_line_count "$ultrawide_preview" 27
assert_contains "$ultrawide_preview" "smooth-01: 2322x972 framebuffer=4644x1944 payload=AAASJAAAB5gAAAABACAAAA=="
assert_contains "$ultrawide_preview" "native: 3440x1440 framebuffer=6880x2880 payload=AAAa4AAAC0AAAAABACAAAA=="
assert_exact_aspect_ratio "$ultrawide_preview" 3440 1440
assert_unique_logical_resolutions "$ultrawide_preview"

four_k_preview="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 3840x2160 \
    --mode-set smooth)" || fail "4K smooth preview should succeed"
assert_line_count "$four_k_preview" 41
assert_contains "$four_k_preview" "smooth-01: 2560x1440 framebuffer=5120x2880 payload=AAAUAAAAC0AAAAABACAAAA=="
assert_contains "$four_k_preview" "native: 3840x2160 framebuffer=7680x4320 payload=AAAeAAAAEOAAAAABACAAAA=="
assert_exact_aspect_ratio "$four_k_preview" 3840 2160
assert_unique_logical_resolutions "$four_k_preview"

limited_framebuffer_output=""
if limited_framebuffer_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --framebuffer-limit 3839 2>&1)"; then
    fail "smooth preview must reject a framebuffer limit below the native 2x mode"
fi
assert_contains "$limited_framebuffer_output" "error: native mode framebuffer 3840x2160 exceeds 3839x3839"

low_divisor_output=""
if low_divisor_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1366x768 \
    --mode-set smooth 2>&1)"; then
    fail "smooth preview must reject a panel without at least two exact-aspect-ratio candidates"
fi
assert_contains "$low_divisor_output" "error: native resolution has fewer than two integer exact-aspect-ratio candidates from 2/3 through native; use --mode-set preset"

near_native_boundary_output=""
if near_native_boundary_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1x1 \
    --mode-set smooth \
    --include-near-native 2>&1)"; then
    fail "near-native mode must reject a native height of one"
fi
assert_contains "$near_native_boundary_output" "error: near-native mode requires a native height greater than one"

duplicate_mode_set_output=""
if duplicate_mode_set_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --mode-set smooth 2>&1)"; then
    fail "duplicate mode-set options must fail explicitly"
fi
assert_contains "$duplicate_mode_set_output" "error: --mode-set may only be provided once"

duplicate_near_native_output=""
if duplicate_near_native_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-near-native 2>&1)"; then
    fail "duplicate near-native options must fail explicitly"
fi
assert_contains "$duplicate_near_native_output" "error: --include-near-native may only be provided once"

duplicate_similar_resolutions_output=""
if duplicate_similar_resolutions_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-similar-resolutions \
    --include-similar-resolutions 2>&1)"; then
    fail "duplicate similar-resolution options must fail explicitly"
fi
assert_contains "$duplicate_similar_resolutions_output" "error: --include-similar-resolutions may only be provided once"

invalid_similar_configuration_output=""
if invalid_similar_configuration_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set preset \
    --include-similar-resolutions 2>&1)"; then
    fail "similar resolutions must require the smooth mode set"
fi
assert_contains "$invalid_similar_configuration_output" "error: mode set or compatibility configuration is invalid"

invalid_mode_set_output=""
if invalid_mode_set_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set unsupported 2>&1)"; then
    fail "unsupported mode sets must fail explicitly"
fi
assert_contains "$invalid_mode_set_output" "error: mode set or compatibility configuration is invalid"

maximum_framebuffer_output=""
if maximum_framebuffer_output="$("${repo_dir}/intel-hidpi.sh" preview \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --framebuffer-limit 8193 2>&1)"; then
    fail "framebuffer limits above the hard maximum must fail explicitly"
fi
assert_contains "$maximum_framebuffer_output" "error: framebuffer limit must be a positive integer no greater than 8192"

assert_document_contains "${repo_dir}/README.md" "When applying a previewed selection, pass the same"
# shellcheck disable=SC2016
assert_document_contains "${repo_dir}/README-zh.md" '将预览结果应用到 override 时，`apply` 必须复用预览所用的'

printf 'PASS: Intel HiDPI smooth modes\n'
