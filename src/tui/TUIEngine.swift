#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

import Foundation

public final class TUIEngine {
    private let profileStore: ProfileStore
    private let pluginStore: PluginStore
    private let activePointer: ActivePointer
    private let activeConf: URL
    private let validator: any ConfigValidating
    private let reloader: any Reloading
    private let sourceFetcher: (any SourceFetching)?
    private let terminal: any TerminalControlling
    private let readKey: () throws -> TUIKey
    private let writeOutput: (String) -> Void
    
    private var selectedPanel = 0 // 0: Profiles, 1: Plugins, 2: Themes, 3: Backups
    
    // Lists and selections
    private var profiles: [String] = []
    private var plugins: [Plugin] = []
    private var themes: [String] = []
    private var backups: [SnapshotManifest] = []
    
    private var selectedProfileIndex = 0
    private var selectedPluginIndex = 0
    private var selectedThemeIndex = 0
    private var selectedBackupIndex = 0
    
    private var statusMessage = "Pressione [Tab] para navegar entre painéis."
    private var statusIsError = false
    
    private var configDir: ConfigDir {
        ConfigDir(url: activeConf.deletingLastPathComponent().deletingLastPathComponent())
    }
    
    public init(
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        activePointer: ActivePointer,
        activeConf: URL,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader(),
        sourceFetcher: (any SourceFetching)? = nil,
        terminal: any TerminalControlling = Terminal(),
        readKey: @escaping () throws -> TUIKey = { KeyReader.readKey() },
        write: @escaping (String) -> Void = {
            print($0, terminator: "")
            fflush(stdout)
        }
    ) {
        self.profileStore = profileStore
        self.pluginStore = pluginStore
        self.activePointer = activePointer
        self.activeConf = activeConf
        self.validator = validator
        self.reloader = reloader
        self.sourceFetcher = sourceFetcher
        self.terminal = terminal
        self.readKey = readKey
        self.writeOutput = write
    }
    
