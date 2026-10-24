#!/usr/bin/env python3
from pathlib import Path


root = Path(__file__).resolve().parents[1]
badge_source = (root / "src/ApolloInboxBadge.xm").read_text()
preview_source = (root / "src/ApolloLinkPreviewFetcher.m").read_text()

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

print("integration review regressions passed")
