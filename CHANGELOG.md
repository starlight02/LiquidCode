# Changelog

All notable changes to LiquidCode will be documented in this file.

## [0.1.0] - 2026-07-03

### Productization

- Make `LiquidCode.xcodeproj` / `LiquidCode` scheme the canonical release path.
- Generate release artifacts from an Xcode archive-derived `.app` instead of `swift build` plus a handcrafted bundle.
- Resolve display name, bundle id, version, and build from the built app Info.plist.
- Add signing/notarization preflight, development ad-hoc fallback, AppIcon asset catalog, localized bundle strings, release metadata, and CI release gate.

### Parity

- Add behavior coverage for composer model/mode/thinking payloads, richer GFM markdown parsing, watcher UI refresh, process restart/exit cleanup, Rewind restore-all/conversation/code/summarize semantics, app-local MCP CRUD persistence/source filtering, provider/MCP cleanup, CLI update detection, and stale recent-project handling.
- Fix project-skill slash insertion so accepting a slash command with trailing whitespace closes the popover instead of showing a stale `No command matches` state.
- Harden release-app launch by replacing fragile SwiftUI window restoration with an AppDelegate-owned model and explicit native `NSWindow` presentation.
- Add a file-fingerprint polling fallback to the directory watcher so create/modify/delete changes still refresh within the parity gate when FSEvents is silent.
- Make the AppIntents dependency explicit to remove the Xcode metadata-extraction warning from Debug/Release builds.
- Keep LiquidCode branding in packaged resources while matching TOKENICODE's native app layout and release artifact matrix.
- Fix MCP server creation so LiquidCode app-local servers persist, while Claude/Project managed servers stay read-only in Settings.
