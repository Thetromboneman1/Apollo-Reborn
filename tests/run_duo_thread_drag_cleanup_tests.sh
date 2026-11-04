#!/bin/sh
set -eu
cleanup_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cleanup_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-drag-cleanup.XXXXXX")
trap 'rm -rf -- "$cleanup_build"' EXIT HUP INT TERM
python3 - "$cleanup_root" "$cleanup_build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root/'src/ApolloDuoSplitView.xm').read_text()
def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2]
fixture = (root/'tests/duo_thread_drag_cleanup_tests.m').read_text()
fixture = fixture.replace('// INCLUDE_PRODUCTION_FILLER_REMOVAL', function('static void ApolloDuoRemoveThreadDragFiller('))
fixture = fixture.replace('// INCLUDE_PRODUCTION_TRANSITION', function('static void ApolloDuoPostsSetDetailPagesFromDrag('))
(build/'tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -fsanitize=address,undefined \
    -framework Foundation -framework CoreGraphics "$cleanup_build/tests.m" -o "$cleanup_build/tests"
"$cleanup_build/tests"
