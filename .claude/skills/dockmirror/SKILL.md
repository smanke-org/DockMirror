---
name: dockmirror
description: Drive DockMirror, the app that keeps the Dock the same on all of the user's Macs, from the shell with the `dockmirror` command: check the sync status, list this Mac's Dock apps, the other Macs and the Dock backups, sync now, pause and resume, set up or stop syncing, answer a held big removal, restore a backup. Use when the user asks about their Dock syncing, their Macs in the sync, or names DockMirror.
---

# DockMirror

`dockmirror` runs commands in the DockMirror app, through the same code as its menu bar menu.
If the app is closed, the command opens it in the background. If `dockmirror` isn't on PATH, use
`/Applications/DockMirror.app/Contents/MacOS/DockMirror` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Changing the Dock restarts it and can spread to every Mac. `setup start`, `removal apply`,
  `backups restore` and `macs forget` only report what they would do. Show the user that report
  and ask before you run it again with `--yes` (over MCP: `yes` set to true).
- `sync now`, `sync resume` and `removal keep` can rearrange this Dock with other Macs' changes.
  Run them when the user asked for a sync.
- `hold` in `dockmirror status` means a big removal is waiting for the person's answer:
  `removal apply` goes ahead, `removal keep` puts the apps back. Ask which they want.
- Find Mac ids with `dockmirror macs list` and backup ids with `dockmirror backups list`.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/dockmirror-test`
  in front: a test copy that never writes the Dock.

## Main commands

| Command | Does |
| --- | --- |
| `dockmirror status --json` | Role, paused, last sync, synced apps, last error, held removal |
| `dockmirror dock list --json` | This Dock's apps in order, and which ones sync |
| `dockmirror macs list --json` | Every Mac in the sync and when it was last seen |
| `dockmirror sync now --json` | Sync right away and wait for it |
| `dockmirror sync pause --json` / `sync resume` | Stop or restart syncing this Mac |
| `dockmirror setup preview --role main\|secondary --json` | What this Dock would become, changing nothing |

Everything else: `dockmirror help`, and `dockmirror help <command>` for its options.
