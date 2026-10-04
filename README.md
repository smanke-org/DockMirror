# DockMirror

A macOS menu bar app that keeps the pinned apps in your Dock in the same order
on all of your Macs.

- Only apps installed on **every** Mac are synced. Apps that are only on one
  Mac stay where they are on that Mac.
- Changes sync both ways: add, remove or move an app on any Mac, and the
  others follow.
- Recents, folders and stacks on the right side, spacers, and Dock settings
  are never touched.

## Install

[**Download the latest release**](https://github.com/smanke-org/DockMirror/releases/latest).
It is a `.dmg` signed with a Developer ID certificate and notarized by Apple.
Drag `DockMirror.app` to `/Applications` and open it on each Mac. Every Mac
must be signed in to the same Apple Account with iCloud Drive turned on.

On first launch DockMirror asks for this Mac's role:

1. **Main Mac**: its current Dock becomes the starting layout. Set this one up first.
2. **Secondary Mac**: adopts the main Mac's order for the apps they share.

The setup window previews the resulting Dock. Nothing changes until you click
**Start Syncing**.

## How it works

- **Storage.** The Dock keeps its layout in the `com.apple.dock` preferences.
  DockMirror reads and writes only `persistent-apps`, through CFPreferences,
  then restarts the Dock. Apps are matched across Macs by bundle identifier.
- **Sharing.** Each Mac writes one file, `iCloud Drive/DockMirror/Devices/<id>.json`.
  It reads everyone else's. With a single writer per file, iCloud never has
  conflicting copies to resolve.
- **Merging.** Every app has its own entry: pinned or not, plus a position key.
  The most recent change to an app wins. Position keys are fractional, so
  moving one app changes only that app's entry. Edits to different apps on
  different Macs therefore never collide.
- **Detecting changes.** Changes to the Dock are noticed through FSEvents and
  acted on after three quiet seconds, so a drag in progress is never synced
  half-way. Other Macs' files are read every minute and on wake.

### Safety

- The whole Dock domain is backed up before every change (the last 50 are
  kept). **Restore Dock** in the menu puts any of them back.
- Large removals are held until you confirm them. That covers 5 or more apps
  at once, or half of the synced apps. Such a change is more likely macOS
  resetting the Dock than a deliberate edit, and spreading it would empty
  every Mac's Dock.
- Uninstalling an app on one Mac stops it being synced. It does not remove it
  from the other Macs' Docks.
- A Mac that hasn't been seen in 30 days stops limiting which apps are synced.
  You can also forget a Mac from the **Macs** menu.
- If the Dock refuses a tile DockMirror adds, that is never mistaken for you
  unpinning the app.

## Building

```bash
swift test         # sync engine tests
./build_app.sh     # .build/app/DockMirror.app
```

`DOCKMIRROR_SYNC_FOLDER=/some/folder` points the app at a scratch folder
instead of iCloud Drive. A debug build shares this Mac's device ID, so always
set this when testing. `DOCKMIRROR_DRY_RUN=1` plans and publishes but never
writes the Dock. `defaults read com.smanke.DockMirror diagnostics` shows the
role, the synced order, and the last error or hold.

## Releasing

```bash
./release.sh "Developer ID Application: …"   # sign, notarize, staple
./make_dmg.sh                                # notarized .dmg
gh release create vX.Y.Z .build/app/DockMirror-X.Y.Z.dmg --repo smanke-org/DockMirror
```

The app updates itself from the latest GitHub release's `.dmg`. It checks
quietly at launch, and offers the update in the menu. The download must pass
`codesign`, carry the same Team ID, and pass Gatekeeper (notarization) before
it is installed in place.
