import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A scratch directory that lives exactly as long as one run.
///
/// Downloads, in-memory attachments, and schema files that a CLI insists on
/// reading from disk all land here, and the whole directory is removed when the
/// run ends — including when it fails or is cancelled.
final class RunWorkspace: @unchecked Sendable {
    let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.directory = fileManager.temporaryDirectory
            .appendingPathComponent("agenticclikit-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes a schema for CLIs that take a file path rather than an inline string.
    func writeSchema(_ schema: JSONSchema) throws -> URL {
        let url = directory.appendingPathComponent("output-schema.json")
        try schema.jsonData().write(to: url, options: [.atomic])
        return url
    }

    func write(_ data: Data, named filename: String) throws -> URL {
        let url = directory.appendingPathComponent(sanitised(filename))
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Strips path separators so a caller-supplied filename cannot escape the
    /// scratch directory.
    private func sanitised(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "attachment" : cleaned
    }

    func destroy() {
        try? fileManager.removeItem(at: directory)
    }
}

/// Turns ``PromptAttachment`` values into files on disk that any CLI can read.
struct AttachmentResolver: Sendable {
    /// Refuses anything larger than this, rather than letting a 2 GB download
    /// fill the user's disk or blow past a model's limits.
    let maximumByteCount: Int
    let downloadTimeout: Duration
    private let session: URLSession

    init(
        maximumByteCount: Int = 32 * 1024 * 1024,
        downloadTimeout: Duration = .seconds(60),
        session: URLSession = .shared
    ) {
        self.maximumByteCount = maximumByteCount
        self.downloadTimeout = downloadTimeout
        self.session = session
    }

    func resolve(
        _ attachments: [PromptAttachment],
        into workspace: RunWorkspace,
        cli: CLIIdentifier
    ) async throws -> [ResolvedAttachment] {
        var resolved: [ResolvedAttachment] = []
        resolved.reserveCapacity(attachments.count)
        for attachment in attachments {
            resolved.append(try await resolve(attachment, into: workspace, cli: cli))
        }
        return resolved
    }

    private func resolve(
        _ attachment: PromptAttachment,
        into workspace: RunWorkspace,
        cli: CLIIdentifier
    ) async throws -> ResolvedAttachment {
        switch attachment.source {
        case let .file(url):
            let path = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                throw AgenticCLIError.attachmentUnavailable(url, reason: "File does not exist")
            }
            guard !isDirectory.boolValue else {
                throw AgenticCLIError.attachmentUnavailable(
                    url,
                    reason: "Attachments must be files; use RunConfiguration.additionalDirectories for folders"
                )
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? Int) ?? 0
            try checkSize(size, for: url)
            return ResolvedAttachment(
                url: path,
                kind: attachment.resolvedKind,
                description: attachment.description,
                byteCount: size
            )

        case let .remote(url):
            let data = try await download(url)
            try checkSize(data.count, for: url)
            let local = try workspace.write(data, named: attachment.filename)
            return ResolvedAttachment(
                url: local,
                kind: attachment.kind ?? PromptAttachment.Kind(inferringFrom: local.lastPathComponent),
                description: attachment.description,
                byteCount: data.count,
                origin: url
            )

        case let .data(data, filename):
            try checkSize(data.count, for: URL(fileURLWithPath: filename))
            let local = try workspace.write(data, named: filename)
            return ResolvedAttachment(
                url: local,
                kind: attachment.resolvedKind,
                description: attachment.description,
                byteCount: data.count
            )
        }
    }

    private func checkSize(_ byteCount: Int, for url: URL) throws {
        guard byteCount <= maximumByteCount else {
            throw AgenticCLIError.attachmentTooLarge(url, byteCount: byteCount, limit: maximumByteCount)
        }
    }

    private func download(_ url: URL) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AgenticCLIError.attachmentUnavailable(url, reason: "Only http and https URLs can be fetched")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = downloadTimeout.seconds
        request.setValue("AgenticCLIKit", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AgenticCLIError.attachmentUnavailable(url, reason: "HTTP \(http.statusCode)")
            }
            return data
        } catch let error as AgenticCLIError {
            throw error
        } catch {
            throw AgenticCLIError.attachmentUnavailable(url, reason: error.localizedDescription)
        }
    }
}

extension ResolvedAttachment {
    /// The prompt preamble that tells the agent what it has and where.
    ///
    /// Every adapter uses the same wording, so switching CLIs does not change
    /// how the model is told about its inputs. Adapters that can attach a file
    /// natively (Codex passes images with `-i`) still list it here, because the
    /// path is what the model refers to when it answers.
    static func promptPreamble(for attachments: [ResolvedAttachment]) -> String {
        guard !attachments.isEmpty else { return "" }

        var lines = attachments.count == 1
            ? ["The following file is attached for this task. Read it before answering."]
            : ["The following files are attached for this task. Read them before answering."]

        for (index, attachment) in attachments.enumerated() {
            var line = "\(index + 1). \(attachment.url.path)"
            if let description = attachment.description {
                line += " — \(description)"
            } else if let origin = attachment.origin {
                line += " — downloaded from \(origin.absoluteString)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Directories that must be readable for the agent to open these files.
    ///
    /// A file outside the working directory is invisible to a sandboxed agent
    /// unless its directory is granted explicitly.
    static func requiredDirectories(
        for attachments: [ResolvedAttachment],
        workingDirectory: URL
    ) -> [URL] {
        let root = workingDirectory.standardizedFileURL.path
        var directories: [URL] = []
        var seen: Set<String> = []

        for attachment in attachments {
            let parent = attachment.url.deletingLastPathComponent().standardizedFileURL
            guard !parent.path.hasPrefix(root) else { continue }
            guard seen.insert(parent.path).inserted else { continue }
            directories.append(parent)
        }
        return directories
    }
}
