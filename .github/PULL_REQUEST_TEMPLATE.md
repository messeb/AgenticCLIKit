## Description

<!-- What does this PR do, and why? -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Adapter update (CLI flags, parsing, or capabilities changed)
- [ ] Breaking change
- [ ] Documentation

## Testing

- [ ] `swift test` passes
- [ ] Build is warning-free
- [ ] Unit tests added or updated

### For adapter changes

- [ ] Verified against the real CLI (`AGENTICCLIKIT_LIVE=1 swift test`)
- [ ] Fixtures re-recorded from real CLI output, not written by hand
- [ ] CLI version noted in the adapter's doc comment and in `Fixtures.swift`
- [ ] `capabilities` and `minimumSupportedVersion` still accurate

<!-- Which CLI and version did you verify against? -->

## Checklist

- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] No permission policy is silently widened
- [ ] Public API changes are documented
- [ ] Conventional commit messages used
