# The caller defines localization variables before sourcing this library.
# shellcheck disable=SC2154
intel_safe_hidpi() {
    local tool_path="$1"
    local edid="$2"
    local vendor_id="$3"
    local product_id="$4"
    local native_resolution
    local action
    local confirmation

    [[ -f "$tool_path" ]] || {
        echo "$langIntelSafeToolMissing"
        return 1
    }

    native_resolution="$(/bin/bash "$tool_path" native-resolution --edid "$edid")" || return 1
    echo ""
    printf "%s: %s\n" "$langIntelSafeTitle" "$native_resolution"
    /bin/bash "$tool_path" preview --native-resolution "$native_resolution" || return 1

    echo ""
    echo "$langIntelSafeApply"
    echo "$langIntelSafeRevert"
    echo "$langIntelSafeCancel"
    echo ""
    read -r -p "${langInputChoice} [1~3]: " action

    case "$action" in
    1)
        if ((EUID != 0)); then
            echo "$langIntelSafeRoot"
            return 1
        fi
        read -r -p "${langIntelSafeApplyConfirm}: " confirmation
        [[ "$confirmation" == "APPLY" ]] || {
            echo "$langIntelSafeCancelled"
            return 0
        }
        /bin/bash "$tool_path" apply --vendor-id "$vendor_id" --product-id "$product_id" --native-resolution "$native_resolution" --confirm
        ;;
    2)
        if ((EUID != 0)); then
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
