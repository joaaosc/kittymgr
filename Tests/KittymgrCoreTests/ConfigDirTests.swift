import Foundation
import Testing
@testable import KittymgrCore

struct ConfigDirTests {
    let home = URL(fileURLWithPath: "/home/tester")

    @Test func honorsKittyConfigDirectory() {
        let dir = ConfigDir.resolve(
            environment: [
                "KITTY_CONFIG_DIRECTORY": "/tmp/k",
                "XDG_CONFIG_HOME": "/should/not/win",
            ],
            home: home
        )
        #expect(dir.url.path == "/tmp/k")
    }

    @Test func expandsTildeInKittyConfigDirectory() {
        let dir = ConfigDir.resolve(
            environment: ["KITTY_CONFIG_DIRECTORY": "~/custom/kitty"],
            home: home
        )
        #expect(dir.url.path == "/home/tester/custom/kitty")
    }

    @Test func fallsBackToXdgConfigHome() {
        let dir = ConfigDir.resolve(
            environment: ["XDG_CONFIG_HOME": "/xdg"],
            home: home
        )
        #expect(dir.url.path == "/xdg/kitty")
    }

    @Test func defaultsToDotConfigKitty() {
        let dir = ConfigDir.resolve(environment: [:], home: home)
        #expect(dir.url.path == "/home/tester/.config/kitty")
    }

    @Test func emptyEnvValuesAreIgnored() {
        let dir = ConfigDir.resolve(
            environment: ["KITTY_CONFIG_DIRECTORY": "", "XDG_CONFIG_HOME": ""],
            home: home
        )
        #expect(dir.url.path == "/home/tester/.config/kitty")
    }

    @Test func derivedPaths() {
        let dir = ConfigDir(url: URL(fileURLWithPath: "/cfg/kitty"))
        #expect(dir.kittyConf.path == "/cfg/kitty/kitty.conf")
        #expect(dir.managedDir.path == "/cfg/kitty/managed")
        #expect(dir.activeConf.path == "/cfg/kitty/managed/active.conf")
    }
}
