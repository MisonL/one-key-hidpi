#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-verify-override.XXXXXX")"
overrides_root="${scratch_dir}/overrides"
state_root="${scratch_dir}/state"
target_path="${overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
linked_overrides_root="${scratch_dir}/linked-overrides"
betterdisplay_payload_fixture="${repo_dir}/tests/fixtures/betterdisplay-1920x1080-payloads.txt"
fixture_overrides_root="${scratch_dir}/fixture-overrides"
fixture_target_path="${fixture_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
fixture_payloads_xml="${scratch_dir}/betterdisplay-payloads.xml"

# shellcheck source=lib/intel_hidpi_plist_arrays.sh
source "${repo_dir}/lib/intel_hidpi_plist_arrays.sh"

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

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

assert_unchanged() {
    local path="$1"
    local expected_hash="$2"
    local actual_hash

    actual_hash="$(sha256_file "$path")" || fail "could not hash ${path}"
    [[ "$actual_hash" == "$expected_hash" ]] || fail "read-only verification changed ${path}"
}

cleanup() {
    /bin/rm -rf "$scratch_dir"
}

trap cleanup EXIT

[[ -f "$betterdisplay_payload_fixture" && ! -L "$betterdisplay_payload_fixture" ]] ||
    fail "missing BetterDisplay payload fixture"
/bin/mkdir -p "$(/usr/bin/dirname "$fixture_target_path")" || fail "could not create BetterDisplay payload fixture override"
/usr/bin/plutil -create xml1 "$fixture_target_path" || fail "could not create BetterDisplay payload fixture override"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$fixture_target_path" || fail "could not write BetterDisplay fixture vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$fixture_target_path" || fail "could not write BetterDisplay fixture product id"
{
    printf '<array>'
    while IFS= read -r fixture_payload || [[ -n "$fixture_payload" ]]; do
        [[ -n "$fixture_payload" ]] || continue
        printf '<data>%s</data>' "$fixture_payload"
    done < "$betterdisplay_payload_fixture"
    printf '</array>'
} > "$fixture_payloads_xml" || fail "could not prepare BetterDisplay fixture payload array"
/usr/bin/plutil -insert scale-resolutions -xml "$(/bin/cat "$fixture_payloads_xml")" "$fixture_target_path" ||
    fail "could not write BetterDisplay fixture payload array"
fixture_payload_count="$(/usr/bin/plutil -extract scale-resolutions raw -o - "$fixture_target_path")" ||
    fail "could not count BetterDisplay fixture payloads"
[[ "$fixture_payload_count" == 126 ]] || fail "BetterDisplay payload fixture must contain 126 payloads"
fixture_hash="$(sha256_file "$fixture_target_path")" || fail "could not hash BetterDisplay fixture override"
fixture_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$fixture_overrides_root")" || fail "BetterDisplay fixture payload set should verify"
assert_contains "$fixture_output" "payload-set=exact expected=126 observed=126 missing=0 extra=0 duplicates=0"
assert_contains "$fixture_output" "verification=complete matched=126 missing=0"
assert_unchanged "$fixture_target_path" "$fixture_hash"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" \
    --state-root "$state_root" \
    --confirm || fail "could not create an isolated compatible override fixture"

exact_hash="$(sha256_file "$target_path")" || fail "could not hash the complete override fixture"
exact_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root")" || fail "complete compatible override should verify"
assert_contains "$exact_output" "override=DisplayVendorID-30ae/DisplayProductID-62a5"
assert_contains "$exact_output" "target=30ae:62a5"
assert_contains "$exact_output" "payload-set=exact expected=126 observed=126 missing=0 extra=0 duplicates=0"
assert_contains "$exact_output" "verification=complete matched=126 missing=0"
assert_unchanged "$target_path" "$exact_hash"

/usr/bin/plutil -insert scale-resolutions.126 -xml '<dict><key>nested-payload</key><data>AAAAAQAAAAE=</data></dict>' "$target_path" ||
    fail "could not add a nested non-direct payload to the fixture"
