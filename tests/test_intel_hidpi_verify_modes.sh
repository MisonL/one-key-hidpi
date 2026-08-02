#!/bin/bash

set -u

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-verify-modes.XXXXXX")" || {
    printf 'FAIL: could not create scratch directory\n' >&2
    exit 1
}

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

cleanup() {
    /bin/rm -rf "$scratch_dir"
}

trap cleanup EXIT

full_modes_path="${scratch_dir}/full-modes.txt"
partial_modes_path="${scratch_dir}/partial-modes.txt"
wrong_target_path="${scratch_dir}/wrong-target.txt"
invalid_modes_path="${scratch_dir}/invalid-modes.txt"
duplicate_target_path="${scratch_dir}/duplicate-target.txt"
trailing_target_path="${scratch_dir}/trailing-target.txt"
trailing_mode_path="${scratch_dir}/trailing-mode.txt"
binary_modes_path="${scratch_dir}/binary-modes.txt"
symlink_modes_path="${scratch_dir}/symlink-modes.txt"
oversized_modes_path="${scratch_dir}/oversized-modes.txt"
missing_modes_path="${scratch_dir}/missing-modes.txt"
directory_modes_path="${scratch_dir}/directory-modes"

# shellcheck disable=SC2016
/usr/bin/grep -Fq 'darwin_read_bounded_file "$normalized_input_file" "$maximum_bytes"' \
    "${repo_dir}/lib/intel_hidpi_verify_modes.sh" ||
    fail "offline reads must use the descriptor-relative Darwin helper"
if /usr/bin/grep -Fq 'sysopen' "${repo_dir}/lib/intel_hidpi_verify_modes.sh"; then
    fail "offline reads must not reopen the input by path"
fi

cat > "$full_modes_path" <<'EOF'
target|vendor-id=000030AE|product-id=000062a5
mode|logical=960x540|pixels=1920x1080|refresh=60.00|flags=1
mode|logical=1152x648|pixels=2304x1296|refresh=60.00|flags=1
mode|logical=1280x720|pixels=2560x1440|refresh=60.00|flags=1
mode|logical=1440x810|pixels=2880x1620|refresh=60.00|flags=1
mode|logical=1920x1080|pixels=3840x2160|refresh=60.00|flags=1
mode|logical=5120x2880|pixels=10240x5760|refresh=60.00|flags=1
EOF

cat > "$partial_modes_path" <<'EOF'
target|vendor-id=30ae|product-id=62a5
mode|logical=960x540|pixels=1920x1080|refresh=60.00|flags=1
mode|logical=1152x648|pixels=2304x1296|refresh=60.00|flags=1
mode|logical=1280x720|pixels=1280x720|refresh=60.00|flags=1
EOF

cat > "$wrong_target_path" <<'EOF'
target|vendor-id=4c2d|product-id=7668
mode|logical=960x540|pixels=1920x1080|refresh=60.00|flags=1
EOF

cat > "$invalid_modes_path" <<'EOF'
target|vendor-id=30ae|product-id=62a5
mode|logical=960x540|pixels=1920x1080
EOF

full_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 000030ae \
    --product-id 000062A5 \
    --native-resolution 1920x1080 \
    --modes-file "$full_modes_path")" || fail "full target capture should verify all generated modes"
assert_contains "$full_output" "capture-source=offline-file"
assert_contains "$full_output" "target=30ae:62a5"
assert_contains "$full_output" "compact: 960x540 framebuffer=1920x1080 status=observed"
assert_contains "$full_output" "balanced: 1152x648 framebuffer=2304x1296 status=observed"
assert_contains "$full_output" "spacious: 1280x720 framebuffer=2560x1440 status=observed"
assert_contains "$full_output" "dense: 1440x810 framebuffer=2880x1620 status=observed"
assert_contains "$full_output" "native: 1920x1080 framebuffer=3840x2160 status=observed"
assert_contains "$full_output" "verification=complete observed=5 missing=0"

duplicate_option_output=""
if duplicate_option_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "a duplicate vendor id option must fail"
fi
assert_contains "$duplicate_option_output" "error: --vendor-id may only be provided once"

duplicate_product_output=""
if duplicate_product_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "a duplicate product id option must fail"
fi
assert_contains "$duplicate_product_output" "error: --product-id may only be provided once"

duplicate_native_resolution_output=""
if duplicate_native_resolution_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --native-resolution 1920x1080 \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "a duplicate native resolution option must fail"
fi
assert_contains "$duplicate_native_resolution_output" "error: --native-resolution may only be provided once"

duplicate_modes_file_output=""
if duplicate_modes_file_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$full_modes_path" \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "a duplicate modes file option must fail"
fi
assert_contains "$duplicate_modes_file_output" "error: --modes-file may only be provided once"

candidate_generation_output=""
if candidate_generation_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1x1 \
    --modes-file "$full_modes_path" 2>&1)"; then
    fail "an unrepresentable candidate set must fail"
