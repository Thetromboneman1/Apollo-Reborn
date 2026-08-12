# Repository Maintenance

## Ownership And Upstream

`Thetromboneman1/Apollo-Reborn` is a maintained fork of
`Apollo-Reborn/Apollo-Reborn`. The upstream project owns product development;
this fork owns only reviewed downstream changes and local build validation.

## Safe Synchronization

1. Fetch upstream `main` and create a dedicated review branch.
2. Merge without force-pushing or rewriting either history.
3. Inspect changes to build, signing, packaging, and release workflows.
4. Run the repository's tests and a bounded build before merging.
5. Keep credentials in GitHub Actions or the Boneman vault. Never add API keys,
   signing material, or decrypted application packages to Git.

If the histories conflict, stop the automated sync and resolve the review
branch manually. Closing the pull request and deleting its branch safely
abandons an update.