nested_hash="$(sha256_file "$target_path")" || fail "could not hash the nested-payload override fixture"
nested_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root")" || fail "nested non-direct payloads must not alter direct payload-set verification"
assert_contains "$nested_output" "payload-set=exact expected=126 observed=126 missing=0 extra=0 duplicates=0"
assert_unchanged "$target_path" "$nested_hash"
/usr/bin/plutil -remove scale-resolutions.126 "$target_path" || fail "could not remove the nested non-direct payload from the fixture"

split_payload_output="$(data_payloads_from_plist_array_xml '<plist><array><data>AAAK<![CDATA[AAAABaAAAAABACAAAA==]]></data></array></plist>')" ||
    fail "split direct payload XML must parse safely"
[[ "$split_payload_output" == "AAAKAAAABaAAAAABACAAAA==" ]] ||
    fail "split direct payload XML must join text and CDATA segments"

no_data_overrides_root="${scratch_dir}/no-data-overrides"
no_data_target_path="${no_data_overrides_root}/DisplayVendorID-30ae/DisplayProductID-62a5"
/bin/mkdir -p "$(/usr/bin/dirname "$no_data_target_path")" || fail "could not create no-data override fixture"
/usr/bin/plutil -create xml1 "$no_data_target_path" || fail "could not create no-data override fixture"
/usr/bin/plutil -insert DisplayVendorID -integer 12462 "$no_data_target_path" || fail "could not write no-data fixture vendor id"
/usr/bin/plutil -insert DisplayProductID -integer 25253 "$no_data_target_path" || fail "could not write no-data fixture product id"
/usr/bin/plutil -insert scale-resolutions -array "$no_data_target_path" || fail "could not initialize no-data fixture mode array"
/usr/bin/plutil -insert scale-resolutions.0 -string preserve-array-entry "$no_data_target_path" || fail "could not write no-data fixture entry"
no_data_hash="$(sha256_file "$no_data_target_path")" || fail "could not hash the no-data override fixture"
no_data_output=""
no_data_status=0
no_data_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$no_data_overrides_root" 2>&1)" || no_data_status=$?
[[ "$no_data_status" == 2 ]] || fail "an override without direct data payloads must return status 2, got ${no_data_status}"
assert_contains "$no_data_output" "payload-set=partial expected=126 observed=0 missing=126 extra=0 duplicates=0"
assert_contains "$no_data_output" "verification=mismatch matched=0 missing=126 extra=0"
assert_unchanged "$no_data_target_path" "$no_data_hash"

/usr/bin/plutil -insert scale-resolutions.126 -xml '<data></data>' "$target_path" ||
    fail "could not add an empty direct payload to the fixture"
empty_payload_hash="$(sha256_file "$target_path")" || fail "could not hash the empty-payload override fixture"
empty_payload_output=""
if empty_payload_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" 2>&1)"; then
    fail "verify-override must reject an empty direct data payload"
fi
assert_contains "$empty_payload_output" "error: could not read target override payloads safely"
assert_unchanged "$target_path" "$empty_payload_hash"
/usr/bin/plutil -remove scale-resolutions.126 "$target_path" || fail "could not remove the empty direct payload from the fixture"

/usr/bin/plutil -insert scale-resolutions.126 -xml '<data>%%%%</data>' "$target_path" ||
    fail "could not add a malformed direct payload to the fixture"
malformed_payload_hash="$(sha256_file "$target_path")" || fail "could not hash the malformed-payload override fixture"
malformed_payload_output=""
if malformed_payload_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" 2>&1)"; then
    fail "verify-override must reject a malformed direct data payload"
fi
assert_contains "$malformed_payload_output" "error: could not read target override payloads safely"
assert_unchanged "$target_path" "$malformed_payload_hash"
/usr/bin/plutil -remove scale-resolutions.126 "$target_path" || fail "could not remove the malformed direct payload from the fixture"

duplicate_option_output=""
if duplicate_option_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-similar-resolutions \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" 2>&1)"; then
    fail "verify-override must reject duplicate similar-resolution options"
fi
assert_contains "$duplicate_option_output" "error: --include-similar-resolutions may only be provided once"

