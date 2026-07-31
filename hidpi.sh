#!/bin/bash

set -u
set -o pipefail

[[ ! -L "${BASH_SOURCE[0]}" ]] || {
    printf '%s\n' 'error: Intel safe HiDPI requires a regular local checkout entrypoint' >&2
    exit 1
}

SCRIPT_DIR="$(builtin cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd)" || {
    printf '%s\n' 'error: could not resolve the local checkout directory' >&2
    exit 1
}
readonly SCRIPT_DIR

INTEL_TOOL_PATH="${SCRIPT_DIR}/intel-hidpi.sh"
INTEL_MENU_PATH="${SCRIPT_DIR}/lib/intel_hidpi_menu.sh"
readonly INTEL_TOOL_PATH
readonly INTEL_MENU_PATH

langInputChoice="Enter your choice"
langEnterError="Invalid selection"
langNoMonitFound="No valid external display was found"
langIntelSafeTitle="Intel safe HiDPI"
langIntelSafeModePreset="(1) Compatibility preset modes"
langIntelSafeModeSmooth="(2) Smooth HiDPI modes"
langIntelSafeNearNative="Add a near-native compatibility mode?"
langIntelSafeNearNativeNo="(1) No"
langIntelSafeNearNativeYes="(2) Yes"
langIntelSafeSimilarResolutions="Add BetterDisplay-compatible similar resolutions?"
langIntelSafeSimilarResolutionsNo="(1) No"
langIntelSafeSimilarResolutionsYes="(2) Yes"
langIntelSafeApply="(1) Apply generated modes"
langIntelSafeRevert="(2) Revert generated modes"
langIntelSafeCancel="(3) Cancel"
langIntelSafeRoot="Run this script as root to change the selected display."
langIntelSafeApplyConfirm="Type APPLY to write the selected display override"
langIntelSafeRevertConfirm="Type REVERT to remove this tool's selected display override"
langIntelSafeCancelled="Cancelled"
langIntelSafeToolMissing="Intel safe HiDPI tool is missing."
langIntelSafeDisplays="Detected display records"
langIntelSafeDisplayHeader="Index | Vendor ID | Product ID | Native resolution"
langIntelSafeChooseDisplay="Choose the display"
langIntelSafeInvalidEdid="Ignoring an invalid display EDID record."
langIntelSafeAmbiguousTarget="Multiple display records share one override target."

if [[ "${LANG:-}" == zh_CN* || "${LC_ALL:-}" == zh_CN* || "${LC_MESSAGES:-}" == zh_CN* ]]; then
    langInputChoice="输入你的选择"
    langEnterError="输入无效"
    langNoMonitFound="没有找到有效的外接显示器"
    langIntelSafeTitle="Intel 安全 HiDPI"
    langIntelSafeModePreset="(1) 兼容预设模式"
    langIntelSafeModeSmooth="(2) 平滑 HiDPI 模式"
    langIntelSafeNearNative="是否加入近原生兼容模式？"
    langIntelSafeNearNativeNo="(1) 否"
    langIntelSafeNearNativeYes="(2) 是"
    langIntelSafeSimilarResolutions="是否加入与 BetterDisplay 兼容的相似分辨率？"
    langIntelSafeSimilarResolutionsNo="(1) 否"
    langIntelSafeSimilarResolutionsYes="(2) 是"
    langIntelSafeApply="(1) 应用生成的模式"
    langIntelSafeRevert="(2) 回退本工具生成的模式"
    langIntelSafeCancel="(3) 取消"
    langIntelSafeRoot="请以 root 身份运行此脚本后再修改当前显示器。"
    langIntelSafeApplyConfirm="输入 APPLY 以写入当前显示器 override"
    langIntelSafeRevertConfirm="输入 REVERT 以移除本工具对当前显示器的 override"
    langIntelSafeCancelled="已取消"
    langIntelSafeToolMissing="未找到 Intel 安全 HiDPI 工具。"
    langIntelSafeDisplays="检测到的显示器记录"
    langIntelSafeDisplayHeader="序号 | 厂商 ID | 产品 ID | 原生分辨率"
    langIntelSafeChooseDisplay="选择显示器"
    langIntelSafeInvalidEdid="已忽略无效的显示器 EDID 记录。"
    langIntelSafeAmbiguousTarget="多个显示器记录共享同一个 override 目标。"
