#!/usr/bin/env python3
from pathlib import Path


root = Path(__file__).resolve().parents[1]
badge_source = (root / "src/ApolloInboxBadge.xm").read_text()
preview_source = (root / "src/ApolloLinkPreviewFetcher.m").read_text()
comment_header_source = (root / "src/ApolloCommentHeaderLayout.xm").read_text()
classes_header = (root / "src/ApolloClasses.h").read_text()
classes_source = (root / "src/ApolloClasses.m").read_text()
duo_source = (root / "src/ApolloDuoRailCore.m").read_text()
new_video_source = (root / "src/ApolloNewVideoPost.xm").read_text()

assert '#import "ApolloClasses.h"' in badge_source
assert 'NSClassFromString(@"_UIBarBadgeView")' not in badge_source
assert badge_source.count("ApolloClassUIBarBadgeView") >= 4

gone_lines = [
    line
    for line in preview_source.splitlines()
    if "Bluesky post is gone" in line
]
assert len(gone_lines) == 2
assert all("actor=%lu chars" in line for line in gone_lines)
assert all("actor=%@" not in line for line in gone_lines)

assert 'objc_getClass("_TtC6Apollo22CommentsHeaderCellNode")' not in comment_header_source
assert "Class headerClass = ApolloClassCommentsHeaderCellNode;" in comment_header_source

assert 'extern Class ApolloClassUIViewReservedRegionKind;' in classes_header
assert 'ApolloClassUIViewReservedRegionKind = objc_getClass("UIViewReservedRegionKind");' in classes_source
assert 'NSClassFromString(@"UIViewReservedRegionKind")' not in duo_source
assert 'NSSelectorFromString(@"reservedRegionsOfKind:")' not in duo_source
assert 'Class kindClass = ApolloClassUIViewReservedRegionKind;' in duo_source

assert 't3_%@' not in new_video_source
assert new_video_source.count('ApolloNewVideoPostLogThing(bareID)') >= 11
assert 'return ApolloLogOwnThing(fullName);' in new_video_source

print("integration review regressions passed")
