# Ghostty Sessions

A floating macOS panel that shows your Claude Code sessions in Ghostty. Click a row to go to its tab.

Ghostty is not changed or forked. The app uses Ghostty's AppleScript dictionary (Ghostty 1.3 and later), so Ghostty updates need no work here.

## What it shows

- **Needs you:** sessions that wait for a permission, and sessions that finished a turn that you did not look at yet.
- **Working:** sessions that Claude is busy on.
- **Idle:** finished sessions that you already looked at.

Each row shows the session title, the repos that the session worked in (from its transcript), and how long it has been in its current state. A permission row also shows the tool call that waits for approval.

## Keys

| Key | Action |
| --- | --- |
| ⌃⌥Space | Go to the session that has waited longest |
| ⌃⌥S | Show or hide the panel |
| ⌘↩ | Start the session in the "New session" form |

## Build and run

You need the Xcode Command Line Tools. The full Xcode app is not necessary.

```sh
./scripts/bundle.sh
open "build/Ghostty Sessions.app"
```

On the first run, macOS asks for permission to control Ghostty. Allow it. If you deny it, enable it again in System Settings → Privacy & Security → Automation.

To see the matched sessions as text, run `.build/release/GhosttySessions --dump`.

## How it works

| Data | Source |
| --- | --- |
| Tabs, titles, focused tab | Ghostty AppleScript (`terminals`, `focus`, `new tab`) |
| Session state | `~/.claude/sessions/<pid>.json` (`busy`, `idle`, `waiting`, `shell`) |
| Tab to session match | The tab title is equal to the latest `ai-title` in the transcript. Sessions that the app starts use `--session-id`. |
| Repos | Paths below the session folder (default `~/code`) in the end of the transcript |

The session files and the transcript format are internal to Claude Code. They can change in a Claude Code update. If they change, the app falls back to the tab title glyph: `✳` is idle, and a half circle is working.

## Note on `@State`

The macOS 26 SDK makes SwiftUI's `@State` a macro. The macro plugin comes only with Xcode. `Local.swift` supplies the same behavior through `@StateObject`, so the views use `@Local`.