fi
assert_contains "$candidate_generation_output" "error: could not generate runtime verification candidates"

partial_output=""
partial_status=0
partial_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$partial_modes_path" 2>&1)" || partial_status=$?
[[ "$partial_status" == 2 ]] || fail "partial target capture must return status 2, got ${partial_status}"
assert_contains "$partial_output" "compact: 960x540 framebuffer=1920x1080 status=observed"
assert_contains "$partial_output" "balanced: 1152x648 framebuffer=2304x1296 status=observed"
assert_contains "$partial_output" "spacious: 1280x720 framebuffer=2560x1440 status=missing"
assert_contains "$partial_output" "dense: 1440x810 framebuffer=2880x1620 status=missing"
assert_contains "$partial_output" "native: 1920x1080 framebuffer=3840x2160 status=missing"
assert_contains "$partial_output" "verification=partial observed=2 missing=3"

wrong_target_output=""
if wrong_target_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$wrong_target_path" 2>&1)"; then
    fail "a capture for another display must fail"
fi
assert_contains "$wrong_target_output" "error: runtime mode target does not match requested display"

invalid_modes_output=""
if invalid_modes_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$invalid_modes_path" 2>&1)"; then
    fail "a malformed mode record must fail"
fi
assert_contains "$invalid_modes_output" "error: runtime mode capture is invalid"

cat > "$trailing_target_path" <<'EOF'
target|vendor-id=30ae|product-id=62a5|
mode|logical=960x540|pixels=1920x1080|refresh=60.00|flags=1
EOF

trailing_target_output=""
if trailing_target_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$trailing_target_path" 2>&1)"; then
    fail "a target record with a trailing field must fail"
fi
assert_contains "$trailing_target_output" "error: runtime mode capture is invalid"

cat > "$trailing_mode_path" <<'EOF'
target|vendor-id=30ae|product-id=62a5
mode|logical=960x540|pixels=1920x1080|refresh=60.00|flags=1|
EOF

trailing_mode_output=""
if trailing_mode_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$trailing_mode_path" 2>&1)"; then
    fail "a mode record with a trailing field must fail"
fi
assert_contains "$trailing_mode_output" "error: runtime mode capture is invalid"

cat > "$duplicate_target_path" <<'EOF'
target|vendor-id=30ae|product-id=62a5
target|vendor-id=30ae|product-id=62a5
mode|logical=960x540|pixels=1920x1080|refresh=60.00|flags=1
EOF

duplicate_target_output=""
if duplicate_target_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$duplicate_target_path" 2>&1)"; then
    fail "a capture with duplicate target records must fail"
fi
assert_contains "$duplicate_target_output" "error: runtime mode capture is invalid"

/usr/bin/perl -e 'print "target|vendor-id=30ae|product-id=62a5\nmode|logical=960x540|pixels=1920x1080|refresh=60.00|flags=1\0\n"' > "$binary_modes_path" || fail "could not create binary capture fixture"
binary_modes_output=""
if binary_modes_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$binary_modes_path" 2>&1)"; then
    fail "a binary capture file must fail"
fi
assert_contains "$binary_modes_output" "error: modes file contains NUL bytes"

missing_modes_output=""
if missing_modes_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "${missing_modes_path}" 2>&1)"; then
    fail "a missing capture file must fail"
fi
assert_contains "$missing_modes_output" "error: could not open modes file"

/bin/ln -s "$full_modes_path" "$symlink_modes_path" || fail "could not create symlink fixture"
symlink_modes_output=""
if symlink_modes_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$symlink_modes_path" 2>&1)"; then
    fail "a symbolic-link capture file must fail"
fi
assert_contains "$symlink_modes_output" "error: modes file must be a regular non-symbolic-link text file"

/bin/mkdir "$directory_modes_path" || fail "could not create directory capture fixture"
directory_modes_output=""
if directory_modes_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$directory_modes_path" 2>&1)"; then
    fail "a directory capture path must fail"
fi
assert_contains "$directory_modes_output" "error: modes file must be a regular non-symbolic-link text file"

/usr/bin/perl -e 'print "x" x 1048577' > "$oversized_modes_path" || fail "could not create oversized capture fixture"
oversized_modes_output=""
if oversized_modes_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "$oversized_modes_path" 2>&1)"; then
    fail "an oversized capture file must fail"
fi
assert_contains "$oversized_modes_output" "error: modes file exceeds 1048576 bytes"

empty_modes_output=""
if empty_modes_output="$("${repo_dir}/intel-hidpi.sh" verify-modes \
    --vendor-id 30ae \
    --product-id 62a5 \
    --native-resolution 1920x1080 \
    --modes-file "" 2>&1)"; then
    fail "an empty modes-file option must fail"
fi
assert_contains "$empty_modes_output" "error: --modes-file requires a regular file path"

printf 'PASS: Intel HiDPI verify modes\n'
