#!/bin/sh
set -eu
visibility_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
visibility_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-search-visibility.XXXXXX")
trap 'rm -rf -- "$visibility_build"' EXIT HUP INT TERM
python3 - "$visibility_root" "$visibility_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root/'src/ApolloSearchNativeBar.xm').read_text()
state = source[source.index('static char kNSBDuoSearchPlacementKey;'):source.index('static char kNSBDuoSearchPlacementScheduledKey;')]
start = source.index('static void NSBUpdateSearchPlacement(')
placement = source[start:source.index('\n}', start) + 2]
fixture = (root/'tests/native_search_visibility_tests.m').read_text()
(build/'tests.m').write_text(fixture.replace('// INCLUDE_PRODUCTION_VISIBILITY_STATE', state).replace('// INCLUDE_PRODUCTION_PLACEMENT', placement))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation "$visibility_build/tests.m" -o "$visibility_build/tests"
"$visibility_build/tests"
