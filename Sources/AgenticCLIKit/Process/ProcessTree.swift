#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Kills a child process *and everything it spawned*.
///
/// This matters more than it looks. Agentic CLIs are process trees: `claude`
/// spawns shells, which spawn build tools. Signalling only the direct child
/// leaves orphaned compilers running long after the host app thinks the run was
/// cancelled.
enum ProcessTree {
    /// Terminates `pid` and its descendants: `SIGTERM` first, then `SIGKILL`
    /// for whatever is still alive after `gracePeriod`.
    ///
    /// Safe to call on an already-dead process.
    static func terminate(pid: pid_t, gracePeriod: Duration) async {
        guard pid > 0 else { return }

        let targets = terminationTargets(for: pid)
        signal(targets, with: SIGTERM)

        // Give the tree a chance to shut down cleanly; agents flush session
        // state on SIGTERM, and killing outright loses the resumable session.
        let deadline = ContinuousClock().now + gracePeriod
        while ContinuousClock().now < deadline {
            if !isAlive(pid) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }

        signal(terminationTargets(for: pid), with: SIGKILL)
    }

    /// Synchronous best-effort kill, for teardown paths that cannot await —
    /// notably `AsyncStream` termination handlers.
    static func terminateImmediately(pid: pid_t) {
        guard pid > 0 else { return }
        signal(terminationTargets(for: pid), with: SIGTERM)
    }

    private enum Target {
        case processGroup(pid_t)
        case processes([pid_t])
    }

    /// Prefers a single process-group signal, which reaches descendants the
    /// process table walk might race against. Falls back to an explicit
    /// descendant list when the child shares our own group.
    private static func terminationTargets(for pid: pid_t) -> Target {
        let childGroup = getpgid(pid)
        if childGroup > 0, childGroup != getpgid(0), childGroup == pid {
            return .processGroup(childGroup)
        }
        return .processes(descendants(of: pid) + [pid])
    }

    private static func signal(_ target: Target, with signalNumber: Int32) {
        switch target {
        case let .processGroup(group):
            _ = kill(-group, signalNumber)
        case let .processes(pids):
            // Leaves first, so a parent cannot respawn a child we already killed.
            for pid in pids.reversed() {
                _ = kill(pid, signalNumber)
            }
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Breadth-first walk of the process table, deepest descendants last.
    static func descendants(of root: pid_t) -> [pid_t] {
        let table = processTable()
        guard !table.isEmpty else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for entry in table {
            childrenByParent[entry.parent, default: []].append(entry.pid)
        }

        var found: [pid_t] = []
        var queue = childrenByParent[root] ?? []
        var visited: Set<pid_t> = [root]
        while let next = queue.first {
            queue.removeFirst()
            guard visited.insert(next).inserted else { continue }
            found.append(next)
            queue.append(contentsOf: childrenByParent[next] ?? [])
        }
        return found
    }

    struct ProcessEntry {
        let pid: pid_t
        let parent: pid_t
    }

    #if canImport(Darwin)
    /// Reads the kernel process table directly. Spawning `ps` to clean up after
    /// a runaway process would be its own kind of irony.
    static func processTable() -> [ProcessEntry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&name, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] }

        // The table can grow between sizing and reading; ask for headroom.
        let stride = MemoryLayout<kinfo_proc>.stride
        var capacity = length / stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        length = capacity * stride
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&name, 4, raw.baseAddress, &length, nil, 0)
        }
        guard status == 0 else { return [] }

        capacity = length / stride
        return (0..<capacity).map { index in
            ProcessEntry(
                pid: buffer[index].kp_proc.p_pid,
                parent: buffer[index].kp_eproc.e_ppid
            )
        }
    }
    #else
    static func processTable() -> [ProcessEntry] {
        let procDirectory = URL(fileURLWithPath: "/proc")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: procDirectory.path) else {
            return []
        }
        return entries.compactMap { entry in
            guard let pid = pid_t(entry) else { return nil }
            let statPath = procDirectory.appendingPathComponent(entry).appendingPathComponent("stat")
            guard let stat = try? String(contentsOf: statPath, encoding: .utf8) else { return nil }
            // Field 4 is ppid, but the comm field (2) may contain spaces and parentheses.
            guard let commEnd = stat.lastIndex(of: ")") else { return nil }
            let fields = stat[stat.index(after: commEnd)...]
                .split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let parent = pid_t(fields[1]) else { return nil }
            return ProcessEntry(pid: pid, parent: parent)
        }
    }
    #endif
}