invalid_configuration_output=""
if invalid_configuration_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set preset \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" 2>&1)"; then
    fail "verify-override must require the smooth mode set for similar resolutions"
fi
assert_contains "$invalid_configuration_output" "error: mode set or compatibility configuration is invalid"

/usr/bin/plutil -remove scale-resolutions.125 "$target_path" || fail "could not remove a required payload from the fixture"
partial_hash="$(sha256_file "$target_path")" || fail "could not hash the partial override fixture"
partial_output=""
partial_status=0
partial_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" 2>&1)" || partial_status=$?
[[ "$partial_status" == 2 ]] || fail "missing payload must return status 2, got ${partial_status}"
assert_contains "$partial_output" "payload-set=partial expected=126 observed=125 missing=1 extra=0 duplicates=0"
assert_contains "$partial_output" "missing-payload=AAAPAAAACG4="
assert_contains "$partial_output" "verification=mismatch matched=125 missing=1 extra=0"
assert_unchanged "$target_path" "$partial_hash"

/usr/bin/plutil -insert scale-resolutions.125 -data AAAPAAAACG4= "$target_path" || fail "could not restore the required payload"
/usr/bin/plutil -insert scale-resolutions.126 -data AAAAAQAAAAE= "$target_path" || fail "could not add an extra payload"
superset_hash="$(sha256_file "$target_path")" || fail "could not hash the superset override fixture"
superset_output=""
superset_status=0
superset_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" 2>&1)" || superset_status=$?
[[ "$superset_status" == 2 ]] || fail "an override with extra payloads must return status 2, got ${superset_status}"
assert_contains "$superset_output" "payload-set=superset expected=126 observed=127 missing=0 extra=1 duplicates=0"
assert_contains "$superset_output" "extra-payload=AAAAAQAAAAE="
assert_contains "$superset_output" "verification=mismatch matched=126 missing=0 extra=1"
assert_unchanged "$target_path" "$superset_hash"

/usr/bin/plutil -remove scale-resolutions.126 "$target_path" || fail "could not remove the extra payload from the fixture"
/usr/bin/plutil -insert scale-resolutions.126 -data AAAKAAAABaAAAAABACAAAA== "$target_path" || fail "could not add a duplicate payload to the fixture"
duplicate_hash="$(sha256_file "$target_path")" || fail "could not hash the duplicate-payload override fixture"
duplicate_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root")" || fail "duplicate direct data entries must retain exact set semantics"
assert_contains "$duplicate_output" "payload-set=exact expected=126 observed=126 missing=0 extra=0 duplicates=1"
assert_contains "$duplicate_output" "verification=complete matched=126 missing=0"
assert_unchanged "$target_path" "$duplicate_hash"

/usr/bin/plutil -replace DisplayVendorID -integer 1 "$target_path" || fail "could not create a mismatched override fixture"
identifier_mismatch_output=""
if identifier_mismatch_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --include-near-native \
    --include-similar-resolutions \
    --overrides-root "$overrides_root" 2>&1)"; then
    fail "verify-override must reject a mismatched override header"
fi
assert_contains "$identifier_mismatch_output" "error: override display identifiers do not match the requested target"

/bin/ln -s "$overrides_root" "$linked_overrides_root" || fail "could not create a linked override root fixture"
linked_root_output=""
if linked_root_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --overrides-root "$linked_overrides_root" 2>&1)"; then
    fail "verify-override must reject a symbolic-link override root"
fi
assert_contains "$linked_root_output" "error: overrides root is invalid or traverses a symbolic link"

absent_override_output=""
if absent_override_output="$("${repo_dir}/intel-hidpi.sh" verify-override \
    --vendor-id 30ae \
    --product-id dead \
    --native-resolution 1920x1080 \
    --mode-set smooth \
    --overrides-root "$overrides_root" 2>&1)"; then
    fail "verify-override must reject a missing target override"
fi
assert_contains "$absent_override_output" "error: target override is not a regular file"

printf 'PASS: Intel HiDPI override verification\n'
