#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$repo_root/src/ApolloNotificationBackend.m"

fail() {
    printf 'notification_backend_source_test: %s\n' "$1" >&2
    exit 1
}

# Every request that reaches the rewrite routine has already passed the legacy
# host and configured-backend checks. The token block must therefore occur
# before method/path classification, making it universal for DELETE, PATCH,
# GET, receipt, and diagnostic rewrites while preserving the existing POST-only
# body augmentation below.
token_line=$(awk '/if \(sCachedRegistrationToken\.length > 0\)/ { print NR; exit }' "$source_file")
rewritten_url_line=$(awk '/mutable\.URL = rewrittenURL;/ { print NR; exit }' "$source_file")
method_line=$(awk '/NSString \*method = mutable\.HTTPMethod\.uppercaseString/ { print NR; exit }' "$source_file")
post_augmentation_line=$(awk '/if \(\[method isEqualToString:@"POST"\]\)/ { print NR; exit }' "$source_file")

[ -n "$token_line" ] || fail 'missing configured-token guard'
[ -n "$rewritten_url_line" ] || fail 'missing rewritten request assignment'
[ -n "$method_line" ] || fail 'missing request method handling'
[ -n "$post_augmentation_line" ] || fail 'missing POST body augmentation guard'
[ "$rewritten_url_line" -lt "$token_line" ] || fail 'token can be added to a request that was not rewritten'
[ "$token_line" -lt "$method_line" ] || fail 'token injection is still constrained by method or path classification'
[ "$token_line" -lt "$post_augmentation_line" ] || fail 'token injection occurs after POST-only compatibility work'

header_write_count=$(grep -Fc '[mutable setValue:sCachedRegistrationToken forHTTPHeaderField:@"X-Registration-Token"];' "$source_file" || true)
[ "$header_write_count" -eq 1 ] || fail 'configured token is not written exactly once inside the universal rewrite path'

if grep -Fq 'ApolloPathRequiresRegistrationToken' "$source_file"; then
    fail 'obsolete registration-route token classifier still restricts authentication'
fi

# The length guard is the explicit unset-token behavior: no header write occurs
# when the setting is empty. Because the guarded write is before method/path
# classification, it covers DELETE, PATCH, GET, and diagnostic rewrites.

printf 'notification_backend_source_test passed\n'
