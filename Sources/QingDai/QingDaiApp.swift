import AppKit
import Combine
import SwiftUI

@main
enum QingDaiApp {
    @MainActor
    static func main() {
        let application = QingDaiApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        // NSApplication's delegate is weak; retain it for the entire event loop.
        withExtendedLifetime(delegate) { application.run() }
    }
}

@objc(QingDaiApplication)
final class QingDaiApplication: NSApplication {
    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                state: NSCoder,
                                completionHandler: @escaping (NSWindow?, Error?) -> Void) -> Bool {
        // Older builds registered an empty Settings scene. This app has no standalone windows to restore.
        completionHandler(nil, nil)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var store: TaskStore!
    private let presentation = PanelPresentation()
    private let preferences = SystemPreferences()
    private var reminders: ReminderManager!
    private var backups: BackupCoordinator!
    private var observations = Set<AnyCancellable>()
    private var workspaceObservation: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private let modeKey = "menuBarDisplayMode"

    private enum DisplayMode: String, CaseIterable {
        case count, nextTask, icon

        var title: String {
            switch self {
            case .count: return "图标＋未完成数量"
            case .nextTask: return "图标＋下一条待办"
            case .icon: return "只显示图标"
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        store = TaskStore()
        reminders = ReminderManager()
        backups = BackupCoordinator(store: store)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "轻待")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.delegate = self
        installPopoverDismissMonitors()
        let controller = NSHostingController(rootView:
            PanelView(store: store,
                      presentation: presentation,
                      preferences: preferences,
                      reminders: reminders,
                      backups: backups,
                      onHeightChange: { [weak self] in self?.resizePopover(to: $0) },
                      onClose: { [weak self] in self?.popover.performClose(nil) },
                      onQuit: { NSApp.terminate(nil) })
        )
        // A single height source avoids competing SwiftUI and AppKit size constraints.
        controller.sizingOptions = []
        popover.contentViewController = controller
        popover.contentSize = PanelView.panelSize
        store.$items.combineLatest(store.$now)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &observations)
        workspaceObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.refreshTime() }
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.preferences.refreshLoginStatus() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.closePopoverAfterOutsideInteraction() }
            .store(in: &observations)
        preferences.start { [weak self] in self?.showPopover(focusComposer: true) }
        reminders.start(store: store) { [weak self] itemID in
            guard let self else { return }
            self.showPopover(focusComposer: false)
            self.presentation.requestItem(itemID)
        }
        updateStatusItem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "轻待")
        let open = NSMenuItem(title: "打开待办面板", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        appMenu.addItem(open)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出轻待", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Keep standard text editing shortcuts after removing the SwiftUI App scene.
        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        reminders.stop()
        preferences.stop()
        removePopoverDismissMonitors()
        if let workspaceObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObservation)
        }
    }

    @objc private func statusItemPressed(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover(focusComposer: Bool = false) {
        guard let button = statusItem?.button else { return }
        store.refreshTime()
        preferences.refreshLoginStatus()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.activate(ignoringOtherApps: true)
        presentation.isPresented = true
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
        if focusComposer {
            // Focus once the transient popover has joined its key window.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.presentation.requestComposerFocus()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        presentation.isPresented = false
    }

    private func installPopoverDismissMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                // The status button's mouse-up action owns toggle behavior. Closing on its
                // mouse-down would make that action immediately reopen the popover.
                guard !self.statusItemContains(screenPoint: NSEvent.mouseLocation) else { return }
                self.closePopoverAfterOutsideInteraction()
            }
        }
    }

    private func removePopoverDismissMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func statusItemContains(screenPoint: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonRectInWindow).insetBy(dx: -2, dy: -2).contains(screenPoint)
    }

    private func closePopoverAfterOutsideInteraction() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func resizePopover(to height: CGFloat) {
        guard height.isFinite else { return }
        let size = NSSize(width: PanelView.panelSize.width, height: min(460, max(250, ceil(height))))
        guard abs(popover.contentSize.height - size.height) > 0.5 else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = size
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let mode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .count
        switch mode {
        case .count:
            button.title = " \(store.remainingCount)"
        case .nextTask:
            let title = store.activeItems.first?.title ?? (store.remainingCount > 0 ? "待办已安排稍后" : "都完成了")
            button.title = " " + String(title.prefix(12)) + (title.count > 12 ? "…" : "")
        case .icon:
            button.title = ""
        }
        button.toolTip = "轻待 · \(store.remainingCount) 件未完成，\(store.deferredItems.count) 件稍后\n更新台账 · \(store.outstandingRegionCount) 个地区，\(store.outstandingUpdateCount) 项待同步\n点击查看，右键更多选项"
        button.setAccessibilityLabel("轻待，\(store.remainingCount) 件待办未完成，\(store.outstandingUpdateCount) 项地区更新待同步。点击打开面板")
    }

    private func showContextMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开轻待", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let shortcutLabel = preferences.shortcut != .disabled && preferences.shortcutError == nil
            ? "  \(preferences.shortcut.displayLabel)" : ""
        let quickEntry = NSMenuItem(title: "快速添加\(shortcutLabel)", action: #selector(quickEntryFromMenu), keyEquivalent: "")
        quickEntry.target = self
        menu.addItem(quickEntry)
        let mode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .count
        let displayMenu = NSMenu()
        for option in DisplayMode.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(changeDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == mode ? .on : .off
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        let data = NSMenuItem(title: "打开数据文件夹", action: #selector(openDataFolder), keyEquivalent: "")
        data.target = self
        menu.addItem(data)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出轻待", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { showPopover() }

    @objc private func quickEntryFromMenu() { showPopover(focusComposer: true) }

    @objc private func changeDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: modeKey)
        updateStatusItem()
    }

    @objc private func openDataFolder() {
        if FileManager.default.fileExists(atPath: store.directoryURL.path) {
            NSWorkspace.shared.open(store.directoryURL)
        } else {
            NSWorkspace.shared.open(store.directoryURL.deletingLastPathComponent())
        }
    }
}
