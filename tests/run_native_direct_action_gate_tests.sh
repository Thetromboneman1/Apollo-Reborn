#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-native-direct-action.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloNativeActionMenus.xm').read_text()
start = source.index('static BOOL ApolloNativeActionMenuPerformPendingDirectAction(')
end = source.index('\n}\n\nBOOL ApolloNativeActionMenuInvokePostsAction(', start) + 2
test = (root / 'tests/native_direct_action_gate_tests.m').read_text()
marker = '// INCLUDE_PRODUCTION_DIRECT_DISPATCH'
assert test.count(marker) == 1
(output / 'test.m').write_text(test.replace(marker, source[start:end]))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_build_dir/test.m" -o "$test_build_dir/tests"
"$test_build_dir/tests"
