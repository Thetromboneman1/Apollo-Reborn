#!/bin/sh
set -eu

CDPATH=''
repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$repo_root/src/ApolloRecentlyRead.xm"

require_text() {
    description=$1
    pattern=$2
    if ! grep -Fq -- "$pattern" "$source_file"; then
        echo "FAIL: $description" >&2
        exit 1
    fi
}

reject_text() {
    description=$1
    pattern=$2
    if grep -Fq -- "$pattern" "$source_file"; then
        echo "FAIL: $description" >&2
        exit 1
    fi
}

require_text "post cells bypass settings typography" \
    '- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {'
require_text "post cells use Apollo card surface" \
    'return ApolloThemeCardBackgroundColor() ?: [UIColor systemBackgroundColor];'
require_text "flair uses Apollo page surface" \
    '[(ApolloThemePageBackgroundColor() ?: [UIColor systemGroupedBackgroundColor]) setFill];'
require_text "badge drawing is trait scoped" \
    '[traits performAsCurrentTraitCollection:^{'
require_text "metadata provider resolves secondary color" \
    '[[UIColor secondaryLabelColor] resolvedColorWithTraitCollection:tc]'
require_text "metadata provider resolves primary color" \
    '[[UIColor labelColor] resolvedColorWithTraitCollection:tc]'
require_text "visible metadata stays dynamic" \
    'UIColor *metaColor = RecentlyReadMetaColor();'
require_text "flair uses controller traits" \
    'self.traitCollection,'
require_text "long flair draws with tail truncation" \
    'NSStringDrawingTruncatesLastVisibleLine'
require_text "long flair is capped to available width" \
    'RecentlyReadFlairMaximumWidth(titleLabel,'
require_text "flair width uses current table geometry" \
    'CGFloat width = CGRectGetWidth(tableView.bounds);'
require_text "flair width prefers current thumbnail configuration" \
    'CGFloat thumbnailWidth = configuredSize ? configuredSize.doubleValue'

# The untouched-slider behavior predates this PR. Keep this assistance patch
# bounded to the maintainer's blocking UI regressions rather than silently
# changing Apollo's shared text-size fallback policy.
require_text "pre-existing untouched-slider fallback remains" \
    'return RecentlyReadSystemContentSizeCategory(node);'

reject_text "live theme refresh must not resolve against stale cell traits" \
    '[RecentlyReadMetaColor() resolvedColorWithTraitCollection:cell.traitCollection]'
reject_text "badges must not render from a detached label's traits" \
    'titleLabel.traitCollection);'
reject_text "reused label bounds must not short-circuit current thumbnail geometry" \
    'if (width > 1.0) return width;'
reject_text "nonzero reused thumbnail bounds must not override configured size" \
    'if (CGRectGetWidth(thumbnail.bounds) <= 1.0) {'

echo "PASS: Recently Read review-fix source invariants"
