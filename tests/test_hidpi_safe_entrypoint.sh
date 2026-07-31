#!/bin/bash

set -u
set -o pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
entrypoint_path="${repo_dir}/hidpi.sh"
command_path="${repo_dir}/hidpi.command"
intel_tool_path="${repo_dir}/intel-hidpi.sh"
fixture_dir="${repo_dir}/tests/fixtures"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local expected="$2"

    case "$haystack" in
    *"$expected"*)
        ;;
    *)
        fail "missing expected text: ${expected}"
        ;;
    esac
}

assert_not_contains() {
    local haystack="$1"
    local unexpected="$2"

    case "$haystack" in
    *"$unexpected"*)
        fail "unexpected text: ${unexpected}"
        ;;
    *)
        ;;
    esac
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

first_edid="$(/usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p' "${fixture_dir}/ioreg-displays.txt" | /usr/bin/sed -n '1p')"
second_edid="$(/usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p' "${fixture_dir}/ioreg-displays.txt" | /usr/bin/sed -n '2p')"
[[ -n "$first_edid" && -n "$second_edid" ]] || fail "could not load EDID fixtures"

entrypoint_contents="$(/bin/cat "$entrypoint_path")" || fail "could not read safe entrypoint"
[[ -x "$entrypoint_path" ]] || fail "safe entrypoint must remain executable for hidpi.command"
for forbidden in \
    'sudo ' \
    'curl ' \
    'defaults write' \
    'rm -rf' \
    'cp -r' \
    'create_res' \
    'enable_hidpi' \
    'enable_hidpi_with_patch'; do
    assert_not_contains "$entrypoint_contents" "$forbidden"
done
assert_contains "$entrypoint_contents" "/usr/sbin/ioreg -lw0"
assert_contains "$entrypoint_contents" "/usr/bin/dirname"

command_contents="$(/bin/cat "$command_path")" || fail "could not read hidpi.command"
[[ -x "$command_path" ]] || fail "hidpi.command must remain executable"
command_dispatch_literal="\"\$DIR/hidpi.sh\""
assert_contains "$command_contents" "$command_dispatch_literal"
assert_contains "$command_contents" "/usr/bin/dirname"

intel_tool_contents="$(/bin/cat "$intel_tool_path")" || fail "could not read Intel tool"
assert_contains "$intel_tool_contents" "/usr/sbin/ioreg -lw0"

readme_contents="$(/bin/cat "${repo_dir}/README.md")" || fail "could not read English README"
assert_contains "$readme_contents" "./hidpi.sh"
assert_contains "$readme_contents" "./intel-hidpi.sh revert"
assert_not_contains "$readme_contents" "curl"
assert_not_contains "$readme_contents" ".hidpi-disable"
assert_not_contains "$readme_contents" "legacy menu"
assert_contains "$readme_contents" "symbolic links"

readme_zh_contents="$(/bin/cat "${repo_dir}/README-zh.md")" || fail "could not read Chinese README"
assert_contains "$readme_zh_contents" "./hidpi.sh"
assert_contains "$readme_zh_contents" "./intel-hidpi.sh revert"
assert_not_contains "$readme_zh_contents" "curl"
assert_not_contains "$readme_zh_contents" ".hidpi-disable"
assert_not_contains "$readme_zh_contents" "传统菜单"
assert_contains "$readme_zh_contents" "符号链接"

