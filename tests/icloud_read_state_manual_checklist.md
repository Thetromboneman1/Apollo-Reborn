# iCloud read-state sync manual checks

Use synthetic folders and fixture journals for simulator checks. Never select a
real backup folder containing credentials for development evidence.

## Simulator

- With no folder selected in Backup Settings, enable read-state sync, review the
  consent disclosure, and confirm the setting remains off with a recovery prompt.
- Select a synthetic folder through Backup Settings, then enable read-state sync.
  Confirm the status becomes `Active` without asking for a second folder.
- Confirm the selected folder gains only
  `Apollo Reborn Sync/Read State.plist` and its existing
  `.apollo-reborn-folder-id` marker. Existing `.apollobackup` files must remain
  byte-for-byte unchanged.
- Make the selected folder temporarily unavailable. Confirm local read tracking
  continues, the status explains the failure, and sync retries after foregrounding.
- Stall or disconnect the selected folder's file provider during a read-state
  update. Confirm the operation stops waiting after the shared 45-second
  coordinator timeout, backup operations resume, and sync reports a retryable
  error instead of blocking the store queue indefinitely.
- Revoke or stale the saved bookmark. Confirm the UI asks the user to reconnect
  the folder through Backup Settings instead of choosing a fallback container.
- Restore a settings backup that was created while read-state sync was enabled.
  Confirm this installation remains opted out until the disclosure is accepted.
- While sync is active, select a different folder. Confirm sync turns off and
  requires the disclosure to be accepted again for that exact folder.
- Turn sync off, terminate Apollo, and relaunch it. Confirm the local disabled
  tombstone keeps sync off and no polling or uploads resume without fresh consent.
- While a sync is queued, select a different folder. Confirm the queued operation
  cannot write old-folder history into the newly selected folder.
- Upgrade a legacy selected-folder record without a marker UUID. Confirm the
  marker migration retains the original consent identity and sync stays enabled.

## Real-device acceptance

- On two devices signed into the same iCloud account, select the same iCloud
  Drive backup folder on each device and opt in on each device separately.
- Mark a post read on device A, wait for iCloud Drive to deliver the file, then
  foreground device B and confirm the post is read there.
- Mark the same post unread on device B and confirm the newer event converges on
  device A without resurrecting an older read record.
- Open a comment thread on device A, add comments from a fixture account, and
  confirm device B receives the earlier comment-count baseline after a cold start.
- Exercise concurrent offline edits on both devices, reconnect, and confirm both
  converge after Files resolves conflict versions.

Simulator checks validate UI, bookmark reuse, coordinated file I/O, and journal
merge behavior. They do not prove iCloud transport or cross-device delivery.
