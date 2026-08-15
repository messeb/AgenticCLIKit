import Foundation

/// Reassembles newline-delimited records from arbitrary pipe chunks.
///
/// Pipe reads split wherever the kernel feels like it, routinely mid-JSON-object.
/// Every JSONL-parsing adapter needs this, and getting it wrong shows up as
/// intermittent, output-size-dependent parse failures.
struct LineAccumulator {
    private var buffer = Data()
    /// Guards against a CLI that emits an unbounded line with no newline.
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 16 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// Appends a chunk and returns every complete line it completed.
    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        guard buffer.count <= maximumLineBytes else {
            // Emit what we have rather than growing without bound.
            let line = decode(buffer)
            buffer.removeAll(keepingCapacity: false)
            return line.map { [$0] } ?? []
        }

        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = buffer[buffer.index(after: newlineIndex)...]
            if let line = decode(Data(lineData)) {
                lines.append(line)
            }
        }
        // Re-base the buffer so repeated slicing does not keep the whole stream alive.
        buffer = Data(buffer)
        return lines
    }

    /// Returns any trailing content not terminated by a newline. A CLI that
    /// exits without a final newline is common enough to matter.
    mutating func flush() -> String? {
        defer { buffer.removeAll(keepingCapacity: false) }
        return decode(buffer)
    }

    private func decode(_ data: Data) -> String? {
        var slice = data
        if slice.last == UInt8(ascii: "\r") {
            slice = slice.dropLast()
        }
        guard !slice.isEmpty else { return nil }
        let text = String(decoding: slice, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
    }
}