fi

SAFE_ENTRYPOINT_EDIDS=()
SAFE_ENTRYPOINT_VENDOR_IDS=()
SAFE_ENTRYPOINT_PRODUCT_IDS=()
SAFE_ENTRYPOINT_NATIVE_RESOLUTIONS=()

require_complete_local_checkout() {
    local required_path

    [[ -d "${SCRIPT_DIR}/lib" && ! -L "${SCRIPT_DIR}/lib" ]] || {
        printf '%s\n' 'error: Intel safe HiDPI requires a complete local checkout' >&2
        return 1
    }

    for required_path in \
        "$INTEL_TOOL_PATH" \
        "$INTEL_MENU_PATH" \
        "${SCRIPT_DIR}/lib/intel_hidpi_storage.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_storage_support.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_mode_configuration.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_darwin_fs.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_manifest.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_verify_modes.sh" \
        "${SCRIPT_DIR}/lib/intel_hidpi_runtime_modes.swift"; do
        [[ -f "$required_path" && ! -L "$required_path" && -r "$required_path" ]] || {
            printf '%s\n' 'error: Intel safe HiDPI requires a complete local checkout' >&2
            return 1
        }
    done

    /bin/bash "$INTEL_TOOL_PATH" --help >/dev/null 2>&1 || {
        printf '%s\n' 'error: Intel safe HiDPI requires a complete local checkout' >&2
        return 1
    }
}

require_complete_local_checkout || exit 1
# shellcheck source=lib/intel_hidpi_menu.sh
source "$INTEL_MENU_PATH" || {
    printf '%s\n' 'error: could not load the Intel safe HiDPI menu' >&2
    exit 1
}

