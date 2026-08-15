# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.x     | ✅ (pre-1.0: latest minor only) |

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Report via [GitHub Private Vulnerability Reporting](https://github.com/messeb/AgenticCLIKit/security/advisories/new) or email <sebastian@messeb.com>.

Include the description, reproduction steps, potential impact, and a suggested fix if you have one. Expect a response within 48 hours and a patch for confirmed critical issues within 14 days.

## Threat model for this package

AgenticCLIKit spawns AI agents as child processes on the user's machine, with the user's own credentials. That makes a few areas security-relevant:

- **Permission policies.** `PermissionPolicy` decides what an agent may do. A bug that widens a policy — or an adapter that silently substitutes a broader flag — is a security bug, not a behaviour change. Report it as such.
- **Environment isolation.** Children receive an explicit allowlist, never the host environment wholesale. A leak of unrelated variables (cloud credentials, API keys for other services) into a child is a security bug.
- **Attachments.** Remote attachments are downloaded by the kit and written into a per-run scratch directory. Filenames are sanitised so they cannot escape it. A path-traversal escape is a security bug.
- **Logging.** Prompts and output are redacted from `os.Logger` by default. Unredacted prompt content reaching the system log is a security bug.
- **`unsafeBypassAll`.** This intentionally disables every agent permission check. Its behaviour is not a vulnerability, but a path that reaches it *without* the caller asking for it is.

## Out of scope

- Vulnerabilities in the underlying CLIs (`claude`, `codex`, `gh`, `agy`) — report those to their vendors.
- The inability to run inside the macOS App Sandbox. This is a documented platform constraint, not a defect.

## Security practices for users

- Prefer `.planOnly` or `.readOnly` unless the user explicitly asked the agent to make changes.
- Keep the underlying CLIs updated; the weekly compatibility workflow tracks drift.
- Never commit credentials; the CLIs manage their own.
