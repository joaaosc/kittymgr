import Foundation

/// Severity of a single `doctor` check.
public enum DoctorStatus: String, Sendable, Equatable {
    case ok = "OK"
    case warn = "WARN"
    case fail = "FAIL"
}

/// One line of the `doctor` report.
public struct DoctorFinding: Sendable, Equatable {
    public let status: DoctorStatus
    public let name: String
    public let detail: String

    public init(_ status: DoctorStatus, _ name: String, _ detail: String) {
        self.status = status
        self.name = name
        self.detail = detail
    }
}

/// Non-mutating probes of external tools. Injectable so `doctor` is testable
/// without kitty or git installed and without touching a live kitty.
public protocol EnvironmentProbing: Sendable {
    /// Whether an executable named `tool` is resolvable on `PATH`.
    func toolAvailable(_ tool: String) -> Bool
    /// Whether kitty remote control answers a read-only query (`kitten @ ls`).
    func remoteControlResponds() -> Bool
}

/// Default probe: a pure `PATH` scan for tools (no subprocess) and a read-only
/// `kitten @ ls` / `kitty @ ls` for remote control.
public struct SystemEnvironmentProbe: EnvironmentProbing {
    public init() {}

    public func toolAvailable(_ tool: String) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let fm = FileManager.default
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate.path) { return true }
        }
        return false
    }

    public func remoteControlResponds() -> Bool {
        for tool in ["kitten", "kitty"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [tool, "@", "ls"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        }
        return false
    }
}

/// `doctor`: report on the health of the environment and the managed store,
/// independent of any single profile's config validity (`check` covers that).
///
/// Optional environment pieces (kitty, git, remote control) are `WARN` when absent
/// — kittymgr still works offline. Corruption in the managed store (a snapshot
/// missing its backing object) is `FAIL`. `run` returns `true` only when there is
/// no `FAIL`, which the CLI maps to a non-zero exit.
public struct DoctorCommand {
    public let configDir: ConfigDir
    public let probe: any EnvironmentProbing

    public init(configDir: ConfigDir, probe: any EnvironmentProbing = SystemEnvironmentProbe()) {
        self.configDir = configDir
        self.probe = probe
    }

    /// Runs every check, prints the report, and returns `true` when nothing failed.
    @discardableResult
    public func run(log: (String) -> Void = { print($0) }) -> Bool {
        let findings = environmentFindings() + managedLayerFindings() + integrityFindings()

        for finding in findings {
            log("[\(finding.status.rawValue)] \(finding.name): \(finding.detail)")
        }
        let fails = findings.filter { $0.status == .fail }.count
        let warns = findings.filter { $0.status == .warn }.count
        log("")
        log("doctor: \(findings.count - fails - warns) ok, \(warns) warning(s), \(fails) failure(s).")
        return fails == 0
    }

    // MARK: Checks

    private func environmentFindings() -> [DoctorFinding] {
        [
            probe.toolAvailable("kitty")
                ? DoctorFinding(.ok, "kitty", "found on PATH")
                : DoctorFinding(.warn, "kitty", "not found on PATH; config validation and live reload are skipped"),
            probe.toolAvailable("git")
                ? DoctorFinding(.ok, "git", "found on PATH")
                : DoctorFinding(.warn, "git", "not found on PATH; git sources cannot be fetched"),
            probe.remoteControlResponds()
                ? DoctorFinding(.ok, "remote control", "kitty responds; live reload available")
                : DoctorFinding(.warn, "remote control", "no response; switch/sync persist but reload is manual (needs a running kitty with allow_remote_control)"),
        ]
    }

    private func managedLayerFindings() -> [DoctorFinding] {
        let fm = FileManager.default
        let layout = configDir.detectedLayout(fileManager: fm)
        switch layout {
        case .absent:
            return [DoctorFinding(.warn, "layout", "not initialized; run `kittymgr init`")]
        case .legacy:
            return [
                DoctorFinding(
                    .warn,
                    "layout",
                    "legacy layout at managed/; run `kittymgr init` to migrate to kittymgr/"
                ),
            ]
        case .mixed(let detail):
            return [
                DoctorFinding(
                    .fail,
                    "layout",
                    "mixed layout detected (\(detail)); repair manually, then run `kittymgr init`"
                ),
            ]
        case .current:
            break
        }
        var out = [
            DoctorFinding(.ok, "layout", "new layout at \(configDir.relativePath(of: configDir.managedDir))/"),
            DoctorFinding(.ok, "managed layer", "present at \(configDir.relativePath(of: configDir.managedDir))"),
        ]

        if let content = try? String(contentsOf: configDir.kittyConf, encoding: .utf8) {
            out.append(Guard.containsCurrentInclude(in: content)
                ? DoctorFinding(.ok, "kitty.conf block", "managed include block present")
                : DoctorFinding(.warn, "kitty.conf block", "managed block missing from kitty.conf; run `kittymgr init`"))
        } else {
            out.append(DoctorFinding(.warn, "kitty.conf block", "kitty.conf not found; run `kittymgr init`"))
        }
        return out
    }

    private func integrityFindings() -> [DoctorFinding] {
        var out: [DoctorFinding] = []

        if FileManager.default.fileExists(atPath: configDir.lockFile.path) {
            let lock = Lockfile.load(configDir.lockFile)
            out.append(DoctorFinding(.ok, "lockfile", "\(lock.sources.count) pinned source(s)"))
        }

        let store = SnapshotStore(configDir: configDir)
        let snapshots = store.list()
        if !snapshots.isEmpty {
            let missing = store.missingObjects()
            out.append(missing.isEmpty
                ? DoctorFinding(.ok, "backups", "\(snapshots.count) snapshot(s), all objects present")
                : DoctorFinding(.fail, "backups", "\(missing.count) snapshot object(s) missing from the store"))
        }
        return out
    }
}
