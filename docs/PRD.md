Here's the PRD. I've grounded the adapter details in the actual current CLI surfaces (verified against docs, some behaviors flagged for implementation-time verification since these CLIs move fast).

---

# PRD: AgentCLIKit — Swift Library for Embedding AI/Dev CLIs

**Status:** Draft v0.1 · **Owner:** Sebastian · **Target platforms:** macOS 13+ (primary), Linux (secondary, for server-side Swift)

> **Scope change, 2026-08-16.** This document is the original planning draft and
> is kept as written; the README is the current specification. One decision has
> since been reversed: the fourth adapter is **GitHub Copilot (`copilot`)**, not
> the GitHub CLI (`gh`).
>
> The draft below treats `gh` as GitHub's entry and leans on it as the
> capability-poor adapter that keeps the abstraction honest. That conflated two
> unrelated binaries: `gh` manages repositories and takes no prompts, while
> `copilot` is GitHub's actual coding agent — it prompts, streams token deltas,
> holds resumable sessions, takes attachments, and has the most expressive
> per-tool permission model of any CLI here. Wrapping `gh` in an *agent*
> abstraction was a category error, so it was removed.
>
> The role `gh` was serving in the design is now filled by `StubAgent` in
> `AgenticCLIKitTesting`, which is a better fit: a test double with configurable
> capabilities cannot quietly gain a capability and stop testing degradation, the
> way a real adapter can.

## 1. Problem Statement

Apps increasingly want to delegate work to locally installed agentic CLIs (Claude Code, Codex, Antigravity) and tooling CLIs (GitHub CLI) instead of talking to raw HTTP APIs. The CLIs bring their own auth, billing, sandboxing, and session persistence. But integrating them from a Swift app today means hand-rolling `Process` plumbing, per-CLI flag knowledge, JSON/JSONL parsing, exit-code interpretation, and session bookkeeping, four times over, with breaking changes on every CLI release.

AgentCLIKit provides a unified, typed Swift abstraction over these CLIs: discovery, auth verification, one-shot and multi-turn execution, streaming, and session recovery.

## 2. Goals

1. **Discovery:** Detect whether a CLI is installed, resolve its binary path, and report its version.
2. **Readiness:** Determine whether a CLI is actually usable: authenticated, token not expired, minimum version met.
3. **Execution:** Run one-shot prompts and multi-turn sessions non-interactively, with structured (typed) results.
4. **Session recovery:** Persist session identifiers so a conversation survives app restarts and can be resumed.
5. **Streaming:** Surface incremental output (JSONL / stream-json events) as an `AsyncSequence`.
6. **Safety:** Make permission/sandbox posture an explicit, typed choice, never a silent default.
7. **Extensibility:** New CLIs are added by implementing one protocol, without touching the core.

## 3. Non-Goals

- No bundling or installing of the CLIs themselves (v1 may *detect and deep-link* to install instructions).
- No credential storage or login UI. The library reports auth state and can launch the CLI's own login flow; it never touches tokens directly.
- No interactive TUI passthrough (no PTY emulation of the full interactive mode in v1).
- No support for App Sandboxed Mac App Store apps in v1. Spawning arbitrary user-installed binaries requires a non-sandboxed app (Developer ID distribution) or a helper. This is a hard platform constraint and must be documented prominently.
- Not an API client. If the host app wants raw Anthropic/OpenAI API access, that's a different library.

## 4. Users and Use Cases

**Primary user:** a macOS app developer (IDE plugin, dev tool, internal ops tool) who wants "run this task with the user's own Claude/Codex subscription" as a feature.

Representative flows:

1. App checks on launch: which agents are available and logged in → renders a picker with status badges.
2. User triggers "Review this diff" → app starts a Claude Code session, streams output into the UI, stores the session ID.
3. App relaunches next day → user clicks "continue review" → app resumes the stored session.
4. App needs a PR created → runs `gh` with typed JSON output, no session semantics.
5. A CLI's token expired → library returns `.needsLogin`, app shows a "Sign in" button that launches the CLI's login flow in Terminal or via device flow.

