import Foundation

/// A proposed change to the managed surface: files to (over)write and files to
/// delete, keyed by path relative to the kitty config directory.
public struct ApplyPlan: Equatable {
    public var writes: [String: String]
    public var deletes: [String]

    public init(writes: [String: String] = [:], deletes: [String] = []) {
        self.writes = writes
        self.deletes = deletes
    }

    public var isEmpty: Bool { writes.isEmpty && deletes.isEmpty }
}

/// Transactional apply pipeline: snapshot → atomic write → validate → reload or
/// rollback.
///
/// A change is only kept if kitty's own validation accepts it (or validation is
/// unavailable and degrades to skipped). An invalid change is reverted to the
/// pre-apply snapshot, so the managed surface is restored byte-for-byte and the
/// live session is never asked to reload a rejected configuration.
///
/// Validation runs *after* the atomic write so what is validated is exactly what
/// lands on disk; the pre-apply snapshot (from the backup subsystem) is the
/// rollback point. `--dry-run` short-circuits before any write and prints the
/// unified diff of the plan instead.
public struct ApplyTransaction {
    public enum Status: Equatable {
        case applied
        case previewed
    }

    public struct Result: Equatable {
        public let status: Status
        public let snapshotID: String?
        public let validation: ValidationResult
        public let reload: ReloadOutcome?
    }

    public let snapshotStore: SnapshotStore
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        snapshotStore: SnapshotStore,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.snapshotStore = snapshotStore
        self.validator = validator
        self.reloader = reloader
    }

    /// Apply `plan` transactionally.
    ///
    /// - Parameters:
    ///   - plan: files to write/delete on the managed surface.
    ///   - validationContent: the composed configuration handed to kitty for
    ///     validation (the inlined document that mirrors what kitty will load).
    ///   - dryRun: when `true`, print the unified diff and a validation preview,
    ///     writing nothing.
    ///   - reload: trigger a live reload after a kept change.
    /// - Throws: `SafetyError.invalidConfiguration` after rolling back when
    ///   validation rejects the written change.
    @discardableResult
    public func apply(
        plan: ApplyPlan,
        validationContent: String,
        dryRun: Bool,
        reload: Bool = true,
        log: (String) -> Void = { print($0) }
    ) throws -> Result {
        if dryRun {
            return preview(plan: plan, validationContent: validationContent, log: log)
        }

        // 1. Capture the pre-apply snapshot — the rollback point.
        let snapshot = try snapshotStore.create(label: "pre-apply")

        // 2. Write the candidate atomically (temp + rename per file).
        do {
            try write(plan)
        } catch {
            try? snapshotStore.restore(snapshot)
            throw error
        }

        // 3. Validate exactly what now sits on disk.
        let validation = validator.validate(content: validationContent)
        if case let .invalid(diagnostics) = validation {
            try snapshotStore.restore(snapshot)
            log("Change rejected by validation; rolled back to snapshot \(snapshot.id).")
            throw SafetyError.invalidConfiguration(diagnostics)
        }
        if case let .skipped(reason) = validation {
            log("Validation skipped (\(reason)).")
        }

        // 4. Keep the change; reload the live session.
        var reloadOutcome: ReloadOutcome?
        if reload {
            let outcome = reloader.reload()
            reloadOutcome = outcome
            report(outcome, log: log)
        }
        return Result(status: .applied, snapshotID: snapshot.id, validation: validation, reload: reloadOutcome)
    }

    // MARK: Preview

    private func preview(plan: ApplyPlan, validationContent: String, log: (String) -> Void) -> Result {
        let current = snapshotStore.currentContents()
        var proposed = current
        for (path, content) in plan.writes { proposed[path] = content }
        for path in plan.deletes { proposed[path] = nil }

        let diff = UnifiedDiff.diffStates(old: current, new: proposed)
        log(diff.isEmpty ? "[dry-run] No changes." : "[dry-run] This change would apply:\n" + diff)

        // Validation never touches the managed surface, so it is safe to preview.
        let validation = validator.validate(content: validationContent)
        switch validation {
        case .valid:
            log("[dry-run] Validation: would pass.")
        case let .invalid(diagnostics):
            log("[dry-run] Validation: would FAIL and roll back:\n\(diagnostics)")
        case let .skipped(reason):
            log("[dry-run] Validation skipped (\(reason)).")
        }
        return Result(status: .previewed, snapshotID: nil, validation: validation, reload: nil)
    }

    // MARK: Write

    private func write(_ plan: ApplyPlan) throws {
        let fm = FileManager.default
        let root = snapshotStore.configDir.url
        for (relativePath, content) in plan.writes {
            let destination = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ConfigStore.writeAtomically(content, to: destination)
        }
        for relativePath in plan.deletes {
            let destination = root.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
        }
    }

    private func report(_ outcome: ReloadOutcome, log: (String) -> Void) {
        switch outcome {
        case .reloaded:
            log("Reloaded kitty configuration.")
        case let .unavailable(reason):
            log("Change applied. Live reload unavailable: \(reason)")
            log("Reload manually with `kitten @ load-config`, restart kitty, or send SIGUSR1 to the kitty process.")
        }
    }
}
