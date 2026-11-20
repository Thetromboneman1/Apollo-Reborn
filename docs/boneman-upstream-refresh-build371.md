# Fork upstream refresh for build 371

This update integrates the latest upstream main and all 19 selected open PR heads into the Boneman fork. PR #1592 remains excluded because it removes Classic appearance and older backup restore support.

Upstream main: `6abfda3eb0eeba6602ef07bb4b7f86e9efef917a`.

## Compatibility resolutions

- Keep existing Classic, share-image, Bark/backend, account and backup behavior.
- Preserve independent legacy feed/comment search choices until a new Search Bars mode is explicitly selected. Mixed choices display Custom.
- Replace the old badge renderer with upstream unread badges. Migrate saved count/theme choices only when destination preferences are absent; keep old keys for backup compatibility.
- Replace the old inactive-icon renderer with upstream tab-bar styling while keeping the same saved tint key. Preserve the fork Reply button and its accent updates.
- Keep tabletop opt-in, coordinator lifecycle and native interaction-state restoration, plus fork spelling and unconditional thread-drag cleanup protections.
- Repair the existing listing-response test fixture to link production route policy and request markers. Add both preference-compatibility suites to downstream validation.

## Frozen exact heads

| PR | Change | Exact head |
|---|---|---|
| [#1364](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1364) | Improve Filters & Blocks settings | `7d151d286c31e74821688f28f4ef1eafe5ff0c9a` |
| [#1383](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1383) | Improve Settings keyboard dismissal and numeric field layout | `a00e95efa2786e4ede28933e4c6995c387cf6f8a` |
| [#1481](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1481) | Duo: skip repeated layout, scroll and per-cell work | `d8ffda1acba97b62b4a92d9e509bcad13e6a1c59` |
| [#1591](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1591) | Duo: add tabletop video controls | `9381f04eccbcef2933bd58f02af526802146a18a` |
| [#1597](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1597) | Sign-in: explain a missing Reddit API key instead of opening Reddit | `a213882b64673687ef05a20a55c3d6a9dcf2f19d` |
| [#1599](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1599) | YouTube: play embed-restricted videos in Apollo, and start videos iOS refused to autoplay | `c58f4deed594ff39b8f0eb61ab919b979d24d4e2` |
| [#1602](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1602) | Inbox: open a reply with no search bar flash, no link pill and no bounce | `1ca41c4b0c5963f9993ebab21fcf84f292075d6f` |
| [#1619](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1619) | Open Community Highlights and other tweak links on Apollo 1.14 (iOS 14) | `4da4cf35a3c9720d923a4bdc426bc5ccee1cfd6d` |
| [#1620](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1620) | API keys: load More Replies (and Inbox reply parents) when oauth.reddit.com sends Reddit's block page | `abb60229f7da9ac2b4077ba289c4a6efa8793b40` |
| [#1627](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1627) | Reopen Popular/All at launch without pulling you back to Posts, and let API-Key-Free Mode stay off | `4f667e25d7951bed38280a4332243fb61bd1ee67` |
| [#1630](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1630) | Fix two navigation animation crashes: leaving the app mid-spring, and the nav bar crossfading during a push | `dbb3b81c6b8b5ee155f47d56ad9d2054bdff43f9` |
| [#1641](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1641) | Add Reddit's For You feed to Home | `a40b8e2f83cac149a0b4d08b277666937a31f853` |
| [#1660](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1660) | Add settings to hide the feed search bar and Find in Comments bar | `93d695e2a7c02af31de89e7eb3b59a440c67ba73` |
| [#1669](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1669) | Comments: post camera-roll GIFs as GIFs instead of a still of the first frame | `a1edceb4bc96bfade3d207dbcc720043a6d450e9` |
| [#1670](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1670) | API-Key-Free: reload a failed feed when Reddit's rate limit resets, and send the Inbox's reply-parent lookup once | `982c9f84d3ef05e32150243bd09f64d8429563da` |
| [#1674](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1674) | Subreddit list: keep your subscriptions when Apollo's background refresh fails | `e7c10343f63731919f121d4ea3b5c0ddb155134a` |
| [#1675](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1675) | Translation: keep short text Google can't place, and names it only re-spells (#1665) | `b3b7b12e913ec1402a88e759be581af245d1fe2f` |
| [#1680](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1680) | Unread badges: optional compact dot and theme color | `0e71ecb9691d7fdc7954d927e1a62d74733f9444` |
| [#1684](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1684) | Add Tint Tab Bar Icons and Accent Navigation Buttons, now with Liquid Glass support  | `0c60a29f850937ad019e6ffd69d10117b4ea54f7` |

## Validation boundaries

Local verification evidence and the signed deployment artifacts are kept outside Git in the workspace's `refresh371`, `delivery-build371`, and `device-backup-build371` directories. Coverage is rechecked against live open PR metadata and re-fetched advertised heads before publication. The private phone package uses Xcode 27.2 / iOS 27.2 SDK with an explicit iOS 15 deployment floor; public release defaults remain unchanged.

Compilation, automated checks and simulator behavior are separate from physical-device feature acceptance. Phone deployment is an in-place Wi-Fi update with stopped-app backup and before-launch continuity checks. No uninstall or direct device preference writes are part of this procedure.
