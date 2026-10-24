import SwiftUI

private typealias EditorState<Value> = SwiftUI.State<Value>

@MainActor
private struct LedgerEditorFrame<Content: View>: View {
    @ObservedObject var store: TaskStore
    let title: String
    let isDirty: Bool
    let canSave: Bool
    let onClose: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @EditorState private var showsDiscardConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("返回", systemImage: "chevron.left", action: requestClose)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canSave || store.isReadOnly)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            Rectangle().fill(QingTheme(scheme: colorScheme).line).frame(height: 0.5)
            Form { content() }
                .formStyle(.grouped)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 12))
                .disabled(store.isReadOnly)
            if let error = store.errorMessage {
                ScrollView {
                    Text(error).font(.system(size: 11)).foregroundStyle(QingTheme(scheme: colorScheme).failureText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 55)
                .padding(.horizontal, 14)
            }
        }
        .background(QingTheme(scheme: colorScheme).canvas)
        .onAppear { store.clearError() }
        .onExitCommand(perform: requestClose)
        .alert("放弃未保存的修改？", isPresented: $showsDiscardConfirmation) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive, action: onClose)
        } message: { Text("返回后，本次输入不会保存。") }
    }

    private func requestClose() {
        if isDirty { showsDiscardConfirmation = true }
        else { onClose() }
    }
}

@MainActor
struct ProjectEditor: View {
    @ObservedObject var store: TaskStore
    let projectId: UUID?
    let onClose: () -> Void
    @EditorState private var name: String
    private let originalName: String

    init(store: TaskStore, projectId: UUID?, onClose: @escaping () -> Void) {
        self.store = store
        self.projectId = projectId
        self.onClose = onClose
        let name = store.projects.first { $0.id == projectId }?.name ?? ""
        originalName = name
        _name = EditorState(initialValue: name)
    }

    var body: some View {
        LedgerEditorFrame(store: store, title: projectId == nil ? "新增项目" : "重命名项目",
                          isDirty: name != originalName, canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          onClose: onClose, onSave: save) {
            Section("项目信息") {
                TextField("项目名称", text: $name)
                    .help("1–80 个字")
            }
        }
    }

    private func save() {
        if store.saveProject(id: projectId, name: name) { onClose() }
    }
}

@MainActor
struct RegionEditor: View {
    @ObservedObject var store: TaskStore
    let projectId: UUID
    let regionId: UUID?
    let onClose: () -> Void
    @EditorState private var name: String
    private let originalName: String

    init(store: TaskStore, projectId: UUID, regionId: UUID?, onClose: @escaping () -> Void) {
        self.store = store
        self.projectId = projectId
        self.regionId = regionId
        self.onClose = onClose
        let name = store.regions.first { $0.id == regionId }?.name ?? ""
        originalName = name
        _name = EditorState(initialValue: name)
    }

