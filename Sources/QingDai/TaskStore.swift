import Combine
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var projects: [ManagedProject] = []
    @Published private(set) var regions: [ProjectRegion] = []
    @Published private(set) var updates: [ProjectUpdate] = []
    @Published private(set) var now = Date()
    @Published private(set) var canUndo = false
    @Published private(set) var lastChangeLabel: String?
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    private(set) var isReadOnly = false

    let storage: ArchiveStorage
    let directoryURL: URL
    var onItemsChanged: (([TodoItem]) -> Void)?
    var notice: String? { lastChangeLabel }

    private var undoData: WorkspaceData?
    private var serialized: Data?
    private var clock: AnyCancellable?
    private var nextWake: Timer?
    private var feedbackTask: Task<Void, Never>?
    private var hasLoaded = false

    var snapshot: WorkspaceData {
        WorkspaceData(items: items, projects: projects, regions: regions, updates: updates)
    }

    init(storage: ArchiveStorage = ArchiveStorage()) {
        self.storage = storage
        directoryURL = storage.directoryURL
        load()
        clock = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshTime() }
        scheduleWake()
    }

    var activeItems: [TodoItem] {
        stablePinned(items.filter { !$0.isCompleted && !$0.isDeferred(at: now) })
    }

    var deferredItems: [TodoItem] {
        stablePinned(items.filter { $0.isDeferred(at: now) })
    }

    var laterItems: [TodoItem] { deferredItems }

    var completedItems: [TodoItem] {
        items.filter(\.isCompleted)
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var remainingCount: Int { items.lazy.filter { !$0.isCompleted }.count }

    var completedTodayCount: Int {
        items.lazy.filter { item in
            item.completedAt.map { Calendar.current.isDate($0, inSameDayAs: self.now) } ?? false
        }.count
    }

    var pinnedRemainingCount: Int { items.lazy.filter { !$0.isCompleted && $0.isPinned }.count }

    var allTags: [String] {
        Array(Set(items.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            guard let data = try storage.read() else {
                serialized = try TaskArchive.encode(WorkspaceData())
                onItemsChanged?([])
                return
            }
            let decoded = try TaskArchive.decode(data)
            apply(decoded)
            serialized = try TaskArchive.encode(decoded)
            onItemsChanged?(items)
        } catch {
            isReadOnly = true
            errorMessage = "无法读取本地记录，已暂停写入以保留原文件。可从设置恢复有效备份。\n\(error.localizedDescription)"
        }
    }

    @discardableResult
    func add(_ title: String) -> Bool {
        add(title, tag: nil)
    }

    @discardableResult
    func add(_ title: String, tag: String?, projectId: UUID? = nil, regionId: UUID? = nil) -> Bool {
        guard let title = validatedTitle(title) else { return false }
        if let tag, !allTags.contains(tag) {
            errorMessage = "这个标签已不存在，请重新选择。"
            return false
        }
        return commit([TodoItem(
            title: title, tags: tag.map { [$0] } ?? [], projectId: projectId, regionId: regionId
        )] + items, message: "已添加待办")
    }

    func complete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isCompleted else { return }
        var updated = items
        let original = updated[index]
        let completedAt = Date()
        updated[index].completedAt = completedAt
        updated[index].deferredUntil = nil
        var message = "已完成，收进完成记录"

        if original.repeatRule != .none,
           !items.contains(where: { $0.generatedFromId == original.id }) {
            do {
                let anchor = original.repeatAnchor ?? original.reminderAt ?? original.deferredUntil ?? completedAt
                let series = original.seriesId ?? original.id
                updated[index].repeatAnchor = anchor
                updated[index].seriesId = series

                let next = try nextRepeatDate(for: original, after: completedAt)
                var successor = original
                successor.id = UUID()
                successor.createdAt = completedAt
                successor.completedAt = nil
                successor.deferredUntil = next
                successor.reminderAt = original.reminderAt == nil ? nil : next
                successor.repeatAnchor = anchor
                successor.seriesId = series
                successor.generatedFromId = original.id
                updated.append(successor)
                message = "已完成，下一次已安排到稍后"
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        _ = commit(updated, message: message)
    }

    func restore(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isCompleted else { return }
        var updated = items
        let hasSuccessor = updated.contains { $0.generatedFromId == id }
        updated[index].completedAt = nil
        updated[index].deferredUntil = nil
        updated[index].reminderAt = nil
        if hasSuccessor {
            updated[index].repeatRule = .none
            updated[index].repeatAnchor = nil
        }
        _ = commit(updated, message: hasSuccessor ? "已恢复为普通待办，后续重复计划保留" : "已恢复到现在")
    }

    @discardableResult
    func postpone(_ id: UUID, until date: Date) -> Bool {
        guard date > Date() else { errorMessage = "延后时间需要晚于现在。"; return false }
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isCompleted else { return false }
        var updated = items
        let original = updated[index]
        updated[index].deferredUntil = date
        if original.reminderAt != nil { updated[index].reminderAt = date }
        if original.repeatRule != .none, original.repeatAnchor == nil {
            updated[index].repeatAnchor = original.reminderAt ?? original.deferredUntil ?? Date()
        }
        return commit(updated, message: "已移到稍后，到时自动回来")
    }

    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isCompleted else { return }
        var updated = items
        updated[index].deferredUntil = nil
        _ = commit(updated, message: "已移回现在")
    }

    @discardableResult
    func rename(_ id: UUID, to title: String) -> Bool {
        guard let title = validatedTitle(title) else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            errorMessage = "这条事项已不存在，请先保留输入内容。"
            return false
        }
        guard items[index].title != title else { errorMessage = nil; return true }
        var updated = items
        updated[index].title = title
        return commit(updated, message: "已修改待办")
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].isPinned.toggle()
        _ = commit(updated, message: updated[index].isPinned ? "已置顶" : "已取消置顶")
    }

    func delete(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        _ = commit(items.filter { $0.id != id }, message: "已删除")
    }

    @discardableResult
    func update(_ id: UUID, draft: TaskDetailsDraft) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            errorMessage = "这条事项已不存在。"
            return false
        }
        guard let title = validatedTitle(draft.title) else { return false }
        let links = draft.linksText.split(whereSeparator: \.isNewline).map(String.init)
        let tags = draft.tagsText.split(whereSeparator: { ",，\n".contains($0) }).map(String.init)
        var updated = items
        updated[index].title = title
        updated[index].notes = draft.notes
        updated[index].links = links
        updated[index].tags = tags
        updated[index].projectId = draft.projectId
        updated[index].regionId = draft.regionId
        updated[index].updateId = draft.updateId
        updated[index].reminderEnabled = draft.reminderEnabled
        updated[index].reminderAt = draft.reminderEnabled ? draft.reminderAt : nil
        updated[index].repeatRule = draft.repeatRule
        updated[index].repeatAnchor = draft.repeatRule == .none
            ? nil
            : (updated[index].repeatAnchor ?? draft.reminderAt)
        return commit(updated, message: "已保存事项详情")
    }

    func move(draggedID: UUID, relativeTo targetID: UUID) {
        reorder(draggedID: draggedID, targetID: targetID)
    }

    func move(_ draggedID: UUID, relativeTo targetID: UUID) {
        reorder(draggedID: draggedID, targetID: targetID)
    }

    func undoLastChange() {
        guard let previous = undoData else { return }
        do {
            let data = try TaskArchive.encode(previous)
            try storage.write(data)
            apply(previous)
            serialized = data
            undoData = nil
            canUndo = false
            errorMessage = nil
            showFeedback("已撤销刚才的操作")
            refreshTime()
            scheduleWake()
            onItemsChanged?(items)
        } catch { errorMessage = "撤销未保存：\(error.localizedDescription)" }
    }

    func undo() { undoLastChange() }

    @discardableResult
    func exportArchive(to url: URL) -> Bool {
        do {
            try TaskArchive.encode(snapshot).write(to: url, options: .atomic)
            showFeedback("备份已导出")
            return true
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func importArchive(from url: URL, mode: ImportMode) -> Bool {
        do {
            let incoming = try TaskArchive.decode(Data(contentsOf: url, options: .mappedIfSafe))
            if isReadOnly {
                guard mode == .replace else {
                    errorMessage = "原数据无法读取时不能安全合并，请选择“替换恢复”。"
                    return false
                }
                try recover(with: incoming, message: "数据已恢复，原文件已保留备份")
                return true
            }
            let updated: WorkspaceData
            switch mode {
            case .replace:
                updated = incoming
            case .merge:
                updated = snapshot.merging(incoming)
            }
            return commit(
                updated,
                message: mode == .replace ? "数据已替换" : "数据已合并",
                forceBackup: mode == .replace
            )
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
            return false
        }
    }

    func backups() -> [TaskBackup] {
        do { return try storage.listBackups() }
        catch { errorMessage = "读取备份失败：\(error.localizedDescription)"; return [] }
    }

    @discardableResult
    func restoreBackup(_ backup: TaskBackup) -> Bool {
        do {
            let restored = try TaskArchive.decode(storage.readBackup(backup))
            if isReadOnly {
                try recover(with: restored, message: "备份已恢复，原文件已另存")
                return true
            }
            return commit(restored, message: "备份已恢复", forceBackup: true)
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
            return false
        }
    }

    func clearError() { if !isReadOnly { errorMessage = nil } }

    func clearNotice() {
        feedbackTask?.cancel()
        feedbackTask = nil
        lastChangeLabel = nil
    }

    func refreshTime() { now = Date() }

    private func reorder(draggedID: UUID, targetID: UUID) {
        guard draggedID != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = items.firstIndex(where: { $0.id == targetID })
        else { return }
        var updated = items
        let dragged = updated.remove(at: sourceIndex)
        // Original targetIndex puts the row after the target while moving down,
        // and before it while moving up, which follows the drag direction.
        updated.insert(dragged, at: min(targetIndex, updated.endIndex))
        _ = commit(updated, message: "已调整顺序")
    }

    private func validatedTitle(_ title: String) -> String? {
        guard !isReadOnly else { errorMessage = "记录当前为只读状态，请先从有效备份恢复。"; return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "待办内容不能为空。"; return nil }
        guard trimmed.count <= 500 else { errorMessage = "一条待办最多写 500 个字，可以拆成几件小事。"; return nil }
        return trimmed
    }

    @discardableResult
    private func commit(_ proposed: [TodoItem], message: String, forceBackup: Bool = false) -> Bool {
        var archive = snapshot
        archive.items = proposed
        return commit(archive, message: message, forceBackup: forceBackup)
    }

    @discardableResult
    func commit(_ proposed: WorkspaceData, message: String, forceBackup: Bool = false) -> Bool {
        guard !isReadOnly else { errorMessage = "记录当前为只读状态，请先从有效备份恢复。"; return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let checked = try TaskArchive.validate(proposed)
            let data = try TaskArchive.encode(checked)
            if data == serialized { errorMessage = nil; return true }
            try storage.write(data, forceBackup: forceBackup)
            undoData = snapshot
            canUndo = true
            apply(checked)
            serialized = data
            errorMessage = nil
            refreshTime()
            showFeedback(message)
            scheduleWake()
            onItemsChanged?(items)
            return true
        } catch {
            errorMessage = "这次修改未能保存，原来的记录仍在。\n\(error.localizedDescription)"
            return false
        }
    }

    private func recover(with proposed: WorkspaceData, message: String) throws {
        let checked = try TaskArchive.validate(proposed)
        let data = try TaskArchive.encode(checked)
        try storage.write(data, forceBackup: true)
        apply(checked)
        serialized = data
        undoData = nil
        canUndo = false
        isReadOnly = false
        errorMessage = nil
        refreshTime()
        showFeedback(message)
        scheduleWake()
        onItemsChanged?(items)
    }

    private func apply(_ archive: WorkspaceData) {
        projects = archive.projects
        regions = archive.regions
        updates = archive.updates
        items = archive.items
    }

    private func stablePinned(_ source: [TodoItem]) -> [TodoItem] {
        source.filter(\.isPinned) + source.filter { !$0.isPinned }
    }

    private func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        lastChangeLabel = message
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.lastChangeLabel = nil
            self?.feedbackTask = nil
        }
    }

    private func scheduleWake() {
        nextWake?.invalidate()
        nextWake = nil
        guard let date = items.compactMap({ !$0.isCompleted ? $0.deferredUntil : nil })
            .filter({ $0 > Date() }).min()
        else { return }
        let timer = Timer(timeInterval: max(0.1, date.timeIntervalSinceNow + 0.05), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTime()
                self?.scheduleWake()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nextWake = timer
    }
}

