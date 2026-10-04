# DockMirror

**Keeps the apps pinned in your Dock in the same order on all of your Macs.**

If you use more than one Mac, their Docks drift apart. You pin an app on one Mac and forget
it on the other, or you reorder things here but not there. Your muscle memory stops working
whenever you switch machines. DockMirror is a menu bar app that syncs the pinned apps in your
Dock through iCloud Drive. Add, remove or move an app on any Mac, and the others follow.

---

## ⬇️ Download

<p align="center">
  <a href="https://github.com/smanke-org/DockMirror/releases/latest/download/DockMirror.dmg">
    <img src="https://img.shields.io/badge/Download-DockMirror.dmg-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download DockMirror.dmg" height="48">
  </a>
</p>

1. **[Download DockMirror.dmg](https://github.com/smanke-org/DockMirror/releases/latest/download/DockMirror.dmg)**
2. Open it and drag **DockMirror** to **Applications**.
3. Open DockMirror. On your **main Mac** first, choose **Main Mac**. Its Dock becomes the starting layout.
4. Repeat on each other Mac and choose **Secondary Mac**. The setup window previews the result,
   and nothing changes until you click **Start Syncing**.

Every Mac must be signed in to the same Apple Account with iCloud Drive turned on.
Requires macOS 13 or later. Signed with Developer ID and notarized by Apple.

---

## What gets synced

- Only apps installed on **every** Mac are synced. Apps that are only on one Mac stay where
  they are on that Mac.
- Changes sync both ways: add, remove or move an app on any Mac, and the others follow.
- Recents, folders and stacks on the right side, spacers, and Dock settings are never touched.

## Safety

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

## Preferences

Open **Preferences…** from the menu bar menu (or ⌘,):

- **Check other Macs:** every minute (the default), 5, 15 or 30 minutes,
  hourly, or only when you click Sync Now. Edits to this Dock are still
  shared right away. A longer interval only means other Macs' edits arrive
  later, with less background work.
- **Show in Dock** (off by default) and **Show in menu bar** (on), in any
  combination. Right-clicking the Dock icon offers **Preferences…**. With
  both off, DockMirror keeps syncing with no icon; open it again from
  Applications or Spotlight to get back to Preferences.
- **Launch at Login** and **Check for Updates at Launch.**

## Updates

DockMirror checks GitHub for a new release quietly at launch. If there is one, the menu offers
it, and nothing is installed until you click it. Turn off **Check for Updates at Launch** in
Preferences to stop the check. Before installing, the download must be signed by the same
developer and notarized by Apple. It is installed in place, so your settings carry over.

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
- **Detecting changes.** The Dock rewrites its preferences file for many
  reasons, Recents included. After three quiet seconds, so a drag in progress
  is never synced half-way, DockMirror compares just the pinned apps and does
  a full sync only if they changed. Other Macs' files are checked at the
  chosen interval and on wake. A file that hasn't changed is never re-read,
  and app-location lookups are cached for 10 minutes.

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
./make_dmg.sh                                # notarized .dmg, plus DockMirror.dmg
gh release create vX.Y.Z .build/app/DockMirror-X.Y.Z.dmg .build/app/DockMirror.dmg \
  --repo smanke-org/DockMirror
```

Upload both images. The README's download button points at
`releases/latest/download/DockMirror.dmg`, which only works if every release
carries a file with exactly that name.
