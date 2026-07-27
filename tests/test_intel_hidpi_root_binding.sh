#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_file_exists() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_file_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path: $1"
}

assert_contains() {
    local haystack="$1"
    local expected="$2"

    printf '%s\n' "$haystack" | /usr/bin/grep -Fq "$expected" || fail "missing expected text: $expected"
}

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-root-binding.XXXXXX")"

cleanup() {
    /bin/rm -rf "$scratch_dir"
}
trap cleanup EXIT

system_overrides_root="/Library/Displays/Contents/Resources/Overrides"
system_state_root="/Library/Application Support/one-key-hidpi"
custom_overrides_root="${scratch_dir}/custom-overrides"
custom_state_root="${scratch_dir}/custom-state"

/bin/bash -c '
    DEFAULT_OVERRIDES_ROOT="$2"
    DEFAULT_STATE_ROOT="$3"
    source "$1"

    system_overrides="$(normalize_storage_root "$2")" || exit 1
    system_state="$(normalize_storage_root "$3")" || exit 1
    system_overrides_data="$(normalize_storage_root "/System/Volumes/Data${2}")" || exit 1
    system_state_data="$(normalize_storage_root "/System/Volumes/Data${3}")" || exit 1
    custom_overrides="$(normalize_storage_root "$4")" || exit 1
    custom_state="$(normalize_storage_root "$5")" || exit 1

    storage_roots_have_matching_trust "$system_overrides" "$system_state" || exit 1
    storage_roots_have_matching_trust "$system_overrides_data" "$system_state_data" || exit 1
    storage_roots_have_matching_trust "$custom_overrides" "$custom_state" || exit 1
    if storage_roots_have_matching_trust "$system_overrides" "$custom_state"; then
        exit 1
    fi
    if storage_roots_have_matching_trust "$custom_overrides" "$system_state"; then
        exit 1
    fi
' bash "${repo_dir}/lib/intel_hidpi_storage_support.sh" "$system_overrides_root" "$system_state_root" "$custom_overrides_root" "$custom_state_root" || fail "root trust pairing classification is incorrect"

"${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id cafe \
    --product-id babe \
    --native-resolution 1920x1080 \
    --overrides-root "${custom_overrides_root}/." \
    --state-root "${custom_state_root}/." \
    --confirm || fail "custom overrides and custom state roots should remain supported"

custom_target_path="${custom_overrides_root}/DisplayVendorID-cafe/DisplayProductID-babe"
custom_manifest_path="${custom_state_root}/DisplayVendorID-cafe/DisplayProductID-babe/manifest.plist"
assert_file_exists "$custom_target_path"
assert_file_exists "$custom_manifest_path"

"${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id cafe \
    --product-id babe \
    --overrides-root "${custom_overrides_root}/." \
    --state-root "${custom_state_root}/." \
    --confirm || fail "custom overrides and custom state roots should remain reversible"

assert_file_absent "$custom_target_path"
assert_file_absent "$custom_manifest_path"

mixed_system_overrides_state_root="${scratch_dir}/mixed-system-overrides-state"
mixed_system_overrides_output=""
if mixed_system_overrides_output="$("${repo_dir}/intel-hidpi.sh" apply \
    --vendor-id 1 \
    --product-id 2 \
    --native-resolution 1920x1080 \
    --overrides-root "${system_overrides_root}/./" \
    --state-root "${mixed_system_overrides_state_root}/." \
    --confirm 2>&1)"; then
    fail "system overrides root must reject a custom state root"
fi
assert_contains "$mixed_system_overrides_output" "system overrides root and state root must be used together"
assert_file_absent "$mixed_system_overrides_state_root"

mixed_custom_overrides_root="${scratch_dir}/mixed-custom-overrides"
mixed_system_state_output=""
if mixed_system_state_output="$("${repo_dir}/intel-hidpi.sh" revert \
    --vendor-id 3 \
    --product-id 4 \
    --overrides-root "${mixed_custom_overrides_root}/." \
    --state-root "/System/Volumes/Data${system_state_root}/./" \
    --confirm 2>&1)"; then
    fail "system state root must reject a custom overrides root"
fi
assert_contains "$mixed_system_state_output" "system overrides root and state root must be used together"
assert_file_absent "$mixed_custom_overrides_root"

printf 'PASS: Intel HiDPI system root binding\n'
