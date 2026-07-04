import Foundation
import Testing
@testable import KittymgrCore

struct ProcessRunnerTests {
    private func sh(_ script: String, timeout: TimeInterval = 10) throws -> ProcessOutput {
        try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: timeout
        )
    }

    @Test func capturesBothStreamsAndStatus() throws {
        let result = try sh("printf out; printf err >&2")
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err")
        #expect(!result.timedOut)
    }

    @Test func reportsExitCode() throws {
        let result = try sh("exit 3")
        #expect(result.status == 3)
        #expect(!result.timedOut)
    }

    @Test func missingExecutableThrows() {
        #expect(throws: (any Error).self) {
            try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/nonexistent/tool-\(UUID().uuidString)"),
                arguments: [],
                timeout: 5
            )
        }
    }

    // 200 KiB interleaved on each stream — far beyond the 64 KiB pipe buffer,
    // so this hangs forever unless both pipes are drained while the child runs.
    @Test func drainsLargeOutputOnBothPipesWithoutDeadlock() throws {
        let line = String(repeating: "x", count: 1023)
        let script = """
        i=0
        while [ $i -lt 200 ]; do
          printf '%s\\n' '\(line)'
          printf '%s\\n' '\(line)' >&2
          i=$((i+1))
        done
        """
        let result = try sh(script)
        #expect(result.status == 0)
        #expect(result.stdout.count == 200 * 1024)
        #expect(result.stderr.count == 200 * 1024)
        #expect(!result.timedOut)
    }

    @Test func killsAndFlagsTimedOutChild() throws {
        let start = Date()
        let result = try sh("sleep 30", timeout: 0.3)
        #expect(result.timedOut)
        // SIGTERM/SIGKILL plus reap must return promptly, not after 30s.
        #expect(Date().timeIntervalSince(start) < 10)
    }

    // A descendant that inherits the pipes and keeps writing after the direct
    // child exits: the run must return at its own deadline (never wait out the
    // descendant's ~6s lifetime), flag the run as timed out because output
    // completeness cannot be proven, and keep what was captured by then.
    @Test func descendantHoldingPipesFlipsTimedOutAndKeepsCapturedOutput() throws {
        let start = Date()
        let script = """
        printf before
        ( i=0; while [ $i -lt 60 ]; do printf x; sleep 0.1; i=$((i+1)); done ) &
        exit 0
        """
        let result = try sh(script, timeout: 1)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(result.timedOut)
        #expect(String(decoding: result.stdout, as: UTF8.self).hasPrefix("before"))
    }

    // The mechanism behind the descendant case: once abandoned, the shared
    // buffer keeps only the snapshot and later appends from the still-running
    // drain threads must not accumulate anywhere.
    @Test func abandonedBufferKeepsSnapshotAndDiscardsLaterChunks() {
        let buffer = ProcessRunner.LockedBuffer()
        buffer.append(Data("kept".utf8))
        let snapshot = buffer.abandon()
        #expect(String(decoding: snapshot, as: UTF8.self) == "kept")
        buffer.append(Data(repeating: 0x78, count: 64 * 1024))
        #expect(buffer.value.isEmpty)
    }
}

struct KittyConfigValidatorProcessTests {
    /// Stages an executable `kitty` stand-in so the validator's real process
    /// path is exercised hermetically (no PATH mutation, no real kitty).
    private func fakeKitty(script: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kittymgr-fake-kitty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("kitty")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func hangingKittyIsAHardFailureNotASkip() throws {
        let fake = try fakeKitty(script: "sleep 30")
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }

        let validator = KittyConfigValidator(timeout: 0.3, kittyPath: fake.path)
        let result = validator.validate(content: "font_size 14\n")

        guard case let .invalid(diagnostics) = result else {
            Issue.record("expected .invalid for a hung kitty, got \(result)")
            return
        }
        #expect(diagnostics.contains("did not finish"))
    }

    @Test func missingKittyStaysSkipped() {
        let validator = KittyConfigValidator(
            timeout: 5,
            kittyPath: "/nonexistent/kitty-\(UUID().uuidString)"
        )
        #expect(validator.validate(content: "font_size 14\n")
            == .skipped(reason: "kitty not found"))
    }

    @Test func quickCleanKittyStillValidates() throws {
        let fake = try fakeKitty(script: "exit 0")
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }

        let validator = KittyConfigValidator(timeout: 5, kittyPath: fake.path)
        #expect(validator.validate(content: "font_size 14\n") == .valid)
    }
}
