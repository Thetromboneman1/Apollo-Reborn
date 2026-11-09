#!/bin/sh
set -eu
badge_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
badge_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-badge-migration.XXXXXX")
trap 'rm -rf -- "$badge_build"' EXIT HUP INT TERM
python3 - "$badge_root" "$badge_build" <<'PY'
from pathlib import Path
import re
import sys
root, build = map(Path, sys.argv[1:])
source = (root/'src/ApolloUnreadBadges.xm').read_text()
start = source.index('void ApolloUnreadBadgesMigratePreferences(')
function = source[start:source.index('\n}', start) + 2]
constants = (root/'src/UserDefaultConstants.h').read_text()
keys = re.findall(r'^static NSString \*const UDKey(?:InboxBadge\w+|UnreadBadge\w+) = .*?;', constants, re.M)
fixture = (root/'tests/unread_badge_migration_tests.m').read_text()
fixture = fixture.replace('// INCLUDE_PRODUCTION_MIGRATION', '\n'.join(keys) + '\n' + function)
(build/'tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-variable \
    -fsanitize=address,undefined -framework Foundation "$badge_build/tests.m" -o "$badge_build/tests"
"$badge_build/tests"
