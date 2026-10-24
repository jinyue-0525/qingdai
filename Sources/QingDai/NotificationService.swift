import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled: Bool
    @Published private(set) var authorizationLabel = "未启用"
    @Published private(set) var permissionDenied = false
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    var onOpenTask: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let enabledKey = "QingDai.notificationsEnabled"
    private let requestPrefix = "qingdai.task."
    private var syncGeneration = 0
    private var syncTask: Task<Void, Never>?
    private var itemSubscription: AnyCancellable?
    private weak var store: TaskStore?

    override init() {
        enabled = defaults.bool(forKey: enabledKey)
        super.init()
        center.delegate = self
        refreshAuthorization()
    }

    func requestEnable(items: [TodoItem]) {
        guard !isUpdating else { return }
        isUpdating = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.isUpdating = false
                if let error {
                    self.errorMessage = "通知权限请求失败：\(error.localizedDescription)"
                    return
                }
                self.enabled = granted
                self.permissionDenied = !granted
                self.defaults.set(granted, forKey: self.enabledKey)
                self.authorizationLabel = granted ? "已启用" : "已拒绝"
                self.sync(items)
            }
        }
    }

    func disable() {
        guard !isUpdating else { return }
        enabled = false
        defaults.set(false, forKey: enabledKey)
        enqueueSync([])
        refreshAuthorization()
    }

    func sync(_ items: [TodoItem]) {
        enqueueSync(items)
    }

    var isEnabled: Bool { enabled }
    var authorizationDescription: String { authorizationLabel }

    func start(store: TaskStore, onOpenItem: @escaping (UUID) -> Void) {
        self.store = store
        onOpenTask = onOpenItem
        itemSubscription?.cancel()
        itemSubscription = store.$items
            .sink { [weak self] items in self?.sync(items) }
    }

    func stop() {
        itemSubscription?.cancel()
        itemSubscription = nil
        store = nil
        onOpenTask = nil
        syncTask?.cancel()
        syncTask = nil
    }

    func setEnabled(_ newValue: Bool) {
        if newValue {
            requestEnable(items: store?.items ?? [])
        } else {
            disable()
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func clearError() {
        errorMessage = nil
    }

    private func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.authorizationLabel = self.enabled ? "已启用" : "已关闭"
                case .denied:
                    self.authorizationLabel = "已拒绝"
                case .notDetermined:
                    self.authorizationLabel = "未启用"
                @unknown default:
                    self.authorizationLabel = "未知"
                }
                self.permissionDenied = settings.authorizationStatus == .denied
            }
        }
    }

    private func enqueueSync(_ items: [TodoItem]) {
        syncGeneration &+= 1
        let generation = syncGeneration
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await withCheckedContinuation { continuation in
                self.center.getNotificationSettings { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled, generation == self.syncGeneration else { return }

            guard self.enabled else {
                await self.removeOwnedRequests()
                return
            }

            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                self.authorizationLabel = settings.authorizationStatus == .denied ? "已拒绝" : "等待授权"
                self.permissionDenied = settings.authorizationStatus == .denied
                await self.removeOwnedRequests()
                return
            }

            self.authorizationLabel = "已启用"
            self.permissionDenied = false
            let now = Date()
            let scheduled = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, TodoItem)? in
                guard let date = item.notificationDate, date > now else { return nil }
                return (self.requestIdentifier(for: item.id), item)
            })
            let pending = await self.pendingRequests()
            let ownedPending = pending.filter { $0.identifier.hasPrefix(self.requestPrefix) }
            let stale = ownedPending.compactMap { request in
                scheduled[request.identifier] == nil ? request.identifier : nil
            }
            if !stale.isEmpty {
                self.center.removePendingNotificationRequests(withIdentifiers: stale)
            }

            for (identifier, item) in scheduled {
                guard !Task.isCancelled, generation == self.syncGeneration else { return }
                guard let date = item.notificationDate, date > Date() else { continue }

                let content = UNMutableNotificationContent()
                content.title = "轻待"
                content.body = item.title
                content.sound = .default
                content.userInfo = ["taskId": item.id.uuidString.lowercased()]
                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: date
                )
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
                do {
                    try await self.center.add(request)
                } catch {
                    self.errorMessage = "提醒安排失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func requestIdentifier(for id: UUID) -> String {
        requestPrefix + id.uuidString.lowercased()
    }

    private func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    private func removeOwnedRequests() async {
        let identifiers = await pendingRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(requestPrefix) }
        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let value = response.notification.request.content.userInfo["taskId"] as? String
        Task { @MainActor [weak self] in
            if let value, let id = UUID(uuidString: value) {
                self?.onOpenTask?(id)
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

typealias ReminderManager = NotificationService
