import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class BackupCoordinator: ObservableObject {
    @Published private(set) var backups: [TaskBackup] = []
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published var errorMessage: String?

    private unowned let store: TaskStore
    private let onCompletion: () -> Void
    private let maxImportBytes = 32 * 1024 * 1024

    init(store: TaskStore, onCompletion: @escaping () -> Void = {}) {
        self.store = store
        self.onCompletion = onCompletion
    }

    func refresh() {
        backups = store.backups()
    }

    func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "轻待备份-\(Self.fileDateFormatter.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        defer { isBusy = false }
        store.clearError()
        store.exportArchive(to: url)
        if let storeError = store.errorMessage {
            errorMessage = storeError
        } else {
            message = "备份已导出"
            onCompletion()
        }
    }

    func importArchive() {
        importArchive(mode: nil)
    }

    func importArchive(mode: ImportMode) {
        importArchive(mode: Optional(mode))
    }

    private func importArchive(mode: ImportMode?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                errorMessage = "请选择有效的轻待备份文件。"
                return
            }
            if let size = values.fileSize, size > maxImportBytes {
                errorMessage = "备份文件不能超过 32 MB。"
                return
            }
        } catch {
            errorMessage = "无法读取备份文件：\(error.localizedDescription)"
            return
        }

        guard let selectedMode = mode ?? chooseImportMode() else { return }
        if selectedMode == .replace, !confirm(
            title: "替换全部轻待数据？",
            message: "现有记录会先自动备份，然后由所选文件替换。",
            action: "替换"
        ) {
            return
        }
        isBusy = true
        defer { isBusy = false }
        store.clearError()
        store.importArchive(from: url, mode: selectedMode)
        if let storeError = store.errorMessage {
            errorMessage = storeError
        } else {
            message = selectedMode == .merge ? "备份已合并" : "数据已恢复"
            onCompletion()
        }
        refresh()
    }

    func restore(_ backup: TaskBackup) {
        guard confirm(
            title: "恢复这份备份？",
            message: "当前记录会先另存一份备份，再恢复所选内容。",
            action: "恢复"
        ) else { return }
        performRestore(backup)
    }

    private func performRestore(_ backup: TaskBackup) {
        isBusy = true
        defer { isBusy = false }
        store.clearError()
        store.restoreBackup(backup)
        if let storeError = store.errorMessage {
            errorMessage = storeError
        } else {
            message = "备份已恢复"
            onCompletion()
        }
        refresh()
    }

    func showRestoreOptions() {
        refresh()
        guard !backups.isEmpty else {
            message = "还没有可恢复的自动备份。"
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 290, height: 26))
        for backup in backups.prefix(30) {
            let kind = backup.automatic ? "自动备份" : "导入前备份"
            popup.addItem(withTitle: "\(kind) · \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "选择要恢复的备份"
        alert.informativeText = "恢复前会先保留当前数据。"
        alert.accessoryView = popup
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        guard backups.indices.contains(index) else { return }
        performRestore(backups[index])
    }

    func revealDataDirectory() {
        let fileURL = store.directoryURL.appendingPathComponent("tasks.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(store.directoryURL)
        }
    }

    func openBackupFolder() {
        let directory = store.directoryURL.appendingPathComponent("Backups", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.open(directory)
        } else {
            revealDataDirectory()
        }
    }

    func clearError() {
        errorMessage = nil
        message = nil
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func chooseImportMode() -> ImportMode? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "怎样导入这份备份？"
        alert.informativeText = "合并会保留现有事项；替换会先备份当前数据，再恢复所选文件。"
        alert.addButton(withTitle: "合并")
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .merge
        case .alertSecondButtonReturn: return .replace
        default: return nil
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
