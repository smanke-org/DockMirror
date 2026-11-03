# DockMirror

Drive the app with `dockmirror` (the app binary; `dockmirror help`). See `.claude/skills/dockmirror/SKILL.md`. Commands live in
`Sources/DockMirror/Agent/AgentCommands.swift`; test them on a Debug build with `APP_STORE=/tmp/<name>`, which starts a test
copy on its own sync folder, backups and settings that never writes the Dock (Release builds ignore it).
