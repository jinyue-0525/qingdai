import AppKit
import Carbon
import Combine
import ServiceManagement

enum QuickEntryShortcut: String, CaseIterable, Identifiable {
    case commandShiftSpace
    case controlOptionN
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandShiftSpace: return "⌘⇧Space（默认）"
        case .controlOptionN: return "⌃⌥N"
        case .disabled: return "关闭快捷键"
        }
    }

    var displayLabel: String {
        switch self {
        case .commandShiftSpace: return "⌘⇧Space"
        case .controlOptionN: return "⌃⌥N"
        case .disabled: return "已关闭"
        }
    }

    fileprivate var key: (code: UInt32, modifiers: UInt32)? {
        switch self {
        case .commandShiftSpace: return (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .controlOptionN: return (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey))
        case .disabled: return nil
        }
    }
}

@MainActor
final class SystemPreferences: ObservableObject {
    @Published private(set) var shortcut: QuickEntryShortcut
    @Published private(set) var shortcutError: String?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var loginError: String?
    @Published private(set) var isUpdatingLoginItem = false

    private let shortcutKey = "quickEntryShortcut"
    private let loginService = SMAppService.mainApp
    private var hotKey: QuickEntryHotKey?
    private var onQuickEntry: (() -> Void)?
    private var isStarted = false
    private var loginUpdate: Task<Void, Never>?
    private var lastLoginOperationError: String?

    init() {
        shortcut = QuickEntryShortcut(rawValue: UserDefaults.standard.string(forKey: shortcutKey) ?? "")
            ?? .commandShiftSpace
        refreshLoginStatus()
    }

    func start(onQuickEntry: @escaping () -> Void) {
        self.onQuickEntry = onQuickEntry
        guard !isStarted else { return }
        isStarted = true
        registerShortcut()
    }

    func stop() {
        isStarted = false
        onQuickEntry = nil
        releaseHotKey()
    }

    func setShortcut(_ shortcut: QuickEntryShortcut) {
        guard self.shortcut != shortcut || shortcutError != nil else { return }
        self.shortcut = shortcut
        UserDefaults.standard.set(shortcut.rawValue, forKey: shortcutKey)
        if isStarted {
            registerShortcut()
        } else {
            shortcutError = nil
        }
    }

    func refreshLoginStatus() {
        let status = loginService.status
        launchAtLoginEnabled = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        switch status {
        case .enabled, .requiresApproval, .notRegistered:
            loginError = lastLoginOperationError
        case .notFound:
            loginError = lastLoginOperationError ?? "系统未找到轻待的登录项，请在系统设置中确认应用状态。"
        @unknown default:
            loginError = lastLoginOperationError ?? "无法识别当前登录项状态，请在系统设置中确认。"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isUpdatingLoginItem else { return }
        lastLoginOperationError = nil
        refreshLoginStatus()
        let status = loginService.status
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .notRegistered { return }

        isUpdatingLoginItem = true
        loginUpdate = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if enabled {
                    try self.loginService.register()
                } else {
                    try await self.loginService.unregister()
                }
            } catch {
                let error = error as NSError
                let action = enabled ? "开启" : "关闭"
                self.lastLoginOperationError = "\(action)开机启动失败：\(error.localizedDescription)（\(error.domain) \(error.code)）"
            }
            self.refreshLoginStatus()
            self.isUpdatingLoginItem = false
            self.loginUpdate = nil
        }
    }

    func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registerShortcut() {
        guard releaseHotKey() else { return }
        shortcutError = nil
        guard shortcut != .disabled else { return }
        do {
            hotKey = try QuickEntryHotKey(shortcut: shortcut) { [weak self] in
                guard let self, self.isStarted else { return }
                self.onQuickEntry?()
            }
        } catch {
            shortcutError = error.localizedDescription + "当前全局快捷添加已关闭。"
        }
    }

    @discardableResult
    private func releaseHotKey() -> Bool {
        guard let hotKey else { return true }
        if let status = hotKey.invalidate() {
            shortcutError = "无法卸载原快捷键，新的设置尚未生效（OSStatus \(status)）。"
            return false
        }
        self.hotKey = nil
        return true
    }
}

private struct QuickEntryHotKeyError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "快捷键已被其他应用或系统占用，请换用另一组（OSStatus \(status)）。"
        }
        return "\(operation)失败，快捷键尚未生效（OSStatus \(status)）。"
    }
}

private final class QuickEntryCallback {
    let deliver: (Bool) -> Void
    init(deliver: @escaping (Bool) -> Void) { self.deliver = deliver }
}

private let quickEntryEventHandler: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == 0x51444149, identifier.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }
    let callback = Unmanaged<QuickEntryCallback>.fromOpaque(context).takeUnretainedValue()
    callback.deliver(GetEventKind(event) == UInt32(kEventHotKeyPressed))
    return noErr
}

@MainActor
private final class QuickEntryHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var context: UnsafeMutableRawPointer?
    private var isActive = false
    private var isPressed = false
    private let onPress: () -> Void

    init(shortcut: QuickEntryShortcut, onPress: @escaping () -> Void) throws {
        self.onPress = onPress
        guard let key = shortcut.key else { return }
        let callback = QuickEntryCallback { [weak self] pressed in
            DispatchQueue.main.async { self?.receive(pressed: pressed) }
        }
        context = Unmanaged.passRetained(callback).toOpaque()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), quickEntryEventHandler,
                                                eventTypes.count, &eventTypes, context, &handler)
        guard handlerStatus == noErr else {
            releaseContext()
            throw QuickEntryHotKeyError(operation: "监听全局快捷键", status: handlerStatus)
        }
        let identifier = EventHotKeyID(signature: 0x51444149, id: 1)
        let keyStatus = RegisterEventHotKey(key.code, key.modifiers, identifier, GetApplicationEventTarget(),
                                            OptionBits(kEventHotKeyExclusive), &hotKey)
        guard keyStatus == noErr else {
            invalidate()
            throw QuickEntryHotKeyError(operation: "注册全局快捷键", status: keyStatus)
        }
        isActive = true
    }

    @discardableResult
    func invalidate() -> OSStatus? {
        isActive = false
        isPressed = false
        var failure: OSStatus?
        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            if status == noErr { self.hotKey = nil } else { failure = status }
        }
        if let handler {
            let status = RemoveEventHandler(handler)
            if status == noErr {
                self.handler = nil
                releaseContext()
            } else if failure == nil {
                failure = status
            }
        }
        return failure
    }

    private func receive(pressed: Bool) {
        guard isActive else { return }
        if pressed {
            guard !isPressed else { return }
            isPressed = true
            onPress()
        } else {
            isPressed = false
        }
    }

    private func releaseContext() {
        if let context { Unmanaged<QuickEntryCallback>.fromOpaque(context).release() }
        context = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler {
            // A retained, weak-target callback remains safe if system removal fails.
            if RemoveEventHandler(handler) == noErr, let context {
                Unmanaged<QuickEntryCallback>.fromOpaque(context).release()
            }
        }
    }
}
