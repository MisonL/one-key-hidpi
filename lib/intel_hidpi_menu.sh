# The caller defines localization variables before sourcing this library.
# shellcheck disable=SC2154
intel_safe_hidpi_has_root_privilege() {
    ((EUID == 0))
}

intel_safe_hidpi() {
    local tool_path="$1"
    local edid="$2"
    local vendor_id="$3"
    local product_id="$4"
    local native_resolution
    local action
    local confirmation
    local mode_set
    local include_near_native=false
    local mode_choice
    local near_native_choice
    local mode_arguments=()

    [[ -f "$tool_path" ]] || {
        echo "$langIntelSafeToolMissing"
        return 1
    }

    native_resolution="$(/bin/bash "$tool_path" native-resolution --edid "$edid")" || return 1
    echo ""
    printf "%s: %s\n" "$langIntelSafeTitle" "$native_resolution"
    echo "$langIntelSafeModePreset"
    echo "$langIntelSafeModeSmooth"
    echo "$langIntelSafeCancel"
    echo ""
    read -r -p "${langInputChoice} [1~3]: " mode_choice

    case "$mode_choice" in
    1)
        mode_set="preset"
        ;;
    2)
        mode_set="smooth"
        echo "$langIntelSafeNearNative"
        echo "$langIntelSafeNearNativeNo"
        echo "$langIntelSafeNearNativeYes"
        echo ""
        read -r -p "${langInputChoice} [1~2]: " near_native_choice
        case "$near_native_choice" in
        1)
            ;;
        2)
            include_near_native=true
            ;;
        *)
            echo "$langEnterError"
            return 1
            ;;
        esac
        ;;
    3)
        echo "$langIntelSafeCancelled"
        return 0
        ;;
    *)
        echo "$langEnterError"
        return 1
        ;;
    esac

    mode_arguments=(--mode-set "$mode_set")
    if [[ "$include_near_native" == true ]]; then
        mode_arguments+=(--include-near-native)
    fi
    /bin/bash "$tool_path" preview --native-resolution "$native_resolution" "${mode_arguments[@]}" || return 1

    echo ""
    echo "$langIntelSafeApply"
    echo "$langIntelSafeRevert"
    echo "$langIntelSafeCancel"
    echo ""
    read -r -p "${langInputChoice} [1~3]: " action

    case "$action" in
    1)
        if ! intel_safe_hidpi_has_root_privilege; then
            echo "$langIntelSafeRoot"
            return 1
        fi
        read -r -p "${langIntelSafeApplyConfirm}: " confirmation
        [[ "$confirmation" == "APPLY" ]] || {
            echo "$langIntelSafeCancelled"
            return 0
        }
        /bin/bash "$tool_path" apply --vendor-id "$vendor_id" --product-id "$product_id" --native-resolution "$native_resolution" "${mode_arguments[@]}" --confirm
        ;;
    2)
        if ! intel_safe_hidpi_has_root_privilege; then
            echo "$langIntelSafeRoot"
            return 1
        fi
        read -r -p "${langIntelSafeRevertConfirm}: " confirmation
        [[ "$confirmation" == "REVERT" ]] || {
            echo "$langIntelSafeCancelled"
            return 0
        }
        /bin/bash "$tool_path" revert --vendor-id "$vendor_id" --product-id "$product_id" --confirm
        ;;
    3)
        echo "$langIntelSafeCancelled"
        ;;
    *)
        echo "$langEnterError"
        return 1
        ;;
    esac
}
