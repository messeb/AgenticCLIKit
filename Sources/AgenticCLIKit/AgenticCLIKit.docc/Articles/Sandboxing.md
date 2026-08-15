# App Sandbox and Distribution

Why this package cannot ship in a Mac App Store app.

## Overview

AgenticCLIKit works by spawning the user's own CLI binaries. Under the macOS App Sandbox, an app cannot execute arbitrary user-installed executables — there is no entitlement that grants it.

| Distribution | Supported |
|---|---|
| Developer ID (direct download) | ✅ |
| Mac App Store | ❌ |
| Command-line tools and scripts | ✅ |
| Server-side Swift on Linux | Partially — `gh` and `codex` only |

This is a platform constraint, not a limitation of the implementation. An app that needs App Store distribution needs a different architecture: talk to the vendor APIs directly, or move the execution into a separately distributed helper.

## What the package deliberately does not do

- It never installs, updates, or upgrades a CLI.
- It never performs a login or touches stored credentials. It reports auth state and hands back the command that fixes it; running that command is the app's decision, and the user's.
- It never writes tokens.

## Hardened Runtime

A Developer ID app must be notarised, and the Hardened Runtime is required for notarisation. Spawning child processes is allowed under the Hardened Runtime, so nothing extra is needed for the common case. If the app injects libraries or uses JIT for unrelated reasons, those entitlements are unaffected by this package.

## Finding the CLIs at all

An app launched from Finder inherits a minimal `PATH` — typically `/usr/bin:/bin:/usr/sbin:/sbin`. Homebrew and `~/.local/bin` are absent, so the CLI the user definitely installed is invisible.

``LoginShellExecutableLocator`` handles this: it checks `PATH`, then well-known install locations, then asks the user's login shell what it would resolve, and caches the result. If an app offers a "path to the CLI" preference, pass it as an override.
