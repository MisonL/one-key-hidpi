TEMPORARY_FILES=("")
TEMPORARY_FILE_HASHES=("")
TEMPORARY_FILE_IDENTITIES=("")
TEMPORARY_FILE=""
OPERATION_TEMPORARY_DIRECTORY=""
OPERATION_TEMPORARY_DIRECTORY_IDENTITY=""
OPERATION_LOCK_PATH=""
OPERATION_LOCK_HASH=""
OPERATION_LOCK_IDENTITY=""
PLIST_OPERATION_HASH=""
PLIST_OPERATION_IDENTITY=""

INTEL_HIDPI_STORAGE_LIB_DIR="$(builtin cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd)" || return 1
# shellcheck source=lib/intel_hidpi_mode_configuration.sh
source "${INTEL_HIDPI_STORAGE_LIB_DIR}/intel_hidpi_mode_configuration.sh" || return 1
# shellcheck source=lib/intel_hidpi_darwin_fs.sh
source "${INTEL_HIDPI_STORAGE_LIB_DIR}/intel_hidpi_darwin_fs.sh" || return 1
# shellcheck source=lib/intel_hidpi_manifest.sh
source "${INTEL_HIDPI_STORAGE_LIB_DIR}/intel_hidpi_manifest.sh" || return 1
unset INTEL_HIDPI_STORAGE_LIB_DIR

