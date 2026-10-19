# iCloud read-state simulator evidence

- `no-folder-consent-error.gif` shows the opt-in disclosure and the fail-closed
  result when Backup Settings has no saved folder. The switch remains off.
- `selected-folder-active.gif` shows the same disclosure followed by an active
  status when an existing selected-folder bookmark is available.

These recordings were made in an iOS 27 simulator. The active-folder scenario
used a temporary, simulator-only app-local folder fixture because the locked
development Mac could not complete the Files extension's Save action through
simulator automation. That fixture seam is not present in the committed app
sources. The scenario verifies the settings flow, saved-folder reuse, status
updates, coordinated file access, and namespace creation. It does **not** prove
live iCloud Drive transport, a real Files picker selection, or cross-device
delivery; those remain real-device acceptance checks.
