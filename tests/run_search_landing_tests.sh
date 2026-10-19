#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-search-landing-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloSearchLandingPreferences.m" \
    "$test_repo_root/src/ApolloSearchRecents.m" \
    "$test_repo_root/tests/search_landing_tests.m" \
    -o "$test_build_dir/search_landing_tests"
"$test_build_dir/search_landing_tests"

# Compile the actual Swift readers against concrete class-array fixtures. The
# model harness above cannot exercise Swift storage or returned-object lifetime.
# The production bridge also contains UIKit-only helpers, so extract these two
# Foundation-only functions rather than compiling unrelated iOS code for macOS.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "src/ApolloSwiftIvarBridge.swift").read_text()

def function(named):
    start = source.index(f'@_cdecl("{named}")')
    end = source.index("\n}", start) + 2
    return source[start:end]

(output / "ApolloSearchIvarReaders.swift").write_text(
    "import Foundation\n\n"
    + function("ApolloSwiftCopyOptionalStringArray") + "\n\n"
    + function("ApolloSwiftCopyFirstObjectArrayElement") + "\n"
)
PY
xcrun --sdk macosx swiftc -parse-as-library -O -warnings-as-errors \
    "$test_build_dir/ApolloSearchIvarReaders.swift" \
    "$test_repo_root/tests/search_ivar_bridge_tests.swift" \
    -o "$test_build_dir/search_ivar_bridge_tests"
"$test_build_dir/search_ivar_bridge_tests"