func nextRepeatDate(for item: TodoItem, after date: Date) throws -> Date {
    guard item.repeatRule != .none else { throw TaskDataError.invalid("这条事项没有重复规则。") }
    let calendar = Calendar.current
    let anchor = item.repeatAnchor ?? item.reminderAt ?? item.deferredUntil ?? date
    let anchorDay = calendar.startOfDay(for: anchor)
    let time = calendar.dateComponents([.hour, .minute, .second], from: anchor)

    func occurrence(dayOffset: Int) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: anchorDay) else { return nil }
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: time.second ?? 0,
            of: day
        )
    }

    switch item.repeatRule {
    case .none:
        break
    case .daily, .weekly:
        let step = item.repeatRule == .weekly ? 7 : 1
        let elapsedDays = max(
            0,
            calendar.dateComponents([.day], from: anchorDay, to: calendar.startOfDay(for: date)).day ?? 0
        )
        var offset = max(step, (elapsedDays / step) * step)
        for _ in 0..<4_000 {
            guard let candidate = occurrence(dayOffset: offset) else { break }
            if candidate > date { return candidate }
            offset += step
        }
    case .weekdays:
        var offset = max(
            1,
            calendar.dateComponents([.day], from: anchorDay, to: calendar.startOfDay(for: date)).day ?? 0
        )
        for _ in 0..<3_000 {
            guard let candidate = occurrence(dayOffset: offset) else { break }
            let weekday = calendar.component(.weekday, from: candidate)
            if candidate > date, weekday != 1, weekday != 7 { return candidate }
            offset += 1
        }
    }
    throw TaskDataError.invalid("无法计算下一次重复日期。")
}
