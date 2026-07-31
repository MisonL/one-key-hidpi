# shellcheck shell=bash

readonly MAX_BULK_PLIST_ARRAY_XML_BYTES=131072

scale_resolutions_xml_from_override() {
    local override_path="$1"
    local expected_hash="$2"
    local expected_identity="$3"

    darwin_read_plist_file "$override_path" "$expected_hash" "$expected_identity" \
        -extract scale-resolutions xml1 -expect array -o -
}

data_payloads_from_plist_array_xml() {
    local plist_array_xml="$1"

    plist_xml_argument_is_within_limit "$plist_array_xml" || return 1
    [[ "$plist_array_xml" != *"<!ENTITY"* ]] || return 1
    printf '%s' "$plist_array_xml" | /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/ruby -rbase64 -rrexml/document -e '
        REXML::Security.entity_expansion_limit = 1000
        REXML::Security.entity_expansion_text_limit = 1_048_576
        document = REXML::Document.new(STDIN.read)
        root = document.root
        top_level_elements = root&.elements&.to_a || []
        exit 1 unless root&.name == "plist" && top_level_elements.length == 1 && top_level_elements.first.name == "array"

        top_level_elements.first.elements.each do |element|
            # Payload semantics use direct data nodes; merge preserves other nodes.
            next unless element.name == "data"

            payload = element.texts.map(&:value).join.gsub(/\s+/, "")
            exit 1 if payload.empty?
            Base64.strict_decode64(payload)
            print "#{payload}\n"
        rescue ArgumentError
            exit 1
        end
    '
}

valid_base64_payload() {
    local payload="$1"

    [[ "$payload" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    ((${#payload} % 4 == 0))
}

plist_xml_argument_is_within_limit() {
    local plist_xml="$1"
    local byte_count

    byte_count="$(LC_ALL=C /usr/bin/printf '%s' "$plist_xml" | /usr/bin/wc -c | /usr/bin/tr -d '[:space:]')" || return 1
    [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
    ((byte_count <= MAX_BULK_PLIST_ARRAY_XML_BYTES))
}

validate_data_payload_list() {
    local payloads="$1"
    local payload
    local payload_count=0

    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        valid_base64_payload "$payload" || return 1
        payload_count=$((payload_count + 1))
    done <<< "$payloads"

    ((payload_count > 0))
}

data_payload_list_has_value() {
    local payloads="$1"
    local expected_payload="$2"
    local bounded_payloads

    bounded_payloads=$'\n'"${payloads}"$'\n'
    [[ "$bounded_payloads" == *$'\n'"${expected_payload}"$'\n'* ]]
}

canonical_data_payload_set() {
    local payloads="$1"

    validate_data_payload_list "$payloads" || return 1
    printf '%s\n' "$payloads" | LC_ALL=C /usr/bin/sort -u
}

canonical_optional_data_payload_set() {
    local payloads="$1"

    [[ -n "$payloads" ]] || return 0
    canonical_data_payload_set "$payloads"
}

data_payload_list_has_missing_value() {
    local existing_payloads="$1"
    local generated_payloads="$2"
    local payload

    validate_data_payload_list "$generated_payloads" || return 2
    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        if ! data_payload_list_has_value "$existing_payloads" "$payload"; then
            return 0
        fi
    done <<< "$generated_payloads"
    return 1
}

append_missing_data_payloads_to_plist_array_xml() {
    local plist_array_xml="$1"
    local generated_payloads="$2"
    local updated_array_xml

    validate_data_payload_list "$generated_payloads" || return 1
    plist_xml_argument_is_within_limit "$plist_array_xml" || return 1
    [[ "$plist_array_xml" != *"<!ENTITY"* ]] || return 1
    updated_array_xml="$(printf '%s' "$plist_array_xml" | /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/ruby -rrexml/document -rrexml/formatters/default -e '
        REXML::Security.entity_expansion_limit = 1000
        REXML::Security.entity_expansion_text_limit = 1_048_576
        generated_payloads = ARGV.fetch(0).split("\n").reject(&:empty?)
        document = REXML::Document.new(STDIN.read)
        root = document.root
        top_level_elements = root&.elements&.to_a || []
        unless root&.name == "plist" && top_level_elements.length == 1 && top_level_elements.first.name == "array"
            warn "error: scale-resolutions XML does not contain one top-level array"
            exit 1
        end

        array = top_level_elements.first
        existing_payloads = {}
        array.elements.each("data") do |element|
            existing_payloads[element.texts.map(&:value).join.gsub(/\s+/, "")] = true
        end
        generated_payloads.each do |payload|
            next if existing_payloads[payload]

            array.add_element("data").text = payload
            existing_payloads[payload] = true
        end

        output = String.new
        REXML::Formatters::Default.new.write(document, output)
        print output
    ' "$generated_payloads")" || return 1

    if ! plist_xml_argument_is_within_limit "$updated_array_xml"; then
        printf 'error: scale-resolutions array exceeds the batch update size limit\n' >&2
        return 1
    fi
    printf '%s' "$updated_array_xml"
}

plist_string_array_xml_from_payloads() {
    local payloads="$1"
    local payload
    local payload_count=0
    local plist_array_xml="<array>"

    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        valid_base64_payload "$payload" || return 1
        plist_array_xml="${plist_array_xml}<string>${payload}</string>"
        payload_count=$((payload_count + 1))
    done <<< "$payloads"

    ((payload_count > 0)) || return 1
    plist_array_xml="${plist_array_xml}</array>"
    if ! plist_xml_argument_is_within_limit "$plist_array_xml"; then
        printf 'error: manifest payload array exceeds the batch update size limit\n' >&2
        return 1
    fi
    printf '%s' "$plist_array_xml"
}