safe_entrypoint_normalize_hex_id() {
    local raw_value="$1"
    local allow_zero="${2:-false}"
    local decimal_value

    [[ "$raw_value" =~ ^[0-9A-Fa-f]{4}$ ]] || return 1
    decimal_value=$((16#$raw_value))
    if ((decimal_value == 0)) && [[ "$allow_zero" != true ]]; then
        return 1
    fi
    printf '%x\n' "$decimal_value"
}

safe_entrypoint_record_from_edid() {
    local raw_edid="$1"
    local normalized_edid
    local native_resolution
    local vendor_id
    local product_id

    normalized_edid="$(printf '%s' "$raw_edid" | LC_ALL=C /usr/bin/tr '[:upper:]' '[:lower:]')" || return 1
    [[ "$normalized_edid" =~ ^[0-9a-f]+$ ]] || return 1
    native_resolution="$(/bin/bash "$INTEL_TOOL_PATH" native-resolution --edid "$normalized_edid" 2>/dev/null)" || return 1
    [[ "$native_resolution" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || return 1
    vendor_id="$(safe_entrypoint_normalize_hex_id "${normalized_edid:16:4}")" || return 1
    product_id="$(safe_entrypoint_normalize_hex_id "${normalized_edid:22:2}${normalized_edid:20:2}" true)" || return 1

    printf '%s|%s|%s|%s\n' "$normalized_edid" "$vendor_id" "$product_id" "$native_resolution"
}

safe_entrypoint_read_ioreg() {
    /usr/sbin/ioreg -lw0
}

safe_entrypoint_collect_display_records() {
    local ioreg_output
    local edid_lines
    local raw_edid
    local display_record
    local normalized_edid
    local vendor_id
    local product_id
    local native_resolution
    local seen_edids=""
    local seen_targets=""

    SAFE_ENTRYPOINT_EDIDS=()
    SAFE_ENTRYPOINT_VENDOR_IDS=()
    SAFE_ENTRYPOINT_PRODUCT_IDS=()
    SAFE_ENTRYPOINT_NATIVE_RESOLUTIONS=()

    ioreg_output="$(safe_entrypoint_read_ioreg)" || {
        printf '%s\n' 'error: could not read IODisplayEDID from ioreg' >&2
        return 1
    }
    edid_lines="$(printf '%s\n' "$ioreg_output" | /usr/bin/sed -n 's/.*"IODisplayEDID" = <\([0-9A-Fa-f][0-9A-Fa-f]*\)>.*/\1/p')" || return 1

    while IFS= read -r raw_edid; do
        [[ -n "$raw_edid" ]] || continue
        display_record="$(safe_entrypoint_record_from_edid "$raw_edid")" || {
            printf '%s\n' "$langIntelSafeInvalidEdid" >&2
            continue
        }
        IFS='|' read -r normalized_edid vendor_id product_id native_resolution <<< "$display_record"
        case ":${seen_edids}:" in
        *":${normalized_edid}:"*)
            continue
            ;;
        esac
        case ":${seen_targets}:" in
        *":${vendor_id}-${product_id}:"*)
            printf '%s\n' "$langIntelSafeAmbiguousTarget" >&2
            return 1
            ;;
        esac
        seen_edids="${seen_edids}:${normalized_edid}"
        seen_targets="${seen_targets}:${vendor_id}-${product_id}"
        SAFE_ENTRYPOINT_EDIDS+=("$normalized_edid")
        SAFE_ENTRYPOINT_VENDOR_IDS+=("$vendor_id")
        SAFE_ENTRYPOINT_PRODUCT_IDS+=("$product_id")
        SAFE_ENTRYPOINT_NATIVE_RESOLUTIONS+=("$native_resolution")
    done <<< "$edid_lines"

    if ((${#SAFE_ENTRYPOINT_EDIDS[@]} == 0)); then
        printf '%s\n' "$langNoMonitFound" >&2
        return 1
    fi
}

safe_entrypoint_print_display_choices() {
    local index

    printf '\n%s\n' "$langIntelSafeDisplays"
    printf '%s\n' "$langIntelSafeDisplayHeader"
    for ((index = 0; index < ${#SAFE_ENTRYPOINT_EDIDS[@]}; index++)); do
        printf '%d | 0x%s | 0x%s | %s\n' \
            "$((index + 1))" \
            "${SAFE_ENTRYPOINT_VENDOR_IDS[$index]}" \
            "${SAFE_ENTRYPOINT_PRODUCT_IDS[$index]}" \
            "${SAFE_ENTRYPOINT_NATIVE_RESOLUTIONS[$index]}"
    done
}

safe_entrypoint_decimal_at_most() {
    local value="$1"
    local limit="$2"
    local index
    local value_digit
    local limit_digit

    [[ "$value" =~ ^[1-9][0-9]*$ && "$limit" =~ ^[1-9][0-9]*$ ]] || return 1
    if ((${#value} < ${#limit})); then
        return 0
    fi
    if ((${#value} > ${#limit})); then
        return 1
    fi

    for ((index = 0; index < ${#value}; index++)); do
        value_digit="${value:index:1}"
        limit_digit="${limit:index:1}"
        [[ "$value_digit" == "$limit_digit" ]] && continue
        if ((value_digit < limit_digit)); then
            return 0
        fi
        return 1
    done

    return 0
}

safe_entrypoint_select_display() {
    local display_count
    local selected_index=0
    local selection

    safe_entrypoint_collect_display_records || return 1
    display_count="${#SAFE_ENTRYPOINT_EDIDS[@]}"

    if ((display_count > 1)); then
        safe_entrypoint_print_display_choices
        read -r -p "${langIntelSafeChooseDisplay} [1~${display_count}]: " selection || {
            printf '%s\n' "$langEnterError" >&2
            return 1
        }
        if ! safe_entrypoint_decimal_at_most "$selection" "$display_count"; then
            printf '%s\n' "$langEnterError" >&2
            return 1
        fi
        selected_index=$((selection - 1))
    fi

    EDID="${SAFE_ENTRYPOINT_EDIDS[$selected_index]}"
    Vid="${SAFE_ENTRYPOINT_VENDOR_IDS[$selected_index]}"
    Pid="${SAFE_ENTRYPOINT_PRODUCT_IDS[$selected_index]}"
}

start() {
    safe_entrypoint_select_display || return 1
    intel_safe_hidpi "$INTEL_TOOL_PATH" "$EDID" "$Vid" "$Pid"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    start
fi
