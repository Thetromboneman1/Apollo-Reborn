# Build 369 simulator evidence

Source `616a55ee0d7ea918ed7e1fe271938ad10d264852` passed the SDK27.2 device package build and the 50-check Duo close-cleanup regression, with 318 checks across adjacent suites. Full downstream validation passed before that narrow cleanup repair and reruns in CI on this final revision. This evidence commit changes documentation only.

[Machine-readable matrix](simulator-summary.json) records four successful cold launches, iOS 26.5 and 27.0 in Classic and modern modes. Every launch explicitly injected the freshly built tweak, confirmed module initialization and actual appearance mode, opened the local Apollo Reborn settings screen, delivered UIKit Back taps, survived observation and produced no new Apollo crash report. The simulator used a separate bundle ID with no account backup.

| Classic, iOS 26.5 | Modern, iOS 26.5 |
| --- | --- |
| ![Classic settings](iOS26.5-classic.jpg) | ![Modern settings](iOS26.5-modern.jpg) |

Retained native UIKit harnesses (search source hashes verified unchanged) executed the shipping search-placement function and snapshot helper with actual navigation items, search controllers and bar buttons: 120 checks on 26.5 and 126 on 27.0 passed. Foundation host suites pass 42 search restoration checks and 10 disabled-action dispatch checks. Six affected Duo host suites pass 443 checks.

Installed runtimes cannot emulate iPhone Duo. Actual folding, cover artwork, Focused tall images and finger-following animation remain pending supported-device acceptance. These network-free checks do not certify live Reddit, account-specific composer behavior or Bark delivery. Phone signing, installation and private data continuity are recorded separately outside Git.
