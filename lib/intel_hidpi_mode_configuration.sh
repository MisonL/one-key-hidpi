# shellcheck shell=bash
# shellcheck disable=SC2034
readonly MODE_SET_PRESET="preset"
readonly MODE_SET_SMOOTH="smooth"
readonly SMOOTH_LOWER_NUMERATOR=2
readonly SMOOTH_LOWER_DENOMINATOR=3
readonly SMOOTH_MAX_MODE_COUNT=41

validate_mode_configuration() {
    local mode_set="$1"
    local include_near_native="$2"

    case "$mode_set" in
    "$MODE_SET_PRESET"|"$MODE_SET_SMOOTH")
        ;;
    *)
        return 1
        ;;
    esac
    [[ "$include_near_native" == true || "$include_near_native" == false ]] || return 1
    [[ "$include_near_native" == false || "$mode_set" == "$MODE_SET_SMOOTH" ]]
}
