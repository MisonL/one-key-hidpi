# shellcheck shell=bash

resolution_payload() {
    local width="$1"
    local height="$2"

    printf '%08x%08x' "$width" "$height" |
        /usr/bin/xxd -r -p |
        /usr/bin/base64 |
        /usr/bin/tr -d '\n'
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
