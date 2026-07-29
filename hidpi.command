#!/bin/bash

[[ ! -L "$0" ]] || {
    printf '%s\n' 'error: Intel safe HiDPI requires a regular local checkout entrypoint' >&2
    exit 1
}

DIR="$(builtin cd "$(/usr/bin/dirname "$0")" && /bin/pwd)" || {
    printf '%s\n' 'error: could not resolve the local checkout directory' >&2
    exit 1
}

"$DIR/hidpi.sh"
