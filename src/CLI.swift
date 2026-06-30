import Foundation

/// Minimal command dispatcher for the `kittymgr` executable.
public enum KittymgrCLI {
    /// Runs the CLI with arguments that exclude the executable path.
    /// Returns a process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            printUsage()
            return 2
        }
        let options = Array(arguments.dropFirst())

        do {
            switch command {
            case "init":
                _ = try InitCommand(configDir: ConfigDir.resolve()).run()
                return 0
            case "uninstall":
                let removeManaged = options.contains("--purge") || options.contains("--remove-managed")
                _ = try UninstallCommand(configDir: ConfigDir.resolve(), removeManaged: removeManaged).run()
                return 0
            case "help", "-h", "--help":
                printUsage()
                return 0
            default:
                printError("unknown command: \(command)")
                printUsage()
                return 2
            }
        } catch {
            printError("\(error)")
            return 1
        }
    }

    private static func printUsage() {
        print("""
        kittymgr — non-invasive kitty configuration manager

        Usage:
          kittymgr init                 Create the managed layer and inject the guarded include block.
          kittymgr uninstall [--purge]  Remove the guarded block; --purge also deletes the managed directory.
          kittymgr help                 Show this message.

        The kitty config directory is resolved from KITTY_CONFIG_DIRECTORY,
        then $XDG_CONFIG_HOME/kitty, then ~/.config/kitty.
        """)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
