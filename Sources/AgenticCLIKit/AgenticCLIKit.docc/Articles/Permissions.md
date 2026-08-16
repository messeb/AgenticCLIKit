# Permissions

Every run states what the agent is allowed to do. There is no default.

## Overview

The failure mode of a wrong default here is an agent editing a user's files without being asked, so ``PermissionPolicy`` is a required member of ``RunConfiguration``.

```swift
let configuration = RunConfiguration(
    workingDirectory: repositoryURL,
    permissions: .readOnly
)
```

## The policies

| Policy | Meaning |
|---|---|
| ``PermissionPolicy/planOnly`` | Produce a plan; take no action. |
| ``PermissionPolicy/readOnly`` | Read and search freely; no writes, no shell side effects. |
| ``PermissionPolicy/allowingTools(allowed:denied:)`` | Allow exactly these tools. |
| ``PermissionPolicy/acceptingEdits`` | Edit files in the working directory without prompting. |
| ``PermissionPolicy/unsafeBypassAll`` | Skip every check. |

`planOnly`, `readOnly`, and `acceptingEdits` work on every prompting adapter. The other two are conditional.

## Refusal beats silent widening

`allowingTools` needs ``CLICapabilities/toolAllowlist`` — Claude Code, Copilot, and Vibe have it. Codex and Antigravity sandbox by filesystem scope rather than by tool name, so they cannot express it — and rather than quietly running with something broader, they throw ``AgenticCLIError/unsupportedPermissionPolicy(_:_:reason:)`` with the reason.

```swift
do {
    try await codex.run(prompt, configuration: .init(
        workingDirectory: url,
        permissions: .allowingTools(["Read"])
    ))
} catch let error as AgenticCLIError {
    // "codex cannot honour the permission policy allowingTools(Read):
    //  codex sandboxes by filesystem scope, not by tool name"
}
```

The same principle applies elsewhere: an adapter refuses `maximumTurns`, a system prompt, or an ephemeral run when the CLI has no flag for it, instead of dropping the request on the floor.

## `unsafeBypassAll`

The name carries the warning, in the manner of `unsafeBitCast`. It disables every agent permission check, including shell execution. Uses are logged at `.fault` so they can be found afterwards. Reach for it only when the surrounding environment is itself a sandbox.

## How the policies map

| Policy | `claude` | `codex` | `agy` | `vibe` |
|---|---|---|---|---|
| `planOnly` | `--permission-mode plan` | `--sandbox read-only` | `--mode plan` | `--agent plan` |
| `readOnly` | `--permission-mode manual` + allow/deny lists | `--sandbox read-only` | `--mode plan --sandbox` | `--agent plan --auto-approve` + `--enabled-tools` allowlist |
| `acceptingEdits` | `--permission-mode acceptEdits` | `--sandbox workspace-write` | `--mode accept-edits` | `--agent accept-edits` |
| `unsafeBypassAll` | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` | `--agent auto-approve --auto-approve` |

On `vibe`, an `--enabled-tools` list is real enforcement rather than a request: in programmatic mode it disables every tool it does not name. So ``PermissionPolicy/readOnly`` is expressed as an allowlist of the tools that only observe, not as a profile that merely discourages the rest. A tool a later `vibe` release adds is *not* on that list — the safe direction for a list that can go stale.

> Note: On Antigravity, a schema run cannot use plan mode — see <doc:TypedResults>.

## The environment is an allowlist too

Child processes never receive the host environment wholesale. A host app's environment routinely holds unrelated secrets, and an agent with shell access can read all of them. Each adapter opts into its own credential variables, so a Codex key never reaches a Claude run. Extend it deliberately:

```swift
configuration.environmentPolicy = .base.inheriting("MY_APP_REGION")
configuration.environmentOverrides = ["MY_APP_MODE": "review"]
```
