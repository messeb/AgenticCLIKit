# Attachments

Put files, data, or URLs in front of the agent.

## Overview

```swift
var configuration = RunConfiguration.readOnly(in: workingDirectory)
configuration.attachments = [
    .file(invoiceURL, description: "the invoice to summarise"),
    .remote(URL(string: "https://example.com/spec.pdf")!),
    .data(screenshotPNG, filename: "screen.png"),
]

let response = try await kit.run(
    "What is the total on the invoice?",
    using: .claudeCode,
    configuration: configuration
)
```

## What happens to each kind

- **``PromptAttachment/file(_:kind:description:)``** is used in place; nothing is copied.
- **``PromptAttachment/remote(_:kind:description:)``** is downloaded *by the kit*, not by the agent. The bytes are then identical for every CLI, and the run works even when the agent has no web access.
- **``PromptAttachment/data(_:filename:kind:description:)``** is written into a per-run scratch directory that is removed when the run ends.

Each attachment is then announced in a preamble listing absolute paths and your descriptions, and any directory outside the working directory is granted through the CLI's own `--add-dir`. Codex additionally passes images through its native `--image` flag; the others read them from disk.

The preamble is identical across adapters, so switching CLIs does not change how the model is told about its inputs.

## Guardrails

All of these fail *before* the CLI is spawned, with a typed error:

- a missing file, or a directory instead of a file — ``AgenticCLIError/attachmentUnavailable(_:reason:)``
- a non-HTTP URL, or a failed download
- anything over ``RunConfiguration/maximumAttachmentBytes`` (32 MB by default) — ``AgenticCLIError/attachmentTooLarge(_:byteCount:limit:)``

Caller-supplied filenames are sanitised so they cannot escape the scratch directory.

`gh` cannot read attachments and declares no ``CLICapabilities/fileAttachments``, so it throws ``AgenticCLIError/unsupportedCapability(_:_:)``.

## Folders

Attachments are files. To give an agent a whole directory, use ``RunConfiguration/additionalDirectories`` instead — that grants access without listing every file in the prompt.