## 5. Core Concepts and API Surface

### 5.1 Protocol: `AgentCLI`

```swift
public protocol AgentCLI: Sendable {
    static var id: CLIIdentifier { get }          // .claudeCode, .codex, .gitHub, .antigravity
    var capabilities: CLICapabilities { get }      // sessions, streaming, structuredOutput, ...

    func discover() async -> DiscoveryResult       // installed? path? version?
    func authStatus() async -> AuthStatus          // loggedIn(account:), needsLogin, expired, unknown
    func run(_ request: RunRequest) async throws -> RunResult
    func stream(_ request: RunRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func resume(_ session: SessionRef, prompt: String, ...) async throws -> RunResult
}
```

### 5.2 Key Types

```swift
public struct DiscoveryResult {
    public let installed: Bool
    public let binaryURL: URL?
    public let version: SemanticVersion?
    public let meetsMinimumVersion: Bool
    public let installHint: String?        // e.g. "npm i -g @anthropic-ai/claude-code"
}

public enum AuthStatus {
    case loggedIn(account: String?, method: AuthMethod, expiry: Date?)
    case needsLogin(loginCommand: String)  // what to run/launch
    case environmentKey(variable: String)  // e.g. ANTHROPIC_API_KEY present
    case undetectable(reason: String)      // CLI offers no status probe
}

public struct RunRequest {
    public var prompt: String
    public var workingDirectory: URL
    public var model: String?
    public var permissionPolicy: PermissionPolicy   // .planOnly, .readOnly, .allowTools([...]), .bypassAll
    public var timeout: Duration
    public var maxTurns: Int?
    public var environment: [String: String]
    public var stdin: Data?                          // pipe-in support, size-capped
}

public struct RunResult {
    public let text: String
    public let session: SessionRef?
    public let usage: UsageInfo?         // cost/tokens where the CLI reports them
    public let exitCode: Int32
    public let rawJSON: Data?
}

public struct SessionRef: Codable {      // Codable → host app persists it however it wants
    public let cli: CLIIdentifier
    public let sessionID: String
    public let workingDirectory: URL
    public let createdAt: Date
}
```

### 5.3 Session Store (optional convenience)

A small `SessionStore` protocol with a default file-backed implementation (JSON in Application Support), so apps get restart-safe session recovery for free but can plug in Core Data/SwiftData. The store holds only `SessionRef` metadata, never conversation content. Conversation content lives in the CLI's own storage, which is exactly why resume works.

### 5.4 Events (streaming)

```swift
public enum AgentEvent {
    case sessionStarted(SessionRef)
    case assistantTextDelta(String)
    case toolUseRequested(name: String, input: Data)
    case toolResult(name: String, output: Data)
    case turnCompleted(UsageInfo?)
    case raw(Data)                        // escape hatch: unmapped CLI-specific events
    case finished(RunResult)
}
```

## 6. Functional Requirements

### FR-1 Discovery
- Resolve binaries via login-shell `PATH` resolution (GUI apps on macOS don't inherit the user's shell `PATH`; the library must run `/bin/zsh -lc 'command -v <bin>'` or equivalent, with results cached).
- Report version via each CLI's `--version` and compare against a per-adapter minimum supported version.
- Discovery must never trigger a login prompt or browser window.