workspace_root="$(mktemp -d "${TMPDIR:-/tmp}/one-key-hidpi-safe-entrypoint.XXXXXX")" || fail "could not create fixture root"
workspace_root="$(cd "$workspace_root" && pwd)" || fail "could not normalize fixture root"
complete_root="${workspace_root}/complete"
incomplete_root="${workspace_root}/incomplete"
partial_root="${workspace_root}/partial"
linked_tool_root="${workspace_root}/linked-tool"
linked_menu_root="${workspace_root}/linked-menu"
linked_lib_root="${workspace_root}/linked-lib"
linked_entry_root="${workspace_root}/linked-entry"
linked_direct_tool_root="${workspace_root}/linked-direct-tool"
command_root="${workspace_root}/command"
linked_command_root="${workspace_root}/linked-command"
outside_entrypoint_path="${workspace_root}/outside-hidpi.sh"
outside_direct_tool_path="${workspace_root}/outside-direct-intel-hidpi.sh"
outside_command_path="${workspace_root}/outside-hidpi.command"
outside_tool_path="${workspace_root}/outside-intel-hidpi.sh"
outside_menu_path="${workspace_root}/outside-intel-hidpi-menu.sh"
outside_lib_directory="${workspace_root}/outside-lib"
fixture_bin="${workspace_root}/bin"
invalid_first_ioreg_file="${workspace_root}/invalid-first-ioreg.txt"
invalid_only_ioreg_file="${workspace_root}/invalid-only-ioreg.txt"
duplicate_ioreg_file="${workspace_root}/duplicate-ioreg.txt"
same_target_ioreg_file="${workspace_root}/same-target-ioreg.txt"
zero_product_ioreg_file="${workspace_root}/zero-product-ioreg.txt"
zero_vendor_ioreg_file="${workspace_root}/zero-vendor-ioreg.txt"

cleanup() {
    /bin/rm -rf "$workspace_root"
}
trap cleanup EXIT

/bin/mkdir -p "$complete_root" "$incomplete_root" "$partial_root" "$linked_tool_root" "$linked_menu_root" "$linked_lib_root" "$linked_entry_root" "$linked_direct_tool_root" "$command_root" "$linked_command_root" "$fixture_bin" || fail "could not create fixture directories"
/bin/cp "$entrypoint_path" "${complete_root}/hidpi.sh" || fail "could not copy complete entrypoint"
/bin/cp "${repo_dir}/intel-hidpi.sh" "${complete_root}/intel-hidpi.sh" || fail "could not copy complete Intel tool"
/bin/cp -R "${repo_dir}/lib" "${complete_root}/lib" || fail "could not copy complete Intel libraries"
/bin/cp "$entrypoint_path" "${incomplete_root}/hidpi.sh" || fail "could not copy incomplete entrypoint"
/bin/cp "$entrypoint_path" "${partial_root}/hidpi.sh" || fail "could not copy partial entrypoint"
/bin/cp "${repo_dir}/intel-hidpi.sh" "${partial_root}/intel-hidpi.sh" || fail "could not copy partial Intel tool"
/bin/cp -R "${repo_dir}/lib" "${partial_root}/lib" || fail "could not copy partial Intel libraries"
/bin/rm "${partial_root}/lib/intel_hidpi_manifest.sh" || fail "could not remove partial Intel dependency"
/bin/cp "$entrypoint_path" "${linked_tool_root}/hidpi.sh" || fail "could not copy linked-tool entrypoint"
/bin/cp -R "${repo_dir}/lib" "${linked_tool_root}/lib" || fail "could not copy linked-tool libraries"
/bin/cp "$entrypoint_path" "${linked_menu_root}/hidpi.sh" || fail "could not copy linked-menu entrypoint"
/bin/cp "${repo_dir}/intel-hidpi.sh" "${linked_menu_root}/intel-hidpi.sh" || fail "could not copy linked-menu Intel tool"
/bin/cp -R "${repo_dir}/lib" "${linked_menu_root}/lib" || fail "could not copy linked-menu libraries"
/bin/cp "$entrypoint_path" "${linked_lib_root}/hidpi.sh" || fail "could not copy linked-lib entrypoint"
/bin/cp "$intel_tool_path" "${linked_lib_root}/intel-hidpi.sh" || fail "could not copy linked-lib Intel tool"
/bin/cp -R "${repo_dir}/lib" "$outside_lib_directory" || fail "could not copy outside linked library"
/bin/cp "$entrypoint_path" "$outside_entrypoint_path" || fail "could not copy outside entrypoint"
/bin/cp "$intel_tool_path" "$outside_direct_tool_path" || fail "could not copy outside Intel tool"
/bin/cp "$command_path" "$outside_command_path" || fail "could not copy outside command wrapper"
/bin/ln -s "$outside_entrypoint_path" "${linked_entry_root}/hidpi.sh" || fail "could not link outside entrypoint"
/bin/ln -s "$outside_direct_tool_path" "${linked_direct_tool_root}/intel-hidpi.sh" || fail "could not link outside Intel tool entrypoint"
/bin/cp "$command_path" "${command_root}/hidpi.command" || fail "could not copy command wrapper"
/bin/ln -s "$outside_command_path" "${linked_command_root}/hidpi.command" || fail "could not link outside command wrapper"
printf '%s\n' '#!/bin/bash' 'printf "command-wrapper-dispatch\\n"' > "${command_root}/hidpi.sh" || fail "could not create command wrapper target"
printf '%s\n' '#!/bin/bash' 'exit 92' > "$outside_tool_path" || fail "could not create outside Intel tool"
printf '%s\n' 'intel_safe_hidpi() { exit 93; }' > "$outside_menu_path" || fail "could not create outside Intel menu"
/bin/ln -s "$outside_tool_path" "${linked_tool_root}/intel-hidpi.sh" || fail "could not link outside Intel tool"
/bin/rm "${linked_menu_root}/lib/intel_hidpi_menu.sh" || fail "could not remove linked-menu library"
/bin/ln -s "$outside_menu_path" "${linked_menu_root}/lib/intel_hidpi_menu.sh" || fail "could not link outside Intel menu"
/bin/ln -s "$outside_lib_directory" "${linked_lib_root}/lib" || fail "could not link outside Intel library directory"
/bin/chmod +x "${complete_root}/hidpi.sh" "${complete_root}/intel-hidpi.sh" \
    "${incomplete_root}/hidpi.sh" "${partial_root}/hidpi.sh" "${partial_root}/intel-hidpi.sh" \
    "${linked_tool_root}/hidpi.sh" "${linked_menu_root}/hidpi.sh" "${linked_menu_root}/intel-hidpi.sh" \
    "${linked_lib_root}/hidpi.sh" "${linked_lib_root}/intel-hidpi.sh" \
    "$outside_entrypoint_path" "$outside_direct_tool_path" "$outside_command_path" \
    "${command_root}/hidpi.command" "${command_root}/hidpi.sh" ||
    fail "could not mark fixture entrypoints executable"

