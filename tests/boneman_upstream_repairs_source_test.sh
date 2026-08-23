#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gallery="$root/src/ApolloFeedGalleryCarousel.xm"
share="$root/src/ApolloShareAsImageLink.xm"
avatars="$root/src/ApolloUserAvatars.xm"
main_tweak="$root/src/Tweak.xm"

fail() {
    printf 'boneman_upstream_repairs_source_test: %s\n' "$1" >&2
    exit 1
}

grep -Fq 'kApolloFeedGalleryReleaseFlickVelocity' "$gallery" ||
    fail 'missing merged gallery release-velocity repair'
grep -Fq 'kApolloFeedGalleryReleaseFlickOverscroll' "$gallery" ||
    fail 'missing gallery release overscroll floor'

grep -Fq '_dyld_register_func_for_add_image(ApolloRegisterImageClasses)' "$avatars" ||
    fail 'class validation does not track loaded image class lists'
if grep -Eq '^[[:space:]]*Class[[:space:]]+\*[^=]*=[[:space:]]*objc_copyClassList' "$avatars"; then
    fail 'class validation still realizes every Objective-C class'
fi

grep -Fq 'ApolloWriteTrendingPlist' "$main_tweak" ||
    fail 'missing verified trending plist writer'
grep -Fq 'dictionaryWithContentsOfFile:path' "$main_tweak" ||
    fail 'trending plist is not read back before use'
if grep -Fq 'Trending plist write failed at %@' "$main_tweak"; then
    fail 'trending write diagnostic leaks a container path'
fi

copy_hook="$(awk '
    /%hook _TtC6Apollo15CopyURLActivity/ { capture=1 }
    capture { print }
    capture && /%end/ { exit }
' "$share")"
grep -Fq '%orig; // Apollo copies its own URL' <<<"$copy_hook" ||
    fail 'Copy Link no longer lets Apollo perform the original copy'
grep -Fq 'pasteboard.URL = rewritten;' <<<"$copy_hook" ||
    fail 'Copy Link does not correct the final pasteboard URL'
if grep -Fq 'absoluteString' <<<"$copy_hook"; then
    fail 'Copy Link diagnostic leaks a copied URL path'
fi

printf 'boneman_upstream_repairs_source_test passed\n'
