# Releasing

Releases are cut by hand, in two steps, from a short-lived branch. `main` is the only long-lived branch.

```text
main ──────────────────────────────────────────────●───────▶
        │                                          ▲
        │ Prepare Release 1.2.0                    │ PR merged
        ▼                                          │
   release/1.2.0 ──●────────●────────●─────────────┘
                   │        │        │
                 1.2.0-rc  1.2.0-rc  1.2.0
                (replaced)(replaced) (final, via Release)
```

## One-time repository setup

Both workflows depend on settings that are off by default:

| Setting | Where | Needed for |
|---|---|---|
| **Allow GitHub Actions to create and approve pull requests** | Settings → Actions → General → Workflow permissions | The Release workflow's PR back to `main` |
| **Pages source: GitHub Actions** | Settings → Pages | Publishing documentation |
| Labels `chore`, `fix`, `feature`, `breaking-change`, `compatibility`, `refactor`, `triage`, `ignore-for-release` | Issues → Labels | The release PR label and the generated release-note categories |

```bash
gh api --method PUT repos/messeb/AgenticCLIKit/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true
gh api --method POST repos/messeb/AgenticCLIKit/pages -f build_type=workflow
```

Both release workflows are safe to re-run. If a step fails partway — the PR step is the usual one — fix the cause and run the workflow again with the same version; an already-published release is skipped rather than treated as an error.

## Step 1 — Prepare Release

**Actions → Prepare Release → Run workflow**, with a version like `1.2.0`.

The workflow:

1. Creates `release/1.2.0` from `main`, or reuses it if it already exists.
2. Stamps the version into `Sources/AgenticCLIKit/Version.swift` and promotes the `[Unreleased]` section of `CHANGELOG.md` to `[1.2.0]`.
3. Builds warning-free and runs the tests.
4. Pushes the branch.
5. Publishes `1.2.0-rc` as a GitHub **pre-release** pointing at the branch head.

Consumers can try the candidate:

```swift
.package(url: "https://github.com/messeb/AgenticCLIKit.git", exact: "1.2.0-rc")
```

### Iterating on a candidate

Push fixes to `release/1.2.0` — through a PR, or directly if you have the access — and **run Prepare Release again with the same version**. The `1.2.0-rc` tag and its pre-release are deleted and recreated at the new branch head, so the candidate always matches the branch.

Nothing else is affected: `main` is untouched until step 2's PR is merged.

## Step 2 — Release

**Actions → Release → Run workflow**, with the same version.

The workflow:

1. Verifies `release/1.2.0` exists, is stamped with `1.2.0`, and has not already been released.
2. Builds warning-free and runs the tests again.
3. Creates the `1.2.0` tag and GitHub release from the branch.
4. Opens a pull request from `release/1.2.0` into `main`.

Merge that pull request to bring the version stamp and changelog back to `main`. The `1.2.0-rc` tag stays as the record of what was tested.

## After the release

- The **Documentation** workflow republishes GitHub Pages on every published release.
- Swift Package Index picks up the new tag automatically.
- Delete the `release/1.2.0` branch once the PR is merged.

## Versioning

[Semantic Versioning](https://semver.org). For this package specifically:

- **Major** — a source-breaking change to the public API.
- **Minor** — new capability, a new adapter, or a new supported CLI version.
- **Patch** — fixes, including re-recorded fixtures and adjusted flag mappings that keep the same public behaviour.

An adapter that stops supporting an old CLI release raises `minimumSupportedVersion`. That is a **minor** change: callers see a typed `.unsupportedVersion` error rather than a compile failure.

## Hotfixes

Branch `release/1.2.1` from the `1.2.0` tag rather than from `main`, then run the same two steps. Cherry-pick the fix onto `main` if it is not already there.

## Doing it locally

The version stamp is a plain script, so a release can be rehearsed without CI:

```bash
./Scripts/set-version.sh 1.2.0
git diff
```

It is idempotent — running it twice with the same version changes nothing the second time, which is what makes re-running Prepare Release safe.