# The fixture PATH makes an unqualified ioreg invocation fail. The entrypoint
# must use the explicit reader function, which the test replaces below.
printf '%s\n' '#!/bin/bash' 'exit 91' > "${fixture_bin}/ioreg" || fail "could not create failing ioreg fixture command"
printf '%s\n' '#!/bin/bash' 'exit 94' > "${fixture_bin}/dirname" || fail "could not create failing dirname fixture command"
printf '%s\n' '#!/bin/bash' 'exit 95' > "${fixture_bin}/cat" || fail "could not create failing cat fixture command"
/bin/chmod +x "${fixture_bin}/ioreg" "${fixture_bin}/dirname" "${fixture_bin}/cat" || fail "could not make failing fixture commands executable"

command_wrapper_output="$(
    PATH="${fixture_bin}:${PATH}" "${command_root}/hidpi.command"
)" || fail "hidpi.command must resolve its local target without PATH dirname"
assert_contains "$command_wrapper_output" "command-wrapper-dispatch"

linked_command_output=""
if linked_command_output="$("${linked_command_root}/hidpi.command" 2>&1)"; then
    fail "linked hidpi.command must fail"
fi
assert_contains "$linked_command_output" "regular local checkout entrypoint"

invalid_first_edid="01${first_edid:2}"
printf '    | | "IODisplayEDID" = <%s>\n' "$invalid_first_edid" > "$invalid_first_ioreg_file"
printf '    | | "IODisplayEDID" = <%s>\n' "$second_edid" >> "$invalid_first_ioreg_file"
printf '    | | "IODisplayEDID" = <%s>\n' "$invalid_first_edid" > "$invalid_only_ioreg_file"

