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

    @Test func expandsBareTilde() {
        let kitty = ConfigDir.resolve(
            environment: ["KITTY_CONFIG_DIRECTORY": "~"],
            home: home
        )
        #expect(kitty.url.path == "/home/tester")

        let xdg = ConfigDir.resolve(
            environment: ["XDG_CONFIG_HOME": "~"],
            home: home
        )
        #expect(xdg.url.path == "/home/tester/kitty")
    }

    @Test func relativeEnvValuesAreIgnored() {
        // A relative path would silently resolve against the process cwd; it is
        // rejected and resolution falls through to the next candidate.
        let fallsToXdg = ConfigDir.resolve(
            environment: [
                "KITTY_CONFIG_DIRECTORY": "relative/kitty",
                "XDG_CONFIG_HOME": "/xdg",
            ],
            home: home
        )
        #expect(fallsToXdg.url.path == "/xdg/kitty")

        let fallsToDefault = ConfigDir.resolve(
            environment: [
                "KITTY_CONFIG_DIRECTORY": "./kitty",
                "XDG_CONFIG_HOME": "also-relative",
            ],
            home: home
        )
        #expect(fallsToDefault.url.path == "/home/tester/.config/kitty")
    }

    @Test func resolvedPathsAreStandardized() {
        let dotted = ConfigDir.resolve(
            environment: ["KITTY_CONFIG_DIRECTORY": "/tmp/../tmp/k/"],
            home: home
        )
        #expect(dotted.url.path == "/tmp/k")

        let tilde = ConfigDir.resolve(
            environment: ["KITTY_CONFIG_DIRECTORY": "~/a/../custom"],
            home: home
        )
        #expect(tilde.url.path == "/home/tester/custom")
    }

    @Test func managedStateLivesInsideTheConfigDir() {
        // Every managed path hangs off <config dir>/kittymgr; nothing derives
        // from the process cwd.
        let dir = ConfigDir.resolve(
            environment: ["KITTY_CONFIG_DIRECTORY": "/cfg/kitty"],
            home: home
        )
        for managed in [
            dir.managedDir, dir.profilesDir, dir.pluginsDir, dir.kittensDir,
            dir.cacheDir, dir.backupsDir, dir.activeConf, dir.lockFile,
            dir.activePointerFile, dir.metaFile,
        ] {
            #expect(managed.path.hasPrefix("/cfg/kitty/kittymgr"),
                    "\(managed.path) escaped the managed root")
        }
        #expect(dir.kittyConf.path == "/cfg/kitty/kitty.conf")
        #expect(dir.manifestFile.path == "/cfg/kitty/kittymgr.toml")
    }

    @Test func derivedPaths() {
        let dir = ConfigDir(url: URL(fileURLWithPath: "/cfg/kitty"))
        #expect(dir.kittyConf.path == "/cfg/kitty/kitty.conf")
        #expect(dir.managedDir.path == "/cfg/kitty/kittymgr")
        #expect(dir.activeConf.path == "/cfg/kitty/kittymgr/active.conf")
        #expect(dir.lockFile.path == "/cfg/kitty/kittymgr/kittymgr.lock")
    }
}
