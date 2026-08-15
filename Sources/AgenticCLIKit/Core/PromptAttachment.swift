import Foundation

/// Something to put in front of the agent along with the prompt: a PDF on disk,
/// a screenshot, a document at a URL, or bytes the app already holds.
///
/// ```swift
/// var configuration = RunConfiguration.readOnly(in: workingDirectory)
/// configuration.attachments = [
///     .file(invoiceURL, description: "the invoice to summarise"),
///     .remote(URL(string: "https://example.com/spec.pdf")!),
///     .data(screenshot, filename: "screen.png"),
/// ]
/// ```
public struct PromptAttachment: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// A file already on disk.
        case file(URL)
        /// A file to download before the run. Fetched by the kit, not by the
        /// agent, so the bytes are identical for every CLI and the run works
        /// even when the agent has no web access.
        case remote(URL)
        /// Bytes the app holds in memory, written to a scratch file for the run.
        case data(Data, filename: String)
    }

    /// What kind of thing this is, which decides whether a CLI can attach it
    /// natively or has to read it from disk.
    public enum Kind: String, Sendable, Hashable, Codable {
        case image
        case document
        case text
        case other
    }

    public var source: Source
    /// Overrides the kind inferred from the file extension.
    public var kind: Kind?
    /// What this file is, in the prompt. "the invoice to summarise" reads
    /// better to a model than a bare path.
    public var description: String?

    public init(source: Source, kind: Kind? = nil, description: String? = nil) {
        self.source = source
        self.kind = kind
        self.description = description
    }

    public static func file(_ url: URL, kind: Kind? = nil, description: String? = nil) -> PromptAttachment {
        PromptAttachment(source: .file(url), kind: kind, description: description)
    }

    public static func remote(_ url: URL, kind: Kind? = nil, description: String? = nil) -> PromptAttachment {
        PromptAttachment(source: .remote(url), kind: kind, description: description)
    }

    public static func data(
        _ data: Data,
        filename: String,
        kind: Kind? = nil,
        description: String? = nil
    ) -> PromptAttachment {
        PromptAttachment(source: .data(data, filename: filename), kind: kind, description: description)
    }

    /// The name this attachment will have on disk.
    public var filename: String {
        switch source {
        case let .file(url), let .remote(url):
            return url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
        case let .data(_, filename):
            return filename
        }
    }

    /// The declared kind, or one inferred from the file extension.
    public var resolvedKind: Kind {
        kind ?? Kind(inferringFrom: filename)
    }
}

extension PromptAttachment.Kind {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "docx", "doc", "pages", "key", "pptx", "xlsx", "numbers", "epub", "rtf",
    ]
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "csv", "tsv", "xml",
        "html", "log", "swift", "py", "js", "ts", "rs", "go", "java", "kt", "c", "cpp", "h",
    ]

    init(inferringFrom filename: String) {
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(fileExtension) {
            self = .image
        } else if Self.documentExtensions.contains(fileExtension) {
            self = .document
        } else if Self.textExtensions.contains(fileExtension) {
            self = .text
        } else {
            self = .other
        }
    }
}

/// An attachment that has been made local and verified to exist.
public struct ResolvedAttachment: Sendable, Hashable {
    /// Absolute path to the file, inside the run's scratch directory for
    /// downloads and in-memory data.
    public let url: URL
    public let kind: PromptAttachment.Kind
    public let description: String?
    public let byteCount: Int
    /// Where it came from, when that is not the same as ``url``.
    public let origin: URL?

    public init(
        url: URL,
        kind: PromptAttachment.Kind,
        description: String? = nil,
        byteCount: Int,
        origin: URL? = nil
    ) {
        self.url = url
        self.kind = kind
        self.description = description
        self.byteCount = byteCount
        self.origin = origin
    }
}
