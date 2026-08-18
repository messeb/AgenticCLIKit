# Choosing a Model

Ask the installed CLI what it offers, and know how much to trust the answer.

## Overview

Doing nothing is a valid choice, and usually the right one. When ``RunConfiguration/model`` is `nil` no model flag is sent at all, so the CLI runs whatever the user configured — this library does not overrule them.

```swift
var configuration = RunConfiguration.readOnly(in: repositoryURL)
configuration.model            // nil — the user's own default wins
```

To offer a picker, ask what is actually available:

```swift
let models = try await kit.availableModels(for: .antigravity)
models.isCompleteCatalogue     // true — safe to render as an exhaustive list
models.defaultModel            // preselect this

configuration.use(ClaudeCode.Model.opus)
```

## Trust the origin, not just the identifier

Two of the six CLIs can genuinely enumerate their models, so every entry carries an ``AgentModel/Origin`` saying where it came from.

| `origin` | Meaning | Source |
|---|---|---|
| ``AgentModel/Origin/catalog`` | Authoritative and complete | `agy models` or `grok models` |
| ``AgentModel/Origin/bundled`` | Maintained in this package | ``ClaudeCode/Model``, ``Codex/Model``, ``Vibe/Model`` |
| ``AgentModel/Origin/configuration`` | The user's configured default | `~/.codex/config.toml`, `~/.vibe/config.toml` |
| ``AgentModel/Origin/documentation`` | An alias the installed binary documents | the `--model` paragraph of `claude --help` |

An app can branch on this: render a closed picker when ``Swift/Array/isCompleteCatalogue`` is `true`, and a combo box with a free-text field otherwise.

## Why two lists are hand-maintained

Neither `claude` nor `codex` can be asked:

- **`claude models` is not a subcommand.** The word is taken as a *prompt*, so it spends a billable turn and replies conversationally. Its output looks like a model list and cannot be trusted as one, so the adapter never calls it.
- **`codex models` exits 1** with "stdin is not a terminal", and neither `--help` nor `exec --help` documents valid `--model` values.

So ``ClaudeCode/Model`` and ``Codex/Model`` are ordinary enums, conforming to ``KnownModel``. Adding a model is adding a case. ``Antigravity`` ships no such list, because a maintained copy of a catalogue it can fetch live would only ever be a stale duplicate.

Three things are still read from the machine and merged in, because they *are* knowable: the aliases `claude --help` documents, the model in Codex's own `config.toml`, and the `[[models]]` aliases in Vibe's.

## Vibe: aliases, and a wrong one is silent

``Vibe/Model`` lists what a fresh `vibe` install ships with, and the user's `~/.vibe/config.toml` contributes the rest. Both halves matter, because `vibe` addresses models by the **alias** in that file rather than by the provider's name — the default entry is named `mistral-vibe-cli-latest` and aliased `mistral-medium-3.5`.

`vibe` also has no `--model` flag. The alias travels in `VIBE_ACTIVE_MODEL`, and an alias `vibe` does not recognise is *ignored*: the run silently proceeds on the default model. ``Vibe/Adapter`` therefore checks the requested alias against the bundled list plus `config.toml` and throws ``AgenticCLIError/unsupportedModel(_:model:reason:)`` rather than letting a run bill on a model nobody chose. This is the one adapter where a model outside the list is refused — everywhere else the list is a convenience.

## The list is never a constraint

``RunConfiguration/model`` is a plain `String`. A model released after this package was tagged works today:

```swift
configuration.model = "claude-opus-6"   // no library update required
```

This is deliberate: the enums exist to populate a picker and to document what was current, never to gate what you can run.

``Vibe`` is the exception, and only because `vibe` makes the alternative worse: it ignores an alias it does not know instead of failing, so an unchecked value would run and bill on the wrong model. The check is against the user's `config.toml` as well as the bundled list, so a model added there needs no library update either — it just has to exist somewhere `vibe` will actually find it.

## CLIs without models

``Copilot/Model`` lists GitHub's documented models with the identifiers the CLI's own catalogue uses — which are not always what the display names suggest, so they are pinned by test. Group them with ``Copilot/Model/models(from:)`` when building a picker.

Listing is not availability: Copilot resolves an available set per account at launch, and each model carries terms that must be accepted once before `--model` will take it. ``Copilot/Model/auto`` is the default because it is the one value that works regardless. A refusal surfaces as ``AgenticCLIError/unsupportedModel(_:model:reason:)``, whose reason names the actual fix.

A CLI that cannot report models at all throws ``AgenticCLIError/unsupportedCapability(_:_:)``. ``AgenticCLIKit/AgenticCLIKit/availableModelsByCLI()`` omits it rather than failing the whole call, so one model-less adapter never denies an app the pickers it can build for the others.

Antigravity's catalogue needs the network and valid credentials; when it cannot be fetched, ``AgenticCLI/availableModels()`` throws rather than returning a guess that would look authoritative.