### FR-2 Auth / Readiness
- Each adapter implements a **non-interactive, side-effect-free** auth probe. It must never open a browser.
- Probes must have a hard timeout (default 5s) since some CLIs hang waiting for input when unauthenticated. Adapters must force non-TTY stdin and set any available "fail instead of prompt" flags.
- Expose the CLI's own login command so the host app can hand off (`claude auth login`, `codex login`, `gh auth login`, first-run `agy`).
- Distinguish credential *sources* (OAuth login vs env var API key), because they behave differently (env keys bypass profiles, don't show as "logged in" in some CLIs).

### FR-3 Execution
- All runs use the CLI's non-interactive/print mode with structured output where available.
- Process management: `Process` + pipes wrapped in structured concurrency; cooperative cancellation kills the child process tree; per-run timeout; stdout/stderr captured separately; large-output backpressure handled (bounded buffering).
- Exit-code interpretation is adapter-specific and mapped to typed errors (`CLIError.notLoggedIn`, `.turnLimitReached`, `.timeout`, `.crashed(stderr:)`).

### FR-4 Sessions
- Starting a run returns a `SessionRef` when the CLI created a resumable session.
- `resume(_:prompt:)` continues that exact session; adapters must support resuming from a **different process and later point in time**.
- Adapters expose whether sessions are cross-directory or CWD-scoped (this differs per CLI, see matrix) and validate the working directory on resume, surfacing `.sessionExpired` / `.sessionNotFound` as typed errors.
- Opt-out: `RunRequest.persistSession = false` maps to the CLI's no-persistence mode where one exists.

### FR-5 Permission Policy
- `PermissionPolicy` is required on every `RunRequest`; there is no implicit default that grants write access.
- `.bypassAll` (mapping to the various `--dangerously-skip-permissions` style flags) requires an explicit extra acknowledgment in code (e.g. an `unsafe:` label) and logs a warning.

### FR-6 Diagnostics
- A single `HealthReport` API: for each registered CLI → installed / version / auth / last error, suitable for rendering a status screen and for bug reports.
- Structured logging via `os.Logger` with a redaction rule: never log prompts or tokens by default.

## 7. Adapter Matrix (v1)

| Capability | Claude Code (`claude`) | Codex (`codex`) | GitHub (`gh`) | Antigravity (`agy`) |
|---|---|---|---|---|
| Non-interactive run | `claude -p` | `codex exec` | native (all commands) | `agy -p` / `--print` |
| Structured output | `--output-format json` / `stream-json` | `--json` (JSONL) | `--json <fields>` | to verify; treat as text in v1 |
| Session ID source | `session_id` in JSON result | `thread.started` event in JSONL | n/a | conversation ID |
| Resume | `--resume <id>` (works cross-directory), `--continue`, pre-set via `--session-id` | `codex exec resume <id>`; picker/`--last` are CWD-scoped | n/a | `--conversation <id>`, `--continue` |
| Auth probe | `claude auth status` (exit 0 = logged in, 1 = not; JSON default, `--text` for human) | `codex login status` (prints "Not logged in") | `gh auth status` (exit code) | no dedicated probe known; keyring-backed silent login; needs a safe probe strategy |
| Headless/CI auth | `claude setup-token` (long-lived), `ANTHROPIC_API_KEY` | `codex login --with-api-key`; one-off `CODEX_API_KEY` doesn't persist | `GH_TOKEN` env | Google OAuth only (as of writing) |
| Permission flags | `--allowedTools`, `--permission-mode`, `--max-turns` | `--sandbox <mode>` | n/a (auth scopes instead) | allow rules; denies by default in print mode |
| Sessions capability flag | ✅ | ✅ | ❌ (`capabilities.sessions == false`) | ✅ |

Notes:
- **`gh` is deliberately in scope but session-less.** It validates the abstraction: adapters declare capabilities, and the API degrades gracefully (calling `resume` on `gh` throws `.unsupported`).
- **Antigravity is the riskiest adapter** (youngest CLI, auth probe unclear, print-mode conversation semantics changed between versions). Ship it behind an `experimental` flag in v1.
- All flag mappings must be re-verified against the installed CLI version at adapter level; adapters should degrade with a typed `.unsupportedByVersion` error rather than passing unknown flags.

## 8. Non-Functional Requirements

- **Swift 6, strict concurrency**, `Sendable`-clean public API. SPM package, zero third-party dependencies in the core (Foundation + os only).
- **Testability:** every adapter runs against a `ProcessRunner` protocol; unit tests use a fake runner with recorded CLI transcripts (fixtures per CLI version). Integration test target gated behind env flags for CI machines that have the real CLIs.
- **Version resilience:** fixtures + a compatibility table per adapter; CI job that runs the integration suite against latest CLI releases weekly and files issues on drift.
- **Performance:** discovery + auth probes for all four CLIs complete in < 2s combined (parallelized); streaming latency from child stdout to `AgentEvent` < 50ms.
- **Security:** never write tokens; environment passed to children is an explicit allowlist, not `ProcessInfo.processInfo.environment` wholesale.

## 9. Milestones

| Milestone | Scope |
|---|---|
| **M1: Core + Claude adapter** | `AgentCLI` protocol, `ProcessRunner`, discovery, auth, `-p` runs, JSON parsing, `--resume`, streaming via stream-json. Demo CLI target. |
| **M2: Codex + gh adapters** | JSONL event parsing, `thread.started` session extraction, `exec resume`; `gh` as capability-degraded adapter; `SessionStore`. |
| **M3: Antigravity (experimental) + HealthReport** | `agy -p`, `--conversation` resume, probe strategy; diagnostics API; docs site. |
| **M4: Hardening** | Timeout/cancellation edge cases, PATH resolution corner cases, fixture-based version matrix, 1.0 release. |

## 10. Open Questions

1. **Antigravity auth probe:** is there a safe non-interactive command that reveals login state without opening a browser? If not, the fallback is running a trivial `-p` prompt with a short timeout and classifying the failure mode. Needs a spike.
2. **Should the library launch login flows** (open Terminal with the login command, or capture device-flow URLs and surface them in-app)? Leaning yes for v1.1, no for v1.
3. **Linux support scope:** `gh` and `codex` are straightforward; keyring-based CLIs (Antigravity) differ. Decide before M3.
4. **Cost/usage normalization:** Claude reports cost in JSON; others don't or differ. Normalize into `UsageInfo?` or expose raw only?
5. **MCP passthrough:** should `RunRequest` support attaching MCP server configs for Claude/Codex runs? Probably v2.
6. Whether to also offer a thin wrapper around the **Claude Agent SDK** as a "premium" adapter with richer typing, versus staying purely process-based for uniformity.

## 11. Risks

- **CLI churn** is the dominant risk. All four ship breaking changes frequently (Antigravity replaced Gemini CLI entirely in mid-2026). Mitigation: version gating, fixtures, weekly compatibility CI, and treating raw JSON as the escape hatch.
- **Sandbox constraint** limits the addressable market to non-MAS apps. Must be on page one of the README.
- **Hanging children:** unauthenticated or prompt-waiting CLIs can block forever. Mitigation: non-TTY stdin, timeouts everywhere, process-group kill on cancellation.

---

Two design opinions I'd push on if this were a review: keep `gh` in from M2 even though it feels like the odd one out, because it forces the capability-flag design honest early; and resist the temptation to abstract the *event streams* into a lowest common denominator too aggressively — the `raw(Data)` escape hatch plus per-adapter typed events will age far better than a forced unified schema.

Want me to sketch the `ClaudeCodeAdapter` implementation next, or the fixture-based test harness?

Good name. One style note first, then the full naming scheme.

## The `Cli` vs `CLI` question

The Swift API Design Guidelines are explicit here: initialisms that appear all-uppercase in English should be **uniformly cased**, following the standard library and Foundation precedent (`URLSession`, `JSONDecoder`, `NSHTTPURLResponse`, `UUID`). So the guideline-conformant spelling is:

- **`AgenticCLIKit`** — module/package name, initialism fully uppercased
- `cliKit`, `cli` — when the initialism starts a lowercased identifier, it goes fully lowercase (`var cliIdentifier`, never `var cLIIdentifier`)

`AgenticCliKit` (PascalCase-ing the acronym) is the C#/Java convention, not Swift's. It's your library, and `AgenticCliKit` is readable, but reviewers steeped in Swift style will flag it, and it creates awkward derived names (`AgenticCliKitError` reads worse than `AgenticCLIKitError`). My recommendation: **`AgenticCLIKit`**. If you prefer your spelling, at least keep it consistent everywhere, including lowercase positions (`cliKit`, not `cliKit` in one place and `CLIKit` in another).

Below I'll use `AgenticCLIKit`; s/CLI/Cli/ if you overrule.

## Best-in-class Swift naming scheme

| PRD draft name | Swift-idiomatic name | Rationale |
|---|---|---|
| Package/module | `AgenticCLIKit` | Uniform initialism casing; `Kit` suffix matches Apple framework convention |
| `AgentCLI` (protocol) | `AgenticCLI` | Protocols describing *what something is* are nouns; matches module name |
| `CLIIdentifier` | `CLIID` or keep `CLIIdentifier` | Both fine; `CLIIdentifier` is clearer at the call site, double-initialism `CLIID` is ugly |
| `.claudeCode`, `.gitHub` | `.claudeCode`, `.github`, `.codex`, `.antigravity` | Enum cases lowerCamelCase; "GitHub" as a brand compound stays `github` in case position (Apple uses `.github` style in sample code; `gitHub` is also defensible, pick one) |
| `DiscoveryResult` | `Discovery` or `InstallationStatus` | Avoid `Result` suffix on non-`Result` types; it invites confusion with `Swift.Result` |
| `AuthStatus` | `AuthenticationStatus` | Guidelines prefer full words over abbreviations; `auth` is borderline-acceptable, but you have room |
| `RunRequest` / `RunResult` | `RunConfiguration` and return values directly | See API shape note below |
| `SessionRef` | `SessionReference` | No abbreviations; "omit needless words" doesn't mean truncate words |
| `AgentEvent` | `AgentEvent` ✅ | Fine as is |
| `CLIError` | `AgenticCLIError` or nested `AgenticCLI.Error` | Nesting is the modern move: `ClaudeCode.Error`, pattern below |

## API-shape style, beyond names

**Methods read as grammatical phrases at the call site:**

```swift
// Draft (verb-noun soup)
func run(_ request: RunRequest) async throws -> RunResult
func resume(_ session: SessionRef, prompt: String) async throws -> RunResult

// Idiomatic — first argument label completes the sentence
func run(_ prompt: String, configuration: RunConfiguration = .init()) async throws -> AgentResponse
func resume(_ session: SessionReference, with prompt: String) async throws -> AgentResponse
func stream(_ prompt: String, configuration: RunConfiguration = .init()) -> some AsyncSequence<AgentEvent, any Error>
```

`some AsyncSequence<AgentEvent, any Error>` (Swift 6 primary associated types) instead of committing to `AsyncThrowingStream` in the signature — keeps the concrete type an implementation detail.

**Nested types for namespacing instead of prefixes:**

```swift
public enum ClaudeCode {}          // namespace enum

extension ClaudeCode {
    public struct Adapter: AgenticCLI { ... }
    public enum Error: Swift.Error { case notLoggedIn, sessionExpired(SessionReference) }
}
```

This gives you `ClaudeCode.Adapter` and `Codex.Adapter` rather than `ClaudeCodeAdapter`/`CodexCLIAdapter` prefix sprawl.

**Static factory + protocol existentials for ergonomics:**

```swift
let kit = AgenticCLIKit(adapters: [.claudeCode, .codex, .github])
let report = await kit.healthReport()
```

**Boolean and policy naming:** `meetsMinimumVersion` ✅ (reads as assertion), but `PermissionPolicy.bypassAll` should follow the stdlib's "unsafe" convention: `PermissionPolicy.unsafeBypassAll` — the name itself carries the warning, same pattern as `unsafeBitCast`. That's cleaner than an `unsafe:` argument label.

**Capabilities as `OptionSet` rather than struct of Bools:**

```swift
public struct CLICapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public static let sessions          = Self(rawValue: 1 << 0)
    public static let streaming         = Self(rawValue: 1 << 1)
    public static let structuredOutput  = Self(rawValue: 1 << 2)
}
```

**One more:** `HealthReport` is good; the method producing it should be `func healthReport() async -> HealthReport`, not `getHealthReport()` — no `get` prefixes in Swift, ever.

Want me to regenerate the PRD's §5 (API surface) fully rewritten in this style so it's copy-ready as the package's initial `public` API?