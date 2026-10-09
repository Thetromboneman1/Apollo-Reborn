#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER="$ROOT/src/UserDefaultConstants.h"

duplicates="$({
    sed -nE 's/^[[:space:]]*static NSString \*const ([A-Za-z0-9_]+).*/\1/p' "$HEADER"
} | sort | uniq -d)"

if [[ -n "$duplicates" ]]; then
    printf 'duplicate user-default constant declarations:\n%s\n' "$duplicates" >&2
    exit 1
fi

printf 'user-default constant uniqueness tests passed\n'