    var body: some View {
        LedgerEditorFrame(store: store, title: regionId == nil ? "新增地区" : "重命名地区",
                          isDirty: name != originalName, canSave: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          onClose: onClose, onSave: save) {
            Section(store.projectName(projectId)) {
                TextField("地区名称", text: $name)
            }
            if regionId == nil {
                DisclosureGroup("补录历史更新") {
                    Text("在“更新”页显示历史记录，编辑更新并补选本地区，再登记进度。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() {
        if store.saveRegion(id: regionId, projectId: projectId, name: name) { onClose() }
    }
}

private struct UpdateDraft: Equatable {
    var projectId: UUID?
    var title = ""
    var version = ""
    var notes = ""
    var regionIds = Set<UUID>()
}

@MainActor
struct UpdateEditor: View {
    @ObservedObject var store: TaskStore
    let updateId: UUID?
    let onClose: () -> Void
    @EditorState private var draft: UpdateDraft
    private let original: UpdateDraft
    private let existingRegionIds: Set<UUID>

    init(store: TaskStore, updateId: UUID?, defaultProjectId: UUID?, onClose: @escaping () -> Void) {
        self.store = store
        self.updateId = updateId
        self.onClose = onClose
        let existing = store.updates.first { $0.id == updateId }
        let projectId = existing?.projectId ?? defaultProjectId ?? store.activeProjects.first?.id
        let ids = existing.map { Set($0.regions.map(\.regionId)) }
            ?? Set(store.regions.filter { $0.projectId == projectId && !$0.isArchived }.map(\.id))
        let initial = UpdateDraft(projectId: projectId, title: existing?.title ?? "",
                                  version: existing?.version ?? "", notes: existing?.notes ?? "", regionIds: ids)
        original = initial
        existingRegionIds = existing.map { Set($0.regions.map(\.regionId)) } ?? []
        _draft = EditorState(initialValue: initial)
    }

    private var availableRegions: [ProjectRegion] {
        store.regions.filter {
            $0.projectId == draft.projectId && (!$0.isArchived || existingRegionIds.contains($0.id))
        }
    }

    var body: some View {
        LedgerEditorFrame(store: store, title: updateId == nil ? "登记更新" : "编辑更新",
                          isDirty: draft != original,
                          canSave: draft.projectId != nil && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.regionIds.isEmpty,
                          onClose: onClose, onSave: save) {
            Section("更新内容") {
                Picker("所属项目", selection: $draft.projectId) {
                    Text("选择项目").tag(nil as UUID?)
                    ForEach(store.projects.filter { !$0.isArchived || $0.id == draft.projectId }) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .disabled(updateId != nil)
                TextField("更新标题", text: $draft.title, axis: .vertical)
                    .lineLimit(1...3)
                TextField("版本号（可选）", text: $draft.version)
                TextField("更新说明（可选）", text: $draft.notes, axis: .vertical)
                    .lineLimit(2...6)
            }
            Section("适用地区 · \(draft.regionIds.count)") {
                if availableRegions.isEmpty {
                    Text("请先添加地区")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("全选") { draft.regionIds.formUnion(availableRegions.map(\.id)) }
                        Spacer()
                        Button(existingRegionIds.isEmpty ? "清空" : "仅保留已有") { draft.regionIds = existingRegionIds }
                    }
                    ForEach(availableRegions) { region in
                        Toggle(isOn: Binding(
                            get: { draft.regionIds.contains(region.id) },
                            set: { selected in
                                if selected { draft.regionIds.insert(region.id) }
                                else { draft.regionIds.remove(region.id) }
                            }
                        )) {
                            Text(region.name + (region.isArchived ? "（归档）" : ""))
                        }
                        .toggleStyle(.checkbox)
                        .disabled(existingRegionIds.contains(region.id))
                    }
                }
            }
            if updateId != nil {
                Text("已有地区可在进度中改为“不适用”。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onChange(of: draft.projectId) { _, projectId in
            guard updateId == nil else { return }
            draft.regionIds = Set(store.regions.filter { $0.projectId == projectId && !$0.isArchived }.map(\.id))
        }
    }

    private func save() {
        guard let projectId = draft.projectId else { return }
        if store.saveUpdate(id: updateId, projectId: projectId, title: draft.title,
                            version: draft.version, notes: draft.notes, regionIds: draft.regionIds) { onClose() }
    }
}

private struct ProgressDraft: Equatable {
    var status: UpdateStatus = .pending
    var notes = ""
    var completedAt = Date()
}

@MainActor
struct RegionProgressEditor: View {
    @ObservedObject var store: TaskStore
    let updateId: UUID
    let regionId: UUID
    let onClose: () -> Void
    @EditorState private var draft: ProgressDraft
    @EditorState private var original: ProgressDraft

    init(store: TaskStore, updateId: UUID, regionId: UUID, onClose: @escaping () -> Void) {
        self.store = store
        self.updateId = updateId
        self.regionId = regionId
        self.onClose = onClose
        let record = store.updates.first { $0.id == updateId }?.regions.first { $0.regionId == regionId }
        let initial = ProgressDraft(status: record?.status ?? .pending, notes: record?.notes ?? "",
                                    completedAt: record?.completedAt ?? Date())
        _original = EditorState(initialValue: initial)
        _draft = EditorState(initialValue: initial)
    }

    private var update: ProjectUpdate? { store.updates.first { $0.id == updateId } }
    private var record: RegionUpdate? { update?.regions.first { $0.regionId == regionId } }
    private var existingTodo: TodoItem? {
        store.items.first { !$0.isCompleted && $0.updateId == updateId && $0.regionId == regionId }
    }

    var body: some View {
        LedgerEditorFrame(store: store, title: "地区更新进度", isDirty: draft != original,
                          canSave: record != nil, onClose: onClose, onSave: save) {
            Section(store.projectName(update?.projectId) + " · " + store.regionName(regionId)) {
                Text(update?.title ?? "更新已不存在").fontWeight(.medium)
                if let update, !update.version.isEmpty { Text("版本：\(update.version)").foregroundStyle(.secondary) }
                if let update, !update.notes.isEmpty {
                    Text(update.notes).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("实际进度") {
                Picker("状态", selection: $draft.status) {
                    ForEach(UpdateStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
                TextField("备注", text: $draft.notes, axis: .vertical)
                    .lineLimit(2...5)
                if draft.status == .updated {
                    DatePicker("完成日期", selection: $draft.completedAt, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.field)
                    DatePicker("完成时间", selection: $draft.completedAt, in: ...Date(), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                }
            }
            Section("关联待办") {
                if let existingTodo {
                    Text(existingTodo.title)
                        .font(.system(size: 11))
                        .help("完成待办后，仍需登记实际更新状态。")
                } else {
                    Button("加入待办", systemImage: "plus.circle") {
                        _ = store.addUpdateTodo(updateId: updateId, regionId: regionId)
                    }
                    .disabled(record?.status.isOutstanding != true)
                    .help("完成待办后，仍需登记实际更新状态。")
                }
            }
            DisclosureGroup("历史记录（\(record?.history.count ?? 0)）") {
                if let record, !record.history.isEmpty {
                    ForEach(record.history.reversed()) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                UpdateStatusBadge(status: event.status)
                                Spacer()
                                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if !event.notes.isEmpty {
                                Text(event.notes).font(.system(size: 11)).textSelection(.enabled)
                            }
                            if let date = event.completedAt {
                                Text("实际完成：\(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else { Text("暂无历史记录").foregroundStyle(.secondary) }
            }
        }
    }

    private func save() {
        if store.saveProgress(updateId: updateId, regionId: regionId, status: draft.status,
                              notes: draft.notes, completedAt: draft.completedAt) { onClose() }
    }
}