    public func start() throws {
        guard terminal.isInteractive else {
            throw TerminalError.nonInteractive
        }
        try terminal.enableRawMode()
        defer {
            terminal.disableRawMode()
        }
        
        try loadData()
        
        while true {
            render()
            
            let key = try readKey()
            switch key {
            case .escape, .ctrlC:
                return
            case .char("q"), .char("Q"):
                return
            case .tab:
                selectedPanel = (selectedPanel + 1) % 4
                clearStatus()
            case .left:
                // Shift focus to the left column
                if selectedPanel == 1 { selectedPanel = 0 }
                else if selectedPanel == 3 { selectedPanel = 2 }
                clearStatus()
            case .right:
                // Shift focus to the right column
                if selectedPanel == 0 { selectedPanel = 1 }
                else if selectedPanel == 2 { selectedPanel = 3 }
                clearStatus()
            case .up:
                moveSelection(up: true)
            case .down:
                moveSelection(up: false)
            case .enter:
                try handleEnter()
            case .char("s"), .char("S"):
                try handleSync()
            case .char("u"), .char("U"):
                try handleUpdate()
            case .char("l"), .char("L"):
                try handleClean()
            case .char("r"), .char("R"):
                try loadData()
                showSuccess("Dados recarregados com sucesso.")
            default:
                break
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadData() throws {
        profiles = (try? profileStore.list()) ?? []
        plugins = (try? pluginStore.list()) ?? []
        
        let store = BlockStore(managedDir: configDir.managedDir)
        themes = store.availableThemes()
        
        backups = SnapshotStore(configDir: configDir).list()
        
        // Clamp indices
        selectedProfileIndex = clamp(selectedProfileIndex, max: profiles.count - 1)
        selectedPluginIndex = clamp(selectedPluginIndex, max: plugins.count - 1)
        selectedThemeIndex = clamp(selectedThemeIndex, max: themes.count - 1)
        selectedBackupIndex = clamp(selectedBackupIndex, max: backups.count - 1)
    }
    
    private func clamp(_ val: Int, max m: Int) -> Int {
        if m < 0 { return 0 }
        if val < 0 { return 0 }
        if val > m { return m }
        return val
    }
    
    private func moveSelection(up: Bool) {
        switch selectedPanel {
        case 0:
            selectedProfileIndex = navigate(selectedProfileIndex, up: up, max: profiles.count - 1)
        case 1:
            selectedPluginIndex = navigate(selectedPluginIndex, up: up, max: plugins.count - 1)
        case 2:
            selectedThemeIndex = navigate(selectedThemeIndex, up: up, max: themes.count - 1)
        case 3:
            selectedBackupIndex = navigate(selectedBackupIndex, up: up, max: backups.count - 1)
        default:
            break
        }
    }
    
    private func navigate(_ index: Int, up: Bool, max m: Int) -> Int {
        if m <= 0 { return 0 }
        if up {
            return index > 0 ? index - 1 : 0
        } else {
            return index < m ? index + 1 : m
        }
    }
    
    private func clearStatus() {
        statusMessage = "Pressione [Tab] para navegar entre painéis."
        statusIsError = false
    }
    
    private func showSuccess(_ msg: String) {
        statusMessage = msg
        statusIsError = false
    }
    
    private func showError(_ msg: String) {
        statusMessage = msg
        statusIsError = true
    }
    
    // MARK: - Actions
    
    private func handleEnter() throws {
        switch selectedPanel {
        case 0:
            try handleSwitchProfile()
        case 1:
            try handleTogglePlugin()
        case 2:
            try handleSwitchTheme()
        case 3:
            try handleRestoreBackup()
        default:
            break
        }
    }
    
    private func previewAndConfirm(
        title: String,
        preview: ((String) -> Void) throws -> Void,
        apply: ((String) -> Void) throws -> Void
    ) throws {
        let previewResult = captureOutput(preview)
        if let error = previewResult.error {
            renderActionScreen(
                title: title,
                subtitle: "Preview falhou.",
                body: previewResult.output + "\nErro: \(error)",
                footer: "[Enter/Esc] voltar"
            )
            showError("Preview falhou: \(error)")
            try waitForDismiss()
            return
        }

        while true {
            renderActionScreen(
                title: title,
                subtitle: "O que vai mudar:",
                body: previewResult.output,
                footer: "[Enter] aplicar   [Esc] cancelar"
            )

            switch try readKey() {
            case .enter:
                let applyResult = captureOutput(apply)
                try loadData()
                if let error = applyResult.error {
                    renderActionScreen(
                        title: title,
                        subtitle: "Apply falhou.",
                        body: applyResult.output + "\nErro: \(error)",
                        footer: "[Enter/Esc] voltar"
                    )
                    showError("Erro: \(error)")
                } else {
                    renderActionScreen(
                        title: title,
                        subtitle: "Resultado:",
                        body: applyResult.output,
                        footer: "[Enter/Esc] voltar"
                    )
                    showSuccess("Aplicado. Veja o resultado da acao.")
                }
                try waitForDismiss()
                return
            case .escape, .ctrlC:
                showSuccess("Cancelado; nada escrito.")
                return
            default:
                break
            }
        }
    }

    private func captureOutput(_ action: (((String) -> Void) throws -> Void)) -> (output: String, error: Error?) {
        var lines: [String] = []
        do {
            try action { lines.append($0) }
            return (lines.joined(separator: "\n"), nil)
        } catch {
            return (lines.joined(separator: "\n"), error)
        }
    }

    private func renderActionScreen(title: String, subtitle: String, body: String, footer: String) {
        let visibleBody = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(sem mudancas)" : body
        emit(
            ANSI.clear + ANSI.home
            + "\(ANSI.bold)\(title)\(ANSI.reset)\n\n"
            + "\(subtitle)\n\n"
            + "\(visibleBody)\n\n"
            + "\(ANSI.dim)\(footer)\(ANSI.reset)"
        )
    }

    private func waitForDismiss() throws {
        while true {
            switch try readKey() {
            case .enter, .escape, .ctrlC, .char("q"), .char("Q"):
                return
            default:
                break
            }
        }
    }
    
    private func handleSwitchProfile() throws {
        guard profiles.indices.contains(selectedProfileIndex) else { return }
        let target = profiles[selectedProfileIndex]

        try previewAndConfirm(
            title: "Ativar perfil '\(target)'",
            preview: { log in
                try SwitchCommand(
                    profileStore: self.profileStore,
                    pluginStore: self.pluginStore,
                    activePointer: self.activePointer,
                    activeConf: self.activeConf,
                    rawName: target,
                    force: false,
                    dryRun: true,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            },
            apply: { log in
                try SwitchCommand(
                    profileStore: self.profileStore,
                    pluginStore: self.pluginStore,
                    activePointer: self.activePointer,
                    activeConf: self.activeConf,
                    rawName: target,
                    force: false,
                    dryRun: false,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            }
        )
    }
    
    private func handleTogglePlugin() throws {
        guard plugins.indices.contains(selectedPluginIndex) else { return }
        let plugin = plugins[selectedPluginIndex]
        let active = activePointer.get()
        guard let activeProfile = active else {
            showError("Nenhum perfil ativo. Ative um perfil primeiro.")
            return
        }
        
        let profileName = try ProfileName(validating: activeProfile)
        let enabled = Set(profileStore.metadata(for: profileName).enabledPlugins)
        let isEnabled = enabled.contains(plugin.name)
        let action: PluginCommand.Action = isEnabled ? .disable(plugin.name) : .enable(plugin.name)
        let label = isEnabled ? "Desabilitar plugin '\(plugin.name)'" : "Habilitar plugin '\(plugin.name)'"

        try previewAndConfirm(
            title: label,
            preview: { log in
                try PluginCommand(
                    action: action,
                    profileStore: self.profileStore,
                    pluginStore: self.pluginStore,
                    activePointer: self.activePointer,
                    activeConf: self.activeConf,
                    dryRun: true,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            },
            apply: { log in
                try PluginCommand(
                    action: action,
                    profileStore: self.profileStore,
                    pluginStore: self.pluginStore,
                    activePointer: self.activePointer,
                    activeConf: self.activeConf,
                    dryRun: false,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            }
        )
    }
    
    private func handleSwitchTheme() throws {
        guard themes.indices.contains(selectedThemeIndex) else { return }
        let theme = themes[selectedThemeIndex]

        try previewAndConfirm(
            title: "Ativar tema '\(theme)'",
            preview: { log in
                try BlockCommand(
                    action: .themeSwitch(name: theme),
                    configDir: self.configDir,
                    dryRun: true,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            },
            apply: { log in
                try BlockCommand(
                    action: .themeSwitch(name: theme),
                    configDir: self.configDir,
                    dryRun: false,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            }
        )
    }
    
    private func handleRestoreBackup() throws {
        guard backups.indices.contains(selectedBackupIndex) else { return }
        let manifest = backups[selectedBackupIndex]

        try previewAndConfirm(
            title: "Restaurar backup '\(manifest.id)'",
            preview: { log in
                try BackupCommand(action: .restore(id: manifest.id), configDir: self.configDir, dryRun: true).run(log: log)
            },
            apply: { log in
                try BackupCommand(action: .restore(id: manifest.id), configDir: self.configDir, dryRun: false).run(log: log)
            }
        )
    }

    private func handleSync() throws {
        try previewAndConfirm(
            title: "Sincronizar manifest",
            preview: { log in
                try Synchronizer(
                    configDir: self.configDir,
                    dryRun: true,
                    fetcher: self.sourceFetcher,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            },
            apply: { log in
                try Synchronizer(
                    configDir: self.configDir,
                    dryRun: false,
                    fetcher: self.sourceFetcher,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            }
        )
    }

    private func handleUpdate() throws {
        try previewAndConfirm(
            title: "Atualizar fontes",
            preview: { log in
                try UpdateCommand(
                    configDir: self.configDir,
                    dryRun: true,
                    fetcher: self.sourceFetcher,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            },
            apply: { log in
                try UpdateCommand(
                    configDir: self.configDir,
                    dryRun: false,
                    fetcher: self.sourceFetcher,
                    validator: self.validator,
                    reloader: self.reloader
                ).run(log: log)
            }
        )
    }

    private func handleClean() throws {
        try previewAndConfirm(
            title: "Limpeza conservadora",
            preview: { log in
                try CleanCommand(configDir: self.configDir, artifacts: false, force: false, dryRun: true).run(log: log)
            },
            apply: { log in
                try CleanCommand(configDir: self.configDir, artifacts: false, force: false, dryRun: false).run(log: log)
            }
        )
    }
    
    // MARK: - Rendering
    
    private func render() {
        let size = terminal.getSize()
        let cols = max(80, size.cols)
        let rows = max(24, size.rows)
        
        var frame: [String] = []
        
        // 1. Header Title Bar
        let activeProfile = activePointer.get() ?? "(nenhum)"
        let blockStore = BlockStore(managedDir: configDir.managedDir)
        let activeTheme = blockStore.state().activeTheme ?? "(nenhum)"
        
        let titleText = " kittymgr TUI "
        let detailsText = " Perfil: \(activeProfile) | Tema: \(activeTheme) "
        let titlePadding = max(0, cols - titleText.count - detailsText.count - 4)
        
        let headerLine = ANSI.bgBlue + ANSI.white + ANSI.bold
            + " 🐱" + titleText
            + String(repeating: " ", count: titlePadding)
            + detailsText + " "
            + ANSI.reset
        frame.append(headerLine)
        frame.append("") // spacer
        
        // 2. Compute Quadrants dimensions
        let quadHeight = (rows - 6) / 2
        let leftWidth = cols / 2 - 1
        let rightWidth = cols - leftWidth - 2
        
        // Quadrant 0: Profiles (Top-Left)
        var profileLines: [String] = []
        for (i, p) in profiles.enumerated() {
            let isActive = p == activeProfile
            let activeIndicator = isActive ? ANSI.green + "●" + ANSI.reset : " "
            let isSelected = i == selectedProfileIndex && selectedPanel == 0
            
            if isSelected {
                profileLines.append("\(ANSI.cyan)▶\(ANSI.reset) \(activeIndicator) \(ANSI.cyan)\(ANSI.bold)\(p)\(ANSI.reset)")
            } else {
                profileLines.append("  \(activeIndicator) \(p)")
            }
        }
        let profilesBox = drawBox(title: "Perfis", lines: profileLines, width: leftWidth, height: quadHeight, isFocused: selectedPanel == 0)
        
        // Quadrant 1: Plugins (Top-Right)
        var pluginLines: [String] = []
        let selectedProfileName = profiles.indices.contains(selectedProfileIndex) ? profiles[selectedProfileIndex] : activeProfile
        let enabledPlugins: Set<String>
        if let selName = try? ProfileName(validating: selectedProfileName) {
            enabledPlugins = Set(profileStore.metadata(for: selName).enabledPlugins)
        } else {
            enabledPlugins = []
        }
        
        for (i, p) in plugins.enumerated() {
            let isEnabled = enabledPlugins.contains(p.name)
            let check = isEnabled ? ANSI.green + "[x]" + ANSI.reset : "[ ]"
            let isSelected = i == selectedPluginIndex && selectedPanel == 1
            
            if isSelected {
                pluginLines.append("\(ANSI.cyan)▶\(ANSI.reset) \(check) \(ANSI.cyan)\(ANSI.bold)\(p.name)\(ANSI.reset)")
            } else {
                pluginLines.append("  \(check) \(p.name)")
            }
        }
        if plugins.isEmpty {
            pluginLines.append("  (nenhum plugin encontrado)")
        }
        let pluginsBox = drawBox(title: "Plugins para '\(selectedProfileName)'", lines: pluginLines, width: rightWidth, height: quadHeight, isFocused: selectedPanel == 1)
        
        // Quadrant 2: Themes (Bottom-Left)
        var themeLines: [String] = []
        for (i, t) in themes.enumerated() {
            let isActive = t == activeTheme
            let activeIndicator = isActive ? ANSI.green + "●" + ANSI.reset : " "
            let isSelected = i == selectedThemeIndex && selectedPanel == 2
            
            if isSelected {
                themeLines.append("\(ANSI.cyan)▶\(ANSI.reset) \(activeIndicator) \(ANSI.cyan)\(ANSI.bold)\(t)\(ANSI.reset)")
            } else {
                themeLines.append("  \(activeIndicator) \(t)")
            }
        }
        if themes.isEmpty {
            themeLines.append("  (nenhum tema instalado)")
        }
        let themesBox = drawBox(title: "Temas de Blocos", lines: themeLines, width: leftWidth, height: quadHeight, isFocused: selectedPanel == 2)
        
        // Quadrant 3: Backups (Bottom-Right)
        var backupLines: [String] = []
        for (i, b) in backups.enumerated() {
            let isSelected = i == selectedBackupIndex && selectedPanel == 3
            let lbl = b.label.map { " (\($0))" } ?? ""
            let text = "\(b.id)\(lbl)"
            
            if isSelected {
                backupLines.append("\(ANSI.cyan)▶\(ANSI.reset) \(ANSI.cyan)\(ANSI.bold)\(text)\(ANSI.reset)")
            } else {
                backupLines.append("  \(text)")
            }
        }
        if backups.isEmpty {
            backupLines.append("  (nenhum backup encontrado)")
        }
        let backupsBox = drawBox(title: "Backups", lines: backupLines, width: rightWidth, height: quadHeight, isFocused: selectedPanel == 3)
        
        // Merge top quadrants
        let topSection = mergeColumns(left: profilesBox, right: pluginsBox)
        frame.append(contentsOf: topSection)
        
        frame.append("") // spacer
        
        // Merge bottom quadrants
        let bottomSection = mergeColumns(left: themesBox, right: backupsBox)
        frame.append(contentsOf: bottomSection)
        
        frame.append("") // spacer
        
        // 3. Status Bar
        let statusColor = statusIsError ? ANSI.red + ANSI.bold : ANSI.cyan
        let statusStr = "Status: " + statusColor + statusMessage + ANSI.reset
        frame.append(statusStr)
        
        // 4. Instructions / Legend Footer
        let instructions: String
        switch selectedPanel {
        case 0:
            instructions = "[Setas/Tab] Navegar | [Enter] Ativar Perfil | [S] Sync | [U] Update | [L] Clean | [Q] Sair"
        case 1:
            instructions = "[Setas/Tab] Navegar | [Enter] Alternar Plugin | [S] Sync | [U] Update | [L] Clean | [Q] Sair"
        case 2:
            instructions = "[Setas/Tab] Navegar | [Enter] Ativar Tema | [S] Sync | [U] Update | [L] Clean | [Q] Sair"
        case 3:
            instructions = "[Setas/Tab] Navegar | [Enter] Restaurar Backup | [S] Sync | [U] Update | [L] Clean | [Q] Sair"
        default:
            instructions = "[Setas/Tab] Navegar | [Enter] Confirmar | [Q] Sair"
        }
        
        let footerLine = ANSI.dim + "Atalhos: " + ANSI.reset + ANSI.bold + instructions + ANSI.reset
        frame.append(footerLine)
        
        // Clear screen and draw frame
        let fullOutput = ANSI.clear + ANSI.home + frame.joined(separator: "\n")
        emit(fullOutput)
    }

    private func emit(_ text: String) {
        writeOutput(text)
    }
    
    private func drawBox(title: String, lines: [String], width: Int, height: Int, isFocused: Bool) -> [String] {
        var result: [String] = []
        let borderStyle = isFocused ? ANSI.cyan + ANSI.bold : ANSI.dim
        let titleStr = " \(title) "
        
        // Top border
        let titleLength = titleStr.count
        let remaining = width - 2 - titleLength
        let leftLine = max(0, remaining / 2)
        let rightLine = max(0, remaining - leftLine)
        let top = "┌" + String(repeating: "─", count: leftLine) + titleStr + String(repeating: "─", count: rightLine) + "┐"
        result.append(borderStyle + top + ANSI.reset)
        
        // Content lines
        for i in 0..<(height - 2) {
            let content: String
            if i < lines.count {
                content = lines[i]
            } else {
                content = ""
            }
            
            let visibleLen = stripANSI(content).count
            let paddingLen = max(0, width - 2 - visibleLen)
            let padded = content + String(repeating: " ", count: paddingLen)
            
            result.append(borderStyle + "│" + ANSI.reset + padded + borderStyle + "│" + ANSI.reset)
        }
        
        // Bottom border
        let bottom = "└" + String(repeating: "─", count: max(0, width - 2)) + "┘"
        result.append(borderStyle + bottom + ANSI.reset)
        
        return result
    }
    
    private func mergeColumns(left: [String], right: [String]) -> [String] {
        var result: [String] = []
        let maxRows = max(left.count, right.count)
        for i in 0..<maxRows {
            let l = i < left.count ? left[i] : ""
            let r = i < right.count ? right[i] : ""
            result.append(l + "  " + r)
        }
        return result
    }
    
    private func stripANSI(_ str: String) -> String {
        var result = ""
        var inEscape = false
        let chars = Array(str)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{001B}" {
                inEscape = true
                i += 1
                continue
            }
            if inEscape {
                if chars[i].isLetter || chars[i] == "?" {
                    if chars[i] != "?" {
                        inEscape = false
                    }
                }
                i += 1
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }
}

// MARK: - ANSI Helpers

enum ANSI {
    static let clear = "\u{001B}[2J"
    static let home = "\u{001B}[H"
    
    static let hideCursor = "\u{001B}[?25l"
    static let showCursor = "\u{001B}[?25h"
    
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let cyan = "\u{001B}[36m"
    static let white = "\u{001B}[37m"
    
    static let bgBlue = "\u{001B}[44m"
}