duplicate_target_edid="${first_edid:0:24}01000000${first_edid:32}"
duplicate_target_edid="$(with_recalculated_base_checksum "$duplicate_target_edid")"
zero_product_edid="${first_edid:0:20}0000${first_edid:24}"
zero_product_edid="$(with_recalculated_base_checksum "$zero_product_edid")"
zero_vendor_edid="${first_edid:0:16}0000${first_edid:20}"
zero_vendor_edid="$(with_recalculated_base_checksum "$zero_vendor_edid")"
printf '    | | "IODisplayEDID" = <%s>\n' "$first_edid" > "$duplicate_ioreg_file"
printf '    | | "IODisplayEDID" = <%s>\n' "$first_edid" >> "$duplicate_ioreg_file"
printf '    | | "IODisplayEDID" = <%s>\n' "$first_edid" > "$same_target_ioreg_file"
printf '    | | "IODisplayEDID" = <%s>\n' "$duplicate_target_edid" >> "$same_target_ioreg_file"
printf '    | | "IODisplayEDID" = <%s>\n' "$zero_product_edid" > "$zero_product_ioreg_file"
printf '    | | "IODisplayEDID" = <%s>\n' "$zero_vendor_edid" > "$zero_vendor_ioreg_file"

run_dispatch_fixture() {
    local ioreg_file="$1"
    local input="$2"

    printf '%s' "$input" |
        PATH="${fixture_bin}:${PATH}" \
            HIDPI_TEST_IOREG_FILE="$ioreg_file" \
            LANG=C \
            LC_ALL=C \
            /bin/bash -c '
                source "$1"
                safe_entrypoint_read_ioreg() {
                    /bin/cat "$HIDPI_TEST_IOREG_FILE"
                }
                intel_safe_hidpi() {
                    printf "dispatch|%s|%s|%s|%s\\n" "$1" "$2" "$3" "$4"
                }
                start
            ' bash "${complete_root}/hidpi.sh"
}

invalid_first_dispatch="$(run_dispatch_fixture "$invalid_first_ioreg_file" "")" || fail "a valid display after an invalid EDID should dispatch successfully"
assert_contains "$invalid_first_dispatch" "dispatch|${complete_root}/intel-hidpi.sh|${second_edid}|4c2d|7668"

multi_display_dispatch="$(run_dispatch_fixture "${fixture_dir}/ioreg-displays.txt" $'2\n')" || fail "the second valid display should be selectable"
assert_contains "$multi_display_dispatch" "dispatch|${complete_root}/intel-hidpi.sh|${second_edid}|4c2d|7668"

duplicate_edid_dispatch="$(run_dispatch_fixture "$duplicate_ioreg_file" "")" || fail "duplicate EDID records should be deduplicated"
assert_contains "$duplicate_edid_dispatch" "dispatch|${complete_root}/intel-hidpi.sh|${first_edid}|30ae|62a5"
assert_not_contains "$duplicate_edid_dispatch" "Detected display records"

zero_product_dispatch="$(run_dispatch_fixture "$zero_product_ioreg_file" "")" || fail "a valid EDID with a zero product ID should dispatch successfully"
assert_contains "$zero_product_dispatch" "dispatch|${complete_root}/intel-hidpi.sh|${zero_product_edid}|30ae|0"

zero_vendor_output=""
if zero_vendor_output="$(run_dispatch_fixture "$zero_vendor_ioreg_file" "" 2>&1)"; then
    fail "an EDID with a zero vendor ID must fail"
fi
assert_contains "$zero_vendor_output" "No valid external display was found"

invalid_selection_output=""
if invalid_selection_output="$(run_dispatch_fixture "${fixture_dir}/ioreg-displays.txt" $'3\n' 2>&1)"; then
    fail "an out-of-range display selection must fail"
fi
assert_contains "$invalid_selection_output" "Invalid selection"
assert_not_contains "$invalid_selection_output" "dispatch|"
assert_not_contains "$invalid_selection_output" "No valid external display was found"

oversized_selection_output=""
if oversized_selection_output="$(run_dispatch_fixture "${fixture_dir}/ioreg-displays.txt" $'999999999999999999999999999999999999\n' 2>&1)"; then
    fail "an oversized display selection must fail"