cleanup_temporary_files() {
    local temporary_file
    local temporary_hash
    local temporary_identity
    local index
    local cleanup_status=0

    for ((index = 0; index < ${#TEMPORARY_FILES[@]}; index++)); do
        temporary_file="${TEMPORARY_FILES[$index]}"
        temporary_hash="${TEMPORARY_FILE_HASHES[$index]:-}"
        temporary_identity="${TEMPORARY_FILE_IDENTITIES[$index]:-}"
        [[ -n "$temporary_file" && ( -e "$temporary_file" || -L "$temporary_file" ) ]] || continue
        if ! valid_sha256 "$temporary_hash" || ! valid_file_identity "$temporary_identity" ||
            ! remove_file_if_unchanged "$temporary_file" "$temporary_hash" "$temporary_identity"; then
            printf 'error: refusing to remove a changed temporary artifact: %s\n' "$temporary_file" >&2
            cleanup_status=1
        fi
    done
    return "$cleanup_status"
}

release_display_lock() {
    [[ -n "$OPERATION_LOCK_PATH" ]] || return 0
    valid_sha256 "$OPERATION_LOCK_HASH" || return 1
    valid_file_identity "$OPERATION_LOCK_IDENTITY" || return 1
    remove_file_if_unchanged "$OPERATION_LOCK_PATH" "$OPERATION_LOCK_HASH" "$OPERATION_LOCK_IDENTITY" || return 1
    OPERATION_LOCK_PATH=""
    OPERATION_LOCK_HASH=""
    OPERATION_LOCK_IDENTITY=""
}

cleanup_runtime_artifacts() {
    cleanup_temporary_files || printf 'error: temporary artifacts were retained for manual inspection\n' >&2
    if [[ -n "$OPERATION_TEMPORARY_DIRECTORY" ]]; then
        valid_file_identity "$OPERATION_TEMPORARY_DIRECTORY_IDENTITY" &&
            darwin_remove_empty_directory_if_unchanged "$OPERATION_TEMPORARY_DIRECTORY" "$OPERATION_TEMPORARY_DIRECTORY_IDENTITY" ||
            printf 'error: private operation directory was retained for manual inspection\n' >&2
    fi
    release_display_lock || printf 'error: display operation lock was retained for manual inspection\n' >&2
}

trap cleanup_runtime_artifacts EXIT

normalize_lexical_path() {
    local input_path="$1"
    local absolute_path
    local current_directory
    local component
    local normalized_path=""
    local -a input_components=("")

    [[ -n "$input_path" && "$input_path" != *$'\n'* && "$input_path" != *$'\r'* ]] || return 1
    if [[ "$input_path" == /* ]]; then
        absolute_path="$input_path"
    else
        current_directory="$(/bin/pwd -P)" || return 1
        absolute_path="${current_directory}/${input_path}"
    fi

    IFS='/' read -r -a input_components <<< "$absolute_path"
    for component in "${input_components[@]}"; do
        case "$component" in
        ""|.)
            ;;
        ..)
            [[ -n "$normalized_path" ]] || return 1
            normalized_path="${normalized_path%/*}"
            ;;
        *)
            [[ "$component" != *$'\n'* && "$component" != *$'\r'* ]] || return 1
            normalized_path="${normalized_path}/${component}"
            ;;
        esac
    done

    if [[ -z "$normalized_path" ]]; then
        printf '/\n'
        return 0
    fi
    printf '%s\n' "$normalized_path"
}

path_has_disallowed_symbolic_link() {
    local path="$1"
    local component
    local current_path=""
    local -a components

    IFS='/' read -r -a components <<< "$path"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current_path="${current_path}/${component}"
        [[ -L "$current_path" ]] || continue
        case "$current_path" in
        /tmp|/var)
            ;;
        *)
            return 0
            ;;
        esac
    done
    return 1
}

normalize_storage_root() {
    local input_path="$1"
    local lexical_path

    lexical_path="$(normalize_lexical_path "$input_path")" || return 1
    case "$lexical_path" in
    /tmp|/tmp/*)
        lexical_path="/private${lexical_path}"
        ;;
    /var|/var/*)
        lexical_path="/private${lexical_path}"
        ;;
    esac
    path_has_disallowed_symbolic_link "$lexical_path" && return 1

    # Keep this stage lexical. Resolving an existing component with realpath
    # would follow a link swapped in after the check above and turn that
    # external destination into a trusted path. Every filesystem operation
    # below resolves components from a directory FD with O_NOFOLLOW instead.
    printf '%s\n' "$lexical_path"
}

ensure_directory_path_without_symlinks() {
    local path="$1"

    [[ "$path" == /* ]] || return 1
    darwin_ensure_directory_path "$path"
}

acquire_display_lock() {
    local overrides_root="$1"
    local vendor_id="$2"
    local product_id="$3"
    local locks_directory
    local lock_path

    locks_directory="${overrides_root}/.one-key-hidpi-locks"
    ensure_directory_path_without_symlinks "$locks_directory" || return 1
    lock_path="$(target_lock_path "$overrides_root" "$vendor_id" "$product_id")" || return 1
    local lock_snapshot

    lock_snapshot="$(darwin_acquire_lock "$lock_path" "$$")" || return 1
    IFS='|' read -r OPERATION_LOCK_HASH OPERATION_LOCK_IDENTITY <<< "$lock_snapshot"
    OPERATION_LOCK_PATH="$lock_path"
    valid_sha256 "$OPERATION_LOCK_HASH" || return 1
    valid_file_identity "$OPERATION_LOCK_IDENTITY" || return 1
}

normalize_hex_id() {
    local value="$1"

    [[ "$value" =~ ^[0-9A-Fa-f]{1,8}$ ]] || return 1
    printf '%s\n' "$(printf '%08x' "$((16#$value))" | /usr/bin/sed 's/^0*//; s/^$/0/')"
}

parse_apply_request() {
    local vendor_id="$1"
    local product_id="$2"
    local native_resolution="$3"
    local vendor_decimal
    local product_decimal

    vendor_id="$(normalize_hex_id "$vendor_id")" || return 1
    product_id="$(normalize_hex_id "$product_id")" || return 1
    vendor_decimal="$(decimal_from_hex "$vendor_id")" || return 1
    product_decimal="$(decimal_from_hex "$product_id")" || return 1
    parse_resolution "$native_resolution" >/dev/null || return 1
    printf '%s|%s|%s|%s\n' "$vendor_id" "$product_id" "$vendor_decimal" "$product_decimal"
}

path_for_display() {
    local root="$1"
    local vendor_id="$2"
    local product_id="$3"

    printf '%s/DisplayVendorID-%s/DisplayProductID-%s\n' "$root" "$vendor_id" "$product_id"
}

target_lock_path() {
    local overrides_root="$1"
    local vendor_id="$2"
    local product_id="$3"

    [[ "$overrides_root" == /* ]] || return 1
    [[ "$vendor_id" =~ ^[0-9a-f]+$ && "$product_id" =~ ^[0-9a-f]+$ ]] || return 1
    printf '%s/.one-key-hidpi-locks/DisplayVendorID-%s-DisplayProductID-%s.lock\n' \
        "$overrides_root" "$vendor_id" "$product_id"
}

state_dir_for_display() {
    local state_root="$1"
    local vendor_id="$2"
    local product_id="$3"

    printf '%s/DisplayVendorID-%s/DisplayProductID-%s\n' "$state_root" "$vendor_id" "$product_id"
}

create_temporary_file() {
    local label="${1:-}"
    local temporary_snapshot
    local temporary_hash
    local temporary_identity
    local temporary_index

    [[ $# -eq 1 && -n "$label" && "$label" != */* && "$label" != *$'\n'* && "$label" != *$'\r'* ]] || return 1
    [[ -n "$OPERATION_TEMPORARY_DIRECTORY" && -d "$OPERATION_TEMPORARY_DIRECTORY" && ! -L "$OPERATION_TEMPORARY_DIRECTORY" ]] || return 1
    TEMPORARY_FILE="$(/usr/bin/mktemp "${OPERATION_TEMPORARY_DIRECTORY}/.${label}.XXXXXX")" || return 1
    TEMPORARY_FILES+=("$TEMPORARY_FILE")
    TEMPORARY_FILE_HASHES+=("")
    TEMPORARY_FILE_IDENTITIES+=("")
    temporary_index=$((${#TEMPORARY_FILES[@]} - 1))
    temporary_snapshot="$(darwin_file_snapshot "$TEMPORARY_FILE")" || return 1
    IFS='|' read -r temporary_hash temporary_identity <<< "$temporary_snapshot"
    valid_sha256 "$temporary_hash" || return 1
    valid_file_identity "$temporary_identity" || return 1
    TEMPORARY_FILE_HASHES[temporary_index]="$temporary_hash"
    TEMPORARY_FILE_IDENTITIES[temporary_index]="$temporary_identity"
}

create_operation_temporary_directory() {
    [[ -z "$OPERATION_TEMPORARY_DIRECTORY" ]] || return 1
    OPERATION_TEMPORARY_DIRECTORY="$(umask 077; /usr/bin/mktemp -d "/private/tmp/one-key-hidpi-operation.XXXXXX")" || return 1
    OPERATION_TEMPORARY_DIRECTORY_IDENTITY="$(darwin_directory_identity "$OPERATION_TEMPORARY_DIRECTORY")" || return 1
    valid_file_identity "$OPERATION_TEMPORARY_DIRECTORY_IDENTITY"
}

record_temporary_file_snapshot() {
    local path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local index

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    file_matches_snapshot "$path" "$expected_hash" "$expected_identity" || return 1
    for ((index = ${#TEMPORARY_FILES[@]} - 1; index >= 0; index--)); do
        if [[ "${TEMPORARY_FILES[$index]}" == "$path" ]]; then
            TEMPORARY_FILE_HASHES[index]="$expected_hash"
            TEMPORARY_FILE_IDENTITIES[index]="$expected_identity"
            return 0
        fi
    done
    return 1
}

temporary_file_expected_hash() {
    local path="$1"
    local index

    for ((index = ${#TEMPORARY_FILES[@]} - 1; index >= 0; index--)); do
        if [[ "${TEMPORARY_FILES[$index]}" == "$path" ]]; then
            printf '%s\n' "${TEMPORARY_FILE_HASHES[$index]}"
            return 0
        fi
    done
    return 1
}

temporary_file_expected_identity() {
    local path="$1"
    local index

    for ((index = ${#TEMPORARY_FILES[@]} - 1; index >= 0; index--)); do
        if [[ "${TEMPORARY_FILES[$index]}" == "$path" ]]; then
            printf '%s\n' "${TEMPORARY_FILE_IDENTITIES[$index]}"
            return 0
        fi
    done
    return 1
}

directory_is_empty() {
    local directory="$1"
    local first_entry

    [[ ! -e "$directory" && ! -L "$directory" ]] && return 0
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    first_entry="$(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" || return 1
    [[ -z "$first_entry" ]]
}

require_root_for_system_paths() {
    local overrides_root="$1"
    local state_root="$2"

    if is_system_overrides_root "$overrides_root" || is_system_state_root "$state_root"; then
        ((EUID == 0)) || fail "writing default system paths requires root; rerun explicitly with sudo"
    fi
}

is_system_overrides_root() {
    local path="$1"

    [[ "$path" == "$DEFAULT_OVERRIDES_ROOT" || "$path" == "/System/Volumes/Data${DEFAULT_OVERRIDES_ROOT}" ]]
}

is_system_state_root() {
    local path="$1"

    [[ "$path" == "$DEFAULT_STATE_ROOT" || "$path" == "/System/Volumes/Data${DEFAULT_STATE_ROOT}" ]]
}

storage_roots_have_matching_trust() {
    local overrides_root="$1"
    local state_root="$2"
    local overrides_are_system=false
    local state_is_system=false

    is_system_overrides_root "$overrides_root" && overrides_are_system=true
    is_system_state_root "$state_root" && state_is_system=true
    [[ "$overrides_are_system" == "$state_is_system" ]]
}

reset_operation_cleanup_state() {
    TEMPORARY_FILES=("")
    TEMPORARY_FILE_HASHES=("")
    TEMPORARY_FILE_IDENTITIES=("")
    TEMPORARY_FILE=""
    OPERATION_TEMPORARY_DIRECTORY=""
    OPERATION_TEMPORARY_DIRECTORY_IDENTITY=""
    OPERATION_LOCK_PATH=""
    OPERATION_LOCK_HASH=""
    OPERATION_LOCK_IDENTITY=""
    PLIST_OPERATION_HASH=""
    PLIST_OPERATION_IDENTITY=""
}

complete_operation_cleanup() {
    local cleanup_status=0

    cleanup_temporary_files || cleanup_status=1
    release_display_lock || cleanup_status=1
    if [[ -n "$OPERATION_TEMPORARY_DIRECTORY" ]]; then
        valid_file_identity "$OPERATION_TEMPORARY_DIRECTORY_IDENTITY" &&
            darwin_remove_empty_directory_if_unchanged "$OPERATION_TEMPORARY_DIRECTORY" "$OPERATION_TEMPORARY_DIRECTORY_IDENTITY" || cleanup_status=1
    fi
    ((cleanup_status == 0)) || return "$cleanup_status"
    reset_operation_cleanup_state
    return "$cleanup_status"
}

set_written_file_permissions() {
    local path="$1"
    local system_path="$2"
    local expected_hash="$3"
    local expected_identity="$4"
    local owner_id=""
    local group_id=""
    local updated_snapshot
    local updated_hash
    local updated_identity

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    if [[ "$system_path" == true ]]; then
        owner_id=0
        group_id=0
    fi
    updated_snapshot="$(darwin_set_file_metadata "$path" "$expected_hash" "$expected_identity" "0644" "$owner_id" "$group_id")" || return 1
    IFS='|' read -r updated_hash updated_identity <<< "$updated_snapshot"
    valid_sha256 "$updated_hash" || return 1
    valid_file_identity "$updated_identity" || return 1
    PLIST_OPERATION_HASH="$updated_hash"
    PLIST_OPERATION_IDENTITY="$updated_identity"
}

valid_sha256() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

valid_file_identity() {
    [[ "$1" =~ ^[0-9]+:[0-9]+$ ]]
}

valid_persistent_file_identity() {
    [[ "$1" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]
}

current_boot_session() {
    local boot_time

    boot_time="$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null)" || return 1
    [[ "$boot_time" =~ sec[[:space:]]*=[[:space:]]*([0-9]+),[[:space:]]*usec[[:space:]]*=[[:space:]]*([0-9]+) ]] || return 1
    printf '%s:%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

file_matches_hash() {
    local path="$1"
    local expected_hash="$2"
    local current_hash

    valid_sha256 "$expected_hash" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    current_hash="$(sha256_file "$path")" || return 1
    [[ "$current_hash" == "$expected_hash" ]]
}

file_matches_snapshot() {
    local path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local snapshot
    local current_hash
    local current_identity

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    snapshot="$(darwin_file_snapshot "$path")" || return 1
    IFS='|' read -r current_hash current_identity <<< "$snapshot"
    [[ "$current_hash" == "$expected_hash" && "$current_identity" == "$expected_identity" ]]
}

file_matches_persistent_snapshot() {
    local path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local expected_persistent_identity="$4"
    local snapshot
    local current_hash
    local current_identity
    local current_persistent_identity

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    valid_persistent_file_identity "$expected_persistent_identity" || return 1
    snapshot="$(darwin_file_persistent_snapshot "$path")" || return 1
    IFS='|' read -r current_hash current_identity current_persistent_identity <<< "$snapshot"
    [[ "$current_hash" == "$expected_hash" && "$current_identity" == "$expected_identity" && "$current_persistent_identity" == "$expected_persistent_identity" ]]
}

legacy_file_identity_matches_inode() {
    local expected_identity="$1"
    local current_identity="$2"

    valid_file_identity "$expected_identity" || return 1
    valid_file_identity "$current_identity" || return 1
    [[ "${expected_identity#*:}" == "${current_identity#*:}" ]]
}

run_plutil_and_update_hash() {
    local plist_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local updated_snapshot
    local updated_hash
    local updated_identity

    shift 3
    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    updated_snapshot="$(darwin_plutil_file "$plist_path" "$expected_hash" "$expected_identity" "$@")" || return 1
    IFS='|' read -r updated_hash updated_identity <<< "$updated_snapshot"
    valid_sha256 "$updated_hash" || return 1
    valid_file_identity "$updated_identity" || return 1
    PLIST_OPERATION_HASH="$updated_hash"
    PLIST_OPERATION_IDENTITY="$updated_identity"
}

plist_file_is_valid() {
    local plist_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    darwin_read_plist_file "$plist_path" "$expected_hash" "$expected_identity" -lint >/dev/null
}

plist_raw_value() {
    local plist_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local key_path="$4"
    local expected_type="$5"

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    darwin_read_plist_file "$plist_path" "$expected_hash" "$expected_identity" \
        -extract "$key_path" raw -expect "$expected_type" -o -
}

plist_type() {
    local plist_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local key_path="$4"

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    darwin_read_plist_file "$plist_path" "$expected_hash" "$expected_identity" -type "$key_path"
}

verified_scale_payloads_from_override() {
    local override_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local payload_xml

    payload_xml="$(darwin_read_plist_file "$override_path" "$expected_hash" "$expected_identity" \
        -extract scale-resolutions xml1 -expect array -o -)" || return 1
    printf '%s\n' "$payload_xml" | /usr/bin/perl -0ne '
        while (m{<data>(.*?)</data>}sg) {
            $value = $1;
            $value =~ s/\s+//g;
            print "$value\n" if length $value;
        }
    '
}

payloads_for_resolution() {
    local native_resolution="$1"
    local framebuffer_limit="$2"
    local mode_set="${3:-$MODE_SET_PRESET}"
    local include_near_native="${4:-false}"
    local preview_output

    preview_output="$(preview "$native_resolution" "$framebuffer_limit" "$mode_set" "$include_near_native")" || return 1
    printf '%s\n' "$preview_output" | /usr/bin/sed -n 's/.* payload=\([A-Za-z0-9+\/]*=*\)$/\1/p'
}

ensure_scale_resolutions_array() {
    local candidate_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local existing_type

    file_matches_snapshot "$candidate_path" "$expected_hash" "$expected_identity" || return 1
    if existing_type="$(plist_type "$candidate_path" "$expected_hash" "$expected_identity" scale-resolutions)"; then
        [[ "$existing_type" == array ]] || return 1
        PLIST_OPERATION_HASH="$expected_hash"
        PLIST_OPERATION_IDENTITY="$expected_identity"
        return 0
    fi
    plist_file_is_valid "$candidate_path" "$expected_hash" "$expected_identity" || return 1
    run_plutil_and_update_hash "$candidate_path" "$expected_hash" "$expected_identity" -insert scale-resolutions -array
}

append_missing_payloads() {
    local candidate_path="$1"
    local generated_payloads="$2"
    local expected_hash="$3"
    local expected_identity="$4"
    local payload
    local existing_payloads
    local payload_count
    local current_hash="$expected_hash"
    local current_identity="$expected_identity"

    [[ -n "$generated_payloads" ]] || return 1
    ensure_scale_resolutions_array "$candidate_path" "$current_hash" "$current_identity" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    file_matches_snapshot "$candidate_path" "$current_hash" "$current_identity" || return 1
    existing_payloads="$(verified_scale_payloads_from_override "$candidate_path" "$current_hash" "$current_identity")" || return 1
    payload_count="$(plist_raw_value "$candidate_path" "$current_hash" "$current_identity" scale-resolutions array)" || return 1

    while IFS= read -r payload; do
        [[ -n "$payload" ]] || continue
        if ! printf '%s\n' "$existing_payloads" | /usr/bin/grep -Fqx "$payload"; then
            run_plutil_and_update_hash "$candidate_path" "$current_hash" "$current_identity" -insert "scale-resolutions.${payload_count}" -data "$payload" || return 1
            current_hash="$PLIST_OPERATION_HASH"
            current_identity="$PLIST_OPERATION_IDENTITY"
            existing_payloads="${existing_payloads}${existing_payloads:+$'\n'}${payload}"
            payload_count=$((payload_count + 1))
        fi
    done <<< "$generated_payloads"
    PLIST_OPERATION_HASH="$current_hash"
    PLIST_OPERATION_IDENTITY="$current_identity"
}

create_base_override() {
    local target_path="$1"
    local vendor_decimal="$2"
    local product_decimal="$3"
    local expected_hash="$4"
    local expected_identity="$5"
    local current_hash="$expected_hash"
    local current_identity="$expected_identity"

    run_plutil_and_update_hash "$target_path" "$current_hash" "$current_identity" -create xml1 || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$target_path" "$current_hash" "$current_identity" -insert DisplayVendorID -integer "$vendor_decimal" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$target_path" "$current_hash" "$current_identity" -insert DisplayProductID -integer "$product_decimal" || return 1
    current_hash="$PLIST_OPERATION_HASH"
    current_identity="$PLIST_OPERATION_IDENTITY"
    run_plutil_and_update_hash "$target_path" "$current_hash" "$current_identity" -insert scale-resolutions -array || return 1
}

validate_candidate_override() {
    local candidate_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local vendor_decimal="$4"
    local product_decimal="$5"
    local payload_count

    plist_file_is_valid "$candidate_path" "$expected_hash" "$expected_identity" || return 1
    [[ "$(plist_raw_value "$candidate_path" "$expected_hash" "$expected_identity" DisplayVendorID integer)" == "$vendor_decimal" ]] || return 1
    [[ "$(plist_raw_value "$candidate_path" "$expected_hash" "$expected_identity" DisplayProductID integer)" == "$product_decimal" ]] || return 1
    payload_count="$(plist_raw_value "$candidate_path" "$expected_hash" "$expected_identity" scale-resolutions array)" || return 1
    [[ "$payload_count" =~ ^[1-9][0-9]*$ ]]
}

sha256_file() {
    darwin_sha256_file "$1"
}

target_matches_pre_apply_state() {
    local target_path="$1"
    local target_existed="$2"
    local original_hash="$3"
    local original_identity="$4"
    local original_persistent_identity="${5:-}"

    if [[ "$target_existed" == true ]]; then
        valid_persistent_file_identity "$original_persistent_identity" || return 1
        file_matches_persistent_snapshot "$target_path" "$original_hash" "$original_identity" "$original_persistent_identity"
        return
    fi
    [[ "$target_existed" == false ]] || return 1
    [[ ! -e "$target_path" && ! -L "$target_path" ]]
}

install_file_without_replacement() {
    local candidate_path="$1"
    local target_path="$2"
    local expected_hash="${3:-}"
    local expected_identity="${4:-}"

    [[ -f "$candidate_path" && ! -L "$candidate_path" ]] || return 1
    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    darwin_install_file_without_replacement "$candidate_path" "$target_path" "$expected_hash" "$expected_identity"
}

install_file_without_replacement_persistent() {
    local candidate_path="$1"
    local target_path="$2"
    local expected_hash="${3:-}"
    local expected_identity="${4:-}"

    [[ -f "$candidate_path" && ! -L "$candidate_path" ]] || return 1
    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    darwin_install_file_without_replacement_persistent "$candidate_path" "$target_path" "$expected_hash" "$expected_identity"
}

install_file_without_replacement_persistent_source() {
    local candidate_path="$1"
    local target_path="$2"
    local expected_hash="$3"
    local expected_identity="$4"
    local expected_persistent_identity="$5"

    [[ -f "$candidate_path" && ! -L "$candidate_path" ]] || return 1
    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    valid_persistent_file_identity "$expected_persistent_identity" || return 1
    darwin_install_file_without_replacement_persistent_source "$candidate_path" "$target_path" "$expected_hash" "$expected_identity" "$expected_persistent_identity"
}

replace_file_without_following_directory_link() {
    local candidate_path="$1"
    local target_path="$2"
    local expected_candidate_hash="$3"
    local expected_candidate_identity="$4"
    local expected_target_hash="$5"
    local expected_target_identity="$6"
    valid_sha256 "$expected_candidate_hash" || return 1
    valid_file_identity "$expected_candidate_identity" || return 1
    valid_sha256 "$expected_target_hash" || return 1
    valid_file_identity "$expected_target_identity" || return 1
    darwin_replace_file "$candidate_path" "$target_path" "$expected_candidate_hash" "$expected_candidate_identity" "$expected_target_hash" "$expected_target_identity"
}

replace_file_without_following_directory_link_persistent() {
    local candidate_path="$1"
    local target_path="$2"
    local expected_candidate_hash="$3"
    local expected_candidate_identity="$4"
    local expected_target_hash="$5"
    local expected_target_identity="$6"
    local expected_target_persistent_identity="$7"

    valid_sha256 "$expected_candidate_hash" || return 1
    valid_file_identity "$expected_candidate_identity" || return 1
    valid_sha256 "$expected_target_hash" || return 1
    valid_file_identity "$expected_target_identity" || return 1
    valid_persistent_file_identity "$expected_target_persistent_identity" || return 1
    darwin_replace_file_persistent "$candidate_path" "$target_path" "$expected_candidate_hash" "$expected_candidate_identity" "$expected_target_hash" "$expected_target_identity" "$expected_target_persistent_identity"
}

copy_file_and_verify_hash() {
    local source_path="$1"
    local candidate_path="$2"
    local expected_hash="$3"
    local expected_source_identity="$4"
    local expected_source_persistent_identity="${5:-}"
    local temporary_hash
    local temporary_identity
    local installed_snapshot
    local installed_hash
    local installed_identity

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_source_identity" || return 1
    valid_persistent_file_identity "$expected_source_persistent_identity" || return 1
    [[ -f "$source_path" && ! -L "$source_path" ]] || return 1
    temporary_hash="$(temporary_file_expected_hash "$candidate_path")" || return 1
    temporary_identity="$(temporary_file_expected_identity "$candidate_path")" || return 1
    valid_sha256 "$temporary_hash" || return 1
    valid_file_identity "$temporary_identity" || return 1
    remove_file_if_unchanged "$candidate_path" "$temporary_hash" "$temporary_identity" || return 1
    installed_snapshot="$(install_file_without_replacement_persistent_source "$source_path" "$candidate_path" "$expected_hash" "$expected_source_identity" "$expected_source_persistent_identity")" || return 1
    IFS='|' read -r installed_hash installed_identity <<< "$installed_snapshot"
    [[ "$installed_hash" == "$expected_hash" ]] || return 1
    valid_file_identity "$installed_identity" || return 1
    file_matches_snapshot "$candidate_path" "$expected_hash" "$installed_identity" || return 1
    record_temporary_file_snapshot "$candidate_path" "$expected_hash" "$installed_identity"
}

remove_file_if_unchanged() {
    local target_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    darwin_remove_file_if_unchanged "$target_path" "$expected_hash" "$expected_identity" || return 1
    [[ ! -e "$target_path" && ! -L "$target_path" ]]
}

remove_file_if_unchanged_persistent() {
    local target_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"
    local expected_persistent_identity="$4"

    valid_sha256 "$expected_hash" || return 1
    valid_file_identity "$expected_identity" || return 1
    valid_persistent_file_identity "$expected_persistent_identity" || return 1
    darwin_remove_file_if_unchanged_persistent "$target_path" "$expected_hash" "$expected_identity" "$expected_persistent_identity" || return 1
    [[ ! -e "$target_path" && ! -L "$target_path" ]]
}
