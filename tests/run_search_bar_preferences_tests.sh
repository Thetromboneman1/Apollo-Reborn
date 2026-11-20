#!/bin/sh
set -eu
search_policy_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
search_policy_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-search-preferences.XXXXXX")
trap 'rm -rf -- "$search_policy_build"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -I "$search_policy_root/src" \
    "$search_policy_root/src/ApolloState.m" "$search_policy_root/tests/search_bar_preferences_tests.m" \
    -o "$search_policy_build/tests"
"$search_policy_build/tests"
