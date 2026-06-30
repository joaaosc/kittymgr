import Foundation
import Testing
@testable import KittymgrCore

struct ProfileNameTests {
    @Test func acceptsSafeNames() throws {
        for raw in ["work", "Work", "dev-2", "my.profile", "a_b", "v1.2_3-x"] {
            #expect(try ProfileName(validating: raw).value == raw)
        }
    }

    @Test func rejectsEmpty() {
        #expect(throws: ProfileError.self) { try ProfileName(validating: "") }
    }

    @Test func rejectsPathSeparators() {
        #expect(throws: ProfileError.self) { try ProfileName(validating: "a/b") }
        #expect(throws: ProfileError.self) { try ProfileName(validating: "../escape") }
    }

    @Test func rejectsTraversalAndHidden() {
        #expect(throws: ProfileError.self) { try ProfileName(validating: ".") }
        #expect(throws: ProfileError.self) { try ProfileName(validating: "..") }
        #expect(throws: ProfileError.self) { try ProfileName(validating: ".hidden") }
    }

    @Test func rejectsWhitespaceAndDisallowedCharacters() {
        #expect(throws: ProfileError.self) { try ProfileName(validating: "has space") }
        #expect(throws: ProfileError.self) { try ProfileName(validating: "  ") }
        #expect(throws: ProfileError.self) { try ProfileName(validating: "name!") }
    }
}

struct ProfileStoreTests {
    private let fileManager = FileManager.default

    private func makeStore() throws -> ProfileStore {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-profiles-\(UUID().uuidString)")
            .appendingPathComponent("managed/profiles")
        return ProfileStore(root: root)
    }

    @Test func listIsEmptyWhenRootMissing() throws {
        let store = try makeStore()
        #expect(try store.list().isEmpty)
    }

    @Test func createReflectsOnDiskAndInList() throws {
        let store = try makeStore()
        let dir = try store.create(try ProfileName(validating: "work"))
        #expect(fileManager.fileExists(atPath: dir.path))
        #expect(try store.list() == ["work"])
    }

    @Test func deleteRemovesFromDiskAndList() throws {
        let store = try makeStore()
        let name = try ProfileName(validating: "work")
        try store.create(name)
        try store.delete(name)
        #expect(try store.list().isEmpty)
        #expect(store.exists(name) == false)
    }

    @Test func duplicateCreateFailsAndKeepsFirst() throws {
        let store = try makeStore()
        let name = try ProfileName(validating: "work")
        try store.create(name)
        #expect(throws: ProfileError.alreadyExists("work")) {
            try store.create(name)
        }
        #expect(try store.list() == ["work"])
    }

    @Test func caseInsensitiveCollisionRejected() throws {
        let store = try makeStore()
        try store.create(try ProfileName(validating: "Work"))
        #expect(throws: ProfileError.self) {
            try store.create(try ProfileName(validating: "work"))
        }
    }

    @Test func deleteMissingProfileFails() throws {
        let store = try makeStore()
        #expect(throws: ProfileError.notFound("ghost")) {
            try store.delete(try ProfileName(validating: "ghost"))
        }
    }

    @Test func listIgnoresFilesAndHiddenEntries() throws {
        let store = try makeStore()
        try fileManager.createDirectory(at: store.root, withIntermediateDirectories: true)
        try store.create(try ProfileName(validating: "work"))
        try Data().write(to: store.root.appendingPathComponent("loose.conf"))
        try fileManager.createDirectory(
            at: store.root.appendingPathComponent(".hidden"),
            withIntermediateDirectories: false
        )
        #expect(try store.list() == ["work"])
    }
}

struct ProfileCommandTests {
    private let fileManager = FileManager.default
    private func silent(_ message: String) {}

    private func makeStore() throws -> ProfileStore {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-cmd-\(UUID().uuidString)")
            .appendingPathComponent("managed/profiles")
        return ProfileStore(root: root)
    }

    @Test func createThenListThenDelete() throws {
        let store = try makeStore()
        try CreateCommand(store: store, rawName: "work").run(log: silent)
        #expect(try store.list() == ["work"])

        try DeleteCommand(store: store, rawName: "work", force: true).run(log: silent)
        #expect(try store.list().isEmpty)
    }

    @Test func createRejectsInvalidNameWithoutTouchingDisk() throws {
        let store = try makeStore()
        #expect(throws: ProfileError.self) {
            try CreateCommand(store: store, rawName: "../escape").run(log: silent)
        }
        #expect(try store.list().isEmpty)
    }

    @Test func deleteAbortsWhenNotConfirmed() throws {
        let store = try makeStore()
        try store.create(try ProfileName(validating: "work"))
        try DeleteCommand(store: store, rawName: "work", force: false, confirm: { _ in false })
            .run(log: silent)
        #expect(try store.list() == ["work"])
    }

    @Test func deleteProceedsWhenConfirmed() throws {
        let store = try makeStore()
        try store.create(try ProfileName(validating: "work"))
        try DeleteCommand(store: store, rawName: "work", force: false, confirm: { _ in true })
            .run(log: silent)
        #expect(try store.list().isEmpty)
    }
}
