#!/bin/sh
set -eu

# Run the actual production setters after Logos expansion over Foundation-only
# UIKit doubles. An optional source argument verifies regression sensitivity.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-spelling-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM
python3 - "$test_repo_root" "$test_build_dir" "${1:-$test_repo_root/src/ApolloSpelling.xm}" <<'PY'
from pathlib import Path
import re, sys
root, out, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
conversion = source[source.index('static ApolloSpellingStyle sSpellingStyle'):source.index('static void CollectTables')]
if 'static char kApolloSpellingExcludedKey;' in source:
    owner_helpers = source[source.index('static char kApolloSpellingExcludedKey;'):source.index('ApolloSpellingStyle ApolloSpellingCurrentStyle')]
else:
    owner_helpers = source[source.index('// Replaces word by word'):source.index('ApolloSpellingStyle ApolloSpellingCurrentStyle')] if '// Replaces word by word' in source else ''
hooks = []
for name in ['UILabel', 'UIButton', 'UINavigationItem', 'UIListContentConfiguration']:
    match = re.search(r'%hook '+name+r'\n(.*?)\n%end', source, re.S)
    assert match, 'production hook missing: '+name
    hooks.append(match.group(0))
fixture = (root/'tests/spelling_tests.mm').read_text()
marker = '// INSERT_PRODUCTION_SPELLING'
assert fixture.count(marker) == 1
(out/'tests.xm').write_text(fixture.replace(marker, conversion+'\n'+owner_helpers+'\n'+'\n'.join(hooks)+'\n%ctor { %init; }'))
(out/'substrate.h').write_text('''#import <objc/runtime.h>
static inline void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}
''')
PY
if ! "${THEOS:-/Users/corn/theos}/bin/logos.pl" "$test_build_dir/tests.xm" > "$test_build_dir/tests.mm"; then
    nl -ba "$test_build_dir/tests.xm" | sed -n '175,205p'
    exit 1
fi
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -Wno-unused-parameter -Wno-unused-function -fsanitize=address,undefined \
    -framework Foundation -I "$test_build_dir" \
    "$test_build_dir/tests.mm" -o "$test_build_dir/tests"
"$test_build_dir/tests"
