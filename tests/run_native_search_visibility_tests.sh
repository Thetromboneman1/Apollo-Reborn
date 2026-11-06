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
setting_start = source.index('static BOOL NSBSearchBarTurnedOff(')
setting = source[setting_start:start]
attach_start = source.index('static void NSBAttachNativeSearch(')
attachment = source[attach_start:source.index('\n}', attach_start) + 2]
dismiss_start = source.index('void ApolloNativeFeedSearchFindDismissed(')
dismissal = source[dismiss_start:source.index('\n}', dismiss_start) + 2]
fixture = (root/'tests/native_search_visibility_tests.m').read_text()
for marker, production in [('VISIBILITY_STATE', state), ('SETTING_POLICY', setting), ('PLACEMENT', placement), ('ATTACHMENT', attachment), ('FIND_DISMISSED', dismissal)]:
    fixture = fixture.replace('// INCLUDE_PRODUCTION_' + marker, production)
(build/'tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation "$visibility_build/tests.m" -o "$visibility_build/tests"
"$visibility_build/tests"
