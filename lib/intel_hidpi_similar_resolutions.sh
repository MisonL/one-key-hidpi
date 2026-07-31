# shellcheck shell=bash

readonly MAX_RESOLUTION_PAYLOAD_DIMENSION=4294967295

resolution_payload_dimensions_are_valid() {
    local width="$1"
    local height="$2"
    local maximum="$MAX_RESOLUTION_PAYLOAD_DIMENSION"
    local width_digits
    local height_digits
    local maximum_digits

    [[ "$width" =~ ^[1-9][0-9]*$ && "$height" =~ ^[1-9][0-9]*$ ]] || return 1
    width_digits="${#width}"
    height_digits="${#height}"
    maximum_digits="${#maximum}"
    if ((width_digits < maximum_digits && height_digits < maximum_digits)); then
        return 0
    fi
    if ((width_digits > maximum_digits || height_digits > maximum_digits)); then
        return 1
    fi
    if ((width_digits == maximum_digits)); then
        ((10#$width <= 10#$maximum)) || return 1
    fi
    if ((height_digits == maximum_digits)); then
        ((10#$height <= 10#$maximum)) || return 1
    fi
}

resolution_payload() {
    local width="$1"
    local height="$2"

    resolution_payload_dimensions_are_valid "$width" "$height" || {
        printf 'error: resolution payload dimensions must be positive integers no greater than %s\n' \
            "$MAX_RESOLUTION_PAYLOAD_DIMENSION" >&2
        return 1
    }
    (
        set -o pipefail
        printf '%08x%08x' "$width" "$height" |
            /usr/bin/xxd -r -p |
            /usr/bin/base64 |
            /usr/bin/tr -d '\n'
    )
}

print_resolution_preview_mode() {
    local name="$1"
    local width="$2"
    local height="$3"
    local payload

    [[ "$width" =~ ^[1-9][0-9]*$ && "$height" =~ ^[1-9][0-9]*$ ]] || return 1
    payload="$(resolution_payload "$width" "$height")" || return 1
    printf '%s: %sx%s framebuffer=%sx%s payload=%s\n' \
        "$name" "$width" "$height" "$width" "$height" "$payload"
}

append_similar_resolution_preview_modes() {
    local hidpi_preview="$1"
    local line
    local name
    local logical_width
    local logical_height
    local framebuffer_width
    local framebuffer_height
    local source_payload
    local logical_payload
    local framebuffer_payload
    local logical_output
    local framebuffer_output
    local known_payloads=""
    local similar_logical_outputs=()
    local similar_framebuffer_outputs=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([a-z0-9-]+):\ ([1-9][0-9]*)x([1-9][0-9]*)\ framebuffer=([1-9][0-9]*)x([1-9][0-9]*)\ payload=([A-Za-z0-9+/]+={0,2})$ ]] || return 1
        name="${BASH_REMATCH[1]}"
        logical_width="${BASH_REMATCH[2]}"
        logical_height="${BASH_REMATCH[3]}"
        framebuffer_width="${BASH_REMATCH[4]}"
        framebuffer_height="${BASH_REMATCH[5]}"
        source_payload="${BASH_REMATCH[6]}"
        if data_payload_list_has_value "$known_payloads" "$source_payload"; then
            printf 'error: smooth mode generation produced duplicate payloads\n' >&2
            return 1
        fi
        known_payloads="${known_payloads}${known_payloads:+$'\n'}${source_payload}"
        logical_output="$(print_resolution_preview_mode "similar-logical-${name}" "$logical_width" "$logical_height")" || return 1
        framebuffer_output="$(print_resolution_preview_mode "similar-framebuffer-${name}" "$framebuffer_width" "$framebuffer_height")" || return 1
        logical_payload="${logical_output##* payload=}"
        framebuffer_payload="${framebuffer_output##* payload=}"
        if [[ "$logical_payload" == "$framebuffer_payload" ]]; then
            printf 'error: smooth similar-resolution generation produced identical logical and framebuffer payloads\n' >&2
            return 1
        fi
        if data_payload_list_has_value "$known_payloads" "$logical_payload" ||
            data_payload_list_has_value "$known_payloads" "$framebuffer_payload"; then
            printf 'error: smooth similar-resolution generation produced duplicate payloads\n' >&2
            return 1
        fi
        known_payloads="${known_payloads}"$'\n'"${logical_payload}"$'\n'"${framebuffer_payload}"
        similar_logical_outputs+=("$logical_output")
        similar_framebuffer_outputs+=("$framebuffer_output")
    done <<< "$hidpi_preview"

    ((${#similar_logical_outputs[@]} > 0)) || return 1
    printf '%s\n' "$hidpi_preview"
    printf '%s\n' "${similar_logical_outputs[@]}"
    printf '%s\n' "${similar_framebuffer_outputs[@]}"
}
