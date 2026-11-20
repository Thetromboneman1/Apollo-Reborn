#!/bin/sh
set -eu
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-upload-album-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

upload_probe_count=$(grep -c '^static void ApolloSimDebugUploadAlbumTest(void)' "$test_repo_root/src/ApolloSimDebugTap.xm")
if [ "$upload_probe_count" -ne 1 ]; then
    echo "Expected exactly one simulator upload album probe, found $upload_probe_count" >&2
    exit 1
fi

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloUploadAlbumCompatibility.m" \
    "$test_repo_root/tests/upload_album_compatibility_tests.m" \
    -o "$test_build_dir/upload_album_tests"
"$test_build_dir/upload_album_tests"