fi
assert_contains "$oversized_selection_output" "Invalid selection"
assert_not_contains "$oversized_selection_output" "dispatch|"

same_target_output=""
if same_target_output="$(run_dispatch_fixture "$same_target_ioreg_file" "" 2>&1)"; then
    fail "different EDIDs with the same override target must fail"
fi
assert_contains "$same_target_output" "Multiple display records share one override target."
assert_not_contains "$same_target_output" "dispatch|"
assert_not_contains "$same_target_output" "No valid external display was found"

no_valid_output=""
if no_valid_output="$(run_dispatch_fixture "$invalid_only_ioreg_file" "" 2>&1)"; then
    fail "an ioreg fixture without a valid EDID must fail"
fi
assert_contains "$no_valid_output" "No valid external display was found"

complete_output="$(
    printf '2\n1\n3\n' |
        PATH="${fixture_bin}:${PATH}" \
            HIDPI_TEST_IOREG_FILE="${fixture_dir}/ioreg-displays.txt" \
            LANG=C \
            LC_ALL=C \
            /bin/bash -c '
                source "$1"
                safe_entrypoint_read_ioreg() {
                    /bin/cat "$HIDPI_TEST_IOREG_FILE"
                }
                start
            ' bash "${complete_root}/hidpi.sh"
)" || fail "complete local entrypoint preview and cancel should succeed"
assert_contains "$complete_output" "Intel safe HiDPI: 3840x2160"
assert_contains "$complete_output" "Cancelled"

if /bin/bash "${incomplete_root}/hidpi.sh" >/dev/null 2>"${workspace_root}/incomplete.stderr"; then
    fail "entrypoint without Intel dependencies must fail"
fi
assert_contains "$(/bin/cat "${workspace_root}/incomplete.stderr")" "Intel safe HiDPI requires a complete local checkout"

partial_output=""
if partial_output="$(
    /bin/bash "${partial_root}/hidpi.sh" 2>&1
)"; then
    fail "entrypoint with an incomplete Intel dependency graph must fail"
fi
assert_contains "$partial_output" "Intel safe HiDPI requires a complete local checkout"

linked_tool_output=""
if linked_tool_output="$(
    /bin/bash "${linked_tool_root}/hidpi.sh" 2>&1
)"; then
    fail "entrypoint with a linked Intel tool must fail"
fi
assert_contains "$linked_tool_output" "Intel safe HiDPI requires a complete local checkout"

linked_menu_output=""
if linked_menu_output="$(
    /bin/bash "${linked_menu_root}/hidpi.sh" 2>&1
)"; then
    fail "entrypoint with a linked Intel menu must fail"
fi
assert_contains "$linked_menu_output" "Intel safe HiDPI requires a complete local checkout"

linked_lib_output=""
if linked_lib_output="$(
    /bin/bash -c 'source "$1"' bash "${linked_lib_root}/hidpi.sh" 2>&1
)"; then
    fail "entrypoint with a linked Intel library directory must fail"
fi
assert_contains "$linked_lib_output" "Intel safe HiDPI requires a complete local checkout"

linked_entry_output=""
if linked_entry_output="$(
    /bin/bash "${linked_entry_root}/hidpi.sh" 2>&1
)"; then
    fail "linked hidpi.sh must fail"
fi
assert_contains "$linked_entry_output" "regular local checkout entrypoint"

linked_direct_tool_output=""
if linked_direct_tool_output="$(
    /bin/bash "${linked_lib_root}/intel-hidpi.sh" --help 2>&1
)"; then
    fail "direct Intel tool with a linked library directory must fail"
fi
assert_contains "$linked_direct_tool_output" "Intel HiDPI requires a complete local checkout"

linked_direct_tool_entry_output=""
if linked_direct_tool_entry_output="$(
    /bin/bash "${linked_direct_tool_root}/intel-hidpi.sh" --help 2>&1
)"; then
    fail "linked direct Intel tool must fail"
fi
assert_contains "$linked_direct_tool_entry_output" "regular local checkout entrypoint"

printf 'PASS: safe HiDPI entrypoint\n'
