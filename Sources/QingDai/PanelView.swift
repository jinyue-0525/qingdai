import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Select the property wrapper explicitly: the macOS 27 CLI SDK omits the same-name macro plugin.
private typealias NativeState<Value> = SwiftUI.State<Value>

private enum PanelRegion: Hashable { case chrome, content, footer, scheduler, notices }

private struct PanelHeightPreference: PreferenceKey {
    static let defaultValue: [PanelRegion: CGFloat] = [:]

    static func reduce(value: inout [PanelRegion: CGFloat], nextValue: () -> [PanelRegion: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct RowScrollTarget: Equatable {
    let id: UUID?
    let availableHeight: CGFloat
    let contentHeight: CGFloat
    let editingError: String?
    let isPresented: Bool
}

private extension View {
    func measurePanelHeight(_ region: PanelRegion) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightPreference.self, value: [region: geometry.size.height])
            }
        }
    }
}

private enum TaskPage: String, CaseIterable, Identifiable {
    case now = "现在"
    case later = "稍后"
    case all = "全部"
    case tags = "标签"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .now: "sun.max"
        case .later: "clock"
        case .all: "tray.full"
        case .tags: "tag"
        }
    }
}

private enum HistoryFilter: String, CaseIterable {
    case all = "所有事项"
    case unfinished = "未完成"
    case completed = "已完成"
}

private enum PanelMode: Equatable {
    case tasks, ledger
}

struct PanelView: View {
    static let panelSize = CGSize(width: 340, height: 300)

    @ObservedObject var store: TaskStore
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var preferences: SystemPreferences
    @ObservedObject var reminders: ReminderManager
    @ObservedObject var backups: BackupCoordinator
    let onHeightChange: (CGFloat) -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearanceMode") private var appearanceMode = "light"
    @FocusState private var composerFocused: Bool
    @NativeState private var page: TaskPage = .now
    @NativeState private var historyFilter: HistoryFilter = .all
    @NativeState private var draft = ""
    @NativeState private var composerTag: String?
    @NativeState private var search = ""
    @NativeState private var schedulingItem: TodoItem?
    @NativeState private var scheduledDate = Date().addingTimeInterval(3600)
    @NativeState private var regionHeights: [PanelRegion: CGFloat] = [:]
    @NativeState private var editingID: UUID?
    @NativeState private var editingDraft = ""
    @NativeState private var editingError: String?
    @NativeState private var expandedID: UUID?
    @NativeState private var interactionMessage: String?
    @NativeState private var focusTask: Task<Void, Never>?
    @NativeState private var heightTask: Task<Void, Never>?
    @NativeState private var detailsID: UUID?
    @NativeState private var detailsAreDirty = false
    @NativeState private var selectedTag: String?
    @NativeState private var draggingItemID: UUID?
    @NativeState private var panelMode: PanelMode = .tasks
    @NativeState private var workspaceScope = WorkspaceScope()

    private var desiredHeight: CGFloat {
        if detailsID != nil { return 373 }
        if panelMode == .ledger { return 460 }
        if visibleItems.count > 4 { return 460 }
        let measured = (regionHeights[.chrome] ?? 144) + (regionHeights[.content] ?? 120) + (regionHeights[.footer] ?? 33)
        let schedulerHeight = schedulingItem == nil ? 0 : (regionHeights[.scheduler] ?? 290) + 20
        return min(460, max(250, ceil(max(measured, schedulerHeight))))
    }

    private var listHeight: CGFloat {
        max(40, desiredHeight - (regionHeights[.chrome] ?? 144) - (regionHeights[.footer] ?? 33))
    }

    private var appearanceOverride: ColorScheme? {
        switch appearanceMode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
    private var displayScheme: ColorScheme { appearanceOverride ?? colorScheme }
    private var theme: QingTheme { QingTheme(scheme: displayScheme) }
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.16) }
    private var iconMotion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.12) }
    private var detailsItem: TodoItem? {
        guard let detailsID else { return nil }
        return store.items.first(where: { $0.id == detailsID })
    }

    private var visibleItems: [TodoItem] {
        let source: [TodoItem]
        switch page {
        case .now:
            source = store.activeItems
        case .later:
            source = store.deferredItems
        case .all:
            switch historyFilter {
            case .all: source = store.activeItems + store.deferredItems + store.completedItems
            case .unfinished: source = store.activeItems + store.deferredItems
            case .completed: source = store.completedItems
            }
        case .tags:
            let unfinished = store.activeItems + store.deferredItems
            if let selectedTag {
                source = unfinished.filter { $0.tags.contains(selectedTag) }
            } else {
                source = unfinished.filter { !$0.tags.isEmpty }
            }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = source.filter { workspaceScope.includes($0) }
        var result = page != .all || query.isEmpty ? scoped : scoped.filter { $0.title.localizedStandardContains(query) }
        // A deferred item becoming due must not hide an unfinished inline edit.
        if let editingID, !result.contains(where: { $0.id == editingID }), let editedItem = store.items.first(where: { $0.id == editingID }) {
            result.insert(editedItem, at: 0)
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            background
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    modeSelector
                    if panelMode == .tasks {
                        composer
                        if !store.projects.isEmpty {
                            WorkspaceScopePicker(store: store, scope: $workspaceScope,
                                                 includesUnassigned: true, includesCommon: true)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 6)
                                .disabled(editingID != nil)
                        }
                        navigationBar
                        if page == .all {
                            historyControls
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if page == .tags {
                            tagControls
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
                .measurePanelHeight(.chrome)
                ZStack(alignment: .top) {
                    listArea
                        .opacity(panelMode == .tasks ? 1 : 0)
                        .allowsHitTesting(panelMode == .tasks)
                        .disabled(panelMode != .tasks)
                        .accessibilityHidden(panelMode != .tasks)
                    UpdateLedgerView(store: store, scope: $workspaceScope, onClose: {
                        if panelMode == .ledger { onClose() }
                    })
                        .opacity(panelMode == .ledger ? 1 : 0)
                        .allowsHitTesting(panelMode == .ledger)
                        .disabled(panelMode != .ledger)
                        .accessibilityHidden(panelMode != .ledger)
                }
                .frame(height: listHeight)
                footer
                    .fixedSize(horizontal: false, vertical: true)
                    .measurePanelHeight(.footer)
            }
            .disabled(schedulingItem != nil || detailsID != nil)
            .accessibilityHidden(schedulingItem != nil || detailsID != nil)

            if let item = schedulingItem {
                Color.black.opacity(displayScheme == .dark ? 0.40 : 0.16)
                    .contentShape(Rectangle())
                    .onTapGesture { closeScheduler() }
                    .transition(.opacity)
                    .accessibilityLabel("关闭延后设置")

                scheduler(for: item)
                    .fixedSize(horizontal: false, vertical: true)
                    .measurePanelHeight(.scheduler)
                    .padding(10)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }

            if let item = detailsItem {
                TaskDetailView(
                    store: store,
                    item: item,
                    onDirtyChange: { detailsAreDirty = $0 },
                    onClose: closeDetails
                )
                .id(item.id)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .frame(width: Self.panelSize.width, height: desiredHeight)
        .tint(theme.accent)
        .foregroundStyle(theme.primary)
        .environment(\.colorScheme, displayScheme)
        .preferredColorScheme(appearanceOverride)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .animation(motion, value: page)
        .animation(motion, value: historyFilter)
        .animation(motion, value: schedulingItem?.id)
        .animation(nil, value: desiredHeight)
        .onPreferenceChange(PanelHeightPreference.self) { values in
            let rounded = values.mapValues { ceil($0) }
            if regionHeights != rounded { regionHeights = rounded }
        }
        .onChange(of: desiredHeight) { _, height in reportHeight(height) }
        .onAppear {
            store.refreshTime()
            preferences.refreshLoginStatus()
            backups.refresh()
            reportHeight(desiredHeight)
            let openedItem = openPendingItemIfPossible()
            if !openedItem, panelMode == .tasks { requestComposerFocus() }
        }
        .onExitCommand(perform: handleEscape)
        .onChange(of: page) { _, newPage in
            if newPage != .all { search = "" }
            expandedID = nil
            draggingItemID = nil
        }
        .onChange(of: historyFilter) { _, _ in expandedID = nil }
        .onChange(of: store.allTags) { _, tags in
            if let composerTag, !tags.contains(composerTag) { self.composerTag = nil }
            if let selectedTag, !tags.contains(selectedTag) { self.selectedTag = nil }
        }
        .onChange(of: presentation.focusRequest) { _, _ in requestComposerFocus() }
        .onChange(of: presentation.itemRequest) { _, _ in openPendingItemIfPossible() }
        .onChange(of: store.items) { _, _ in
            if detailsID != nil, detailsItem == nil { closeDetails() }
        }
        .onChange(of: store.projects) { _, _ in normalizeScope() }
        .onChange(of: store.regions) { _, _ in normalizeScope() }
        .onChange(of: presentation.isPresented) { _, isPresented in
            if isPresented {
                preferences.refreshLoginStatus()
                let openedItem = openPendingItemIfPossible()
                if !openedItem, panelMode == .tasks { requestComposerFocus() }
            } else {
                focusTask?.cancel()
                focusTask = nil
                composerFocused = false
                expandedID = nil
                schedulingItem = nil
                detailsID = nil
                detailsAreDirty = false
                draggingItemID = nil
            }
        }
        .onDisappear {
            focusTask?.cancel()
            heightTask?.cancel()
        }
    }

    private var background: some View {
        VStack(spacing: 0) {
            theme.surface
                .frame(height: 104)
            theme.canvas
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("轻待")
                .font(.system(size: 15, weight: .semibold))
                .help(store.now.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN"))))

            Spacer()

            if panelMode == .tasks {
                Text("今日完成 \(store.completedTodayCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondary)
                    .monospacedDigit()
            }

            Menu {
                Button("更新台账", systemImage: "square.stack.3d.up") { selectMode(.ledger) }
                Divider()
                Button("查看全部事项", systemImage: "tray.full") {
                    selectPage(.all, filter: .all)
                }
                Button("查看已完成", systemImage: "checkmark.circle") {
                    selectPage(.all, filter: .completed)
                }
                Divider()
                Button("撤销上次操作", systemImage: "arrow.uturn.backward") {
                    withAnimation(motion) { store.undoLastChange() }
                }
                .disabled(!store.canUndo || store.isReadOnly || editingID != nil)
                Divider()
                Toggle("系统通知", isOn: Binding(
                    get: { reminders.isEnabled },
                    set: { reminders.setEnabled($0) }
                ))
                .disabled(reminders.isUpdating)
                if reminders.permissionDenied {
                    Button("打开通知设置…", action: reminders.openNotificationSettings)
                }
                Picker("外观", selection: $appearanceMode) {
                    Text("浅蓝白色").tag("light")
                    Text("深色蓝调").tag("dark")
                    Text("跟随系统").tag("system")
                }
                Divider()
                Menu("快速添加：\(preferences.shortcut.displayLabel)") {
                    ForEach(QuickEntryShortcut.allCases, id: \.self) { shortcut in
                        Button {
                            preferences.setShortcut(shortcut)
                        } label: {
                            if preferences.shortcut == shortcut {
                                Label(shortcut.title, systemImage: "checkmark")
                            } else {
                                Text(shortcut.title)
                            }
                        }
                    }
                }
                Toggle("登录时启动", isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                ))
                .disabled(preferences.isUpdatingLoginItem)
                if preferences.loginNeedsApproval {
                    Button("在系统设置中批准登录项…", action: preferences.openLoginSettings)
                    Button("取消开机启动申请") { preferences.setLaunchAtLogin(false) }
                        .disabled(preferences.isUpdatingLoginItem)
                }
                Divider()
                Menu("数据与备份") {
                    Button("导出备份…", systemImage: "square.and.arrow.up", action: backups.exportArchive)
                    Button("导入备份…", systemImage: "square.and.arrow.down", action: backups.importArchive)
                    Button("恢复自动备份…", systemImage: "arrow.clockwise", action: backups.showRestoreOptions)
                    Divider()
                    Button("在 Finder 中显示数据目录", systemImage: "folder", action: backups.openBackupFolder)
                }
                .disabled(backups.isBusy)
                Divider()
                Button("退出轻待", action: onQuit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多选项")
            .help("更多选项")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var modeSelector: some View {
        HStack(spacing: 4) {
            modeButton("待办", symbol: "checkmark.circle", mode: .tasks)
            modeButton("更新台账", symbol: "square.stack.3d.up", count: store.outstandingUpdateCount, mode: .ledger)
        }
        .padding(4)
        .background(theme.subtle, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func modeButton(_ title: String, symbol: String, count: Int = 0, mode: PanelMode) -> some View {
        Button { selectMode(mode) } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                if count > 0 {
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(theme.secondary).monospacedDigit()
                }
            }
                .foregroundStyle(panelMode == mode ? theme.accentText : theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(panelMode == mode ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(QingPressStyle())
        .accessibilityAddTraits(panelMode == mode ? .isSelected : [])
        .disabled(editingID != nil)
    }

    private func selectMode(_ mode: PanelMode) {
        guard editingID == nil else { return }
        composerFocused = false
        expandedID = nil
        if mode == .ledger {
            if workspaceScope.project == .unassigned { workspaceScope.project = .all }
            if workspaceScope.region == .common { workspaceScope.region = .all }
        }
        panelMode = mode
        if mode == .tasks { requestComposerFocus() }
    }

    private func normalizeScope() {
        if let id = workspaceScope.projectId, !store.projects.contains(where: { $0.id == id }) {
            workspaceScope = WorkspaceScope()
        } else if let id = workspaceScope.regionId, !store.regions.contains(where: { $0.id == id }) {
            workspaceScope.region = .all
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("添加待办", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($composerFocused)
                .onSubmit(addTask)
                .accessibilityLabel("新待办内容")
                .help("输入待办内容，按回车添加")
                .disabled(store.isReadOnly || editingID != nil)
            Menu {
                Button {
                    composerTag = nil
                } label: {
                    if composerTag == nil {
                        Label("不加标签", systemImage: "checkmark")
                    } else {
                        Text("不加标签")
                    }
                }
                if store.allTags.isEmpty {
                    Button("可在事项详情中新建标签") { }
                        .disabled(true)
                } else {
                    Divider()
                    ForEach(store.allTags, id: \.self) { tag in
                        Button {
                            composerTag = tag
                        } label: {
                            if composerTag == tag {
                                Label(tag, systemImage: "checkmark")
                            } else {
                                Text(tag)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: composerTag == nil ? "tag" : "tag.fill")
                        .font(.system(size: 11))
                    if let composerTag {
                        Text(composerTag.count > 4 ? String(composerTag.prefix(4)) + "…" : composerTag)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(composerTag == nil ? theme.secondary : theme.accentText)
                .frame(height: 28)
                .padding(.horizontal, composerTag == nil ? 6 : 7)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(composerTag.map { "新增待办标签：\($0)" } ?? "为新待办选择标签")
            .accessibilityLabel(composerTag.map { "新增待办标签：\($0)" } ?? "为新待办选择标签")
            .disabled(store.isReadOnly || editingID != nil)
            Button(action: addTask) {
                Label("添加", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accentInk)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(theme.action, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(QingPressStyle())
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isReadOnly || editingID != nil)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            .accessibilityLabel("添加待办")
            .help("添加待办（回车）")
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(composerFocused ? theme.accent : theme.line, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: composerFocused)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var navigationBar: some View {
        HStack(spacing: 4) {
            ForEach(TaskPage.allCases) { candidate in
                Button {
                    composerFocused = false
                    selectPage(candidate)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: candidate.symbol)
                            .font(.system(size: 10))
                        Text(candidate.rawValue)
                            .font(.system(size: 12, weight: page == candidate ? .semibold : .regular))
                        if candidate != .tags {
                            Text("\(count(for: candidate))")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(theme.secondary)
                        }
                    }
                    .foregroundStyle(page == candidate ? theme.accentText : theme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(page == candidate ? theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(candidate.rawValue)，\(count(for: candidate)) 项")
                .accessibilityAddTraits(page == candidate ? .isSelected : [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var historyControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                    Button { selectPage(.all, filter: filter) } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: historyFilter == filter ? .semibold : .regular))
                            .foregroundStyle(historyFilter == filter ? theme.accentText : theme.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(historyFilter == filter ? theme.subtle : .clear, in: Capsule())
                    }
                    .buttonStyle(QingPressStyle())
                    .accessibilityAddTraits(historyFilter == filter ? .isSelected : [])
                }
                Spacer()
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondary)
                TextField("搜索事项", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityLabel("搜索全部事项")
                    .disabled(editingID != nil)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                    .disabled(editingID != nil)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var tagControls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                tagChip("全部标签", selected: selectedTag == nil) {
                    selectedTag = nil
                    composerTag = nil
                }
                ForEach(store.allTags, id: \.self) { tag in
                    tagChip(tag, selected: selectedTag == tag) {
                        selectedTag = tag
                        composerTag = tag
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
        .frame(height: 36)
        .padding(.bottom, 4)
    }

    private func tagChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.accentText : theme.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selected ? theme.subtle : theme.surface, in: Capsule())
        }
        .buttonStyle(QingPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var taskRows: some View {
        ForEach(visibleItems) { item in
            TodoRow(
                item: item,
                assignmentLabel: store.assignmentLabel(for: item),
                now: store.now,
                isReadOnly: store.isReadOnly || schedulingItem != nil,
                isPresented: presentation.isPresented,
                isEditing: editingID == item.id,
                isAnotherItemEditing: editingID != nil && editingID != item.id,
                editingDraft: $editingDraft,
                editingError: editingID == item.id ? editingError : nil,
                quickActionsExpanded: expandedID == item.id,
                draggingID: draggingItemID,
                canShowDrop: canReorder(draggingItemID, onto: item),
                dropAfter: dropGoesAfter(item),
                onComplete: { changeCompletion(item) },
                onPostpone: { toggleQuickActions(item) },
                onResume: { withAnimation(motion) { store.resume(item.id) } },
                onDelete: { withAnimation(motion) { store.delete(item.id) } },
                onEdit: { beginEditing(item) },
                onDetails: { openDetails(item) },
                onTogglePin: { withAnimation(iconMotion) { store.togglePin(item.id) } },
                onReorder: { draggedID in
                    guard canReorder(draggedID, onto: item) else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)) {
                        store.move(draggedID, relativeTo: item.id)
                    }
                },
                onDragStateChange: { dragging in
                    if dragging {
                        draggingItemID = item.id
                    } else if draggingItemID == item.id {
                        draggingItemID = nil
                    }
                },
                onSave: saveEditing,
                onCancel: cancelEditing,
                onSelect: { if expandedID != item.id { expandedID = nil } },
                onPreset: { postpone(item, to: $0.date(from: Date())) },
                onCustom: { openScheduler(item) }
            )
            .id(item.id)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            ))
        }
    }

    private func canReorder(_ draggedID: UUID?, onto target: TodoItem) -> Bool {
        guard let draggedID,
              let source = store.items.first(where: { $0.id == draggedID }),
              source.id != target.id,
              !source.isCompleted,
              !target.isCompleted else { return false }
        return source.isDeferred(at: store.now) == target.isDeferred(at: store.now)
            && source.isPinned == target.isPinned
    }

    private func dropGoesAfter(_ target: TodoItem) -> Bool {
        guard let draggingItemID,
              let sourceIndex = store.items.firstIndex(where: { $0.id == draggingItemID }),
              let targetIndex = store.items.firstIndex(where: { $0.id == target.id }) else { return false }
        return sourceIndex < targetIndex
    }

    private var listArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if visibleItems.count > 4 {
                    LazyVStack(spacing: 6) { taskRows }
                        .padding(.horizontal, 14)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 6) {
                        if visibleItems.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .transition(.opacity)
                        } else {
                            taskRows
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .measurePanelHeight(.content)
                }
            }
            .scrollIndicators(.hidden)
            .task(id: RowScrollTarget(
                id: editingID ?? expandedID,
                availableHeight: listHeight,
                contentHeight: regionHeights[.content] ?? 0,
                editingError: editingError,
                isPresented: presentation.isPresented
            )) {
                guard let target = editingID ?? expandedID else { return }
                await Task.yield()
                guard !Task.isCancelled, presentation.isPresented else { return }
                withAnimation(motion) { proxy.scrollTo(target, anchor: .bottom) }
            }
        }
        .animation(motion, value: visibleItems)
        .animation(iconMotion, value: expandedID)
        .animation(motion, value: editingID)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(emptyTitle)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondary)
            if !emptyDetail.isEmpty {
                Text(emptyDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyTitle: String {
        if page == .all && !search.isEmpty { return "未找到匹配事项" }
        if page == .later { return "暂无延后事项" }
        if page == .all && historyFilter == .completed { return "暂无完成记录" }
        if store.items.isEmpty { return "暂无待办" }
        if workspaceScope.project != .all { return "当前范围没有事项" }
        if page == .all { return "暂无事项" }
        return "暂无待办"
    }

    private var emptyDetail: String {
        if page == .all && !search.isEmpty { return "试试其他关键词。" }
        if page == .later { return "" }
        if page == .all && historyFilter == .completed { return "" }
        if store.items.isEmpty { return "输入内容，回车添加" }
        if !store.deferredItems.isEmpty { return "另有 \(store.deferredItems.count) 项已安排在稍后。" }
        return ""
    }

    private var hasNotices: Bool {
        interactionMessage != nil || preferences.shortcutError != nil || preferences.loginError != nil || preferences.loginNeedsApproval || (panelMode == .tasks && store.errorMessage != nil)
    }

    private var noticeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = interactionMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil.circle").foregroundStyle(theme.accent)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { interactionMessage = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭编辑提示")
                }
                .padding(8)
                .background(theme.subtle, in: RoundedRectangle(cornerRadius: 8))
            }
            if preferences.shortcutError != nil || preferences.loginError != nil || preferences.loginNeedsApproval {
                VStack(alignment: .leading, spacing: 5) {
                    if let error = preferences.shortcutError {
                        Text(error).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let error = preferences.loginError {
                        Text(error).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if preferences.loginNeedsApproval {
                        Button("登录项等待批准 · 打开系统设置", action: preferences.openLoginSettings)
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accentText)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if panelMode == .tasks, let error = store.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !store.isReadOnly {
                        Button { store.clearError() } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭提示")
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if hasNotices {
                ScrollView {
                    noticeContent
                        .fixedSize(horizontal: false, vertical: true)
                        .measurePanelHeight(.notices)
                }
                .frame(height: min(110, regionHeights[.notices] ?? 50))
            }

            Rectangle().fill(theme.line).frame(height: 1)
            HStack(spacing: 6) {
                if let label = store.lastChangeLabel {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                    Text(label)
                        .lineLimit(1)
                        .help(label)
                    Spacer(minLength: 4)
                    if store.canUndo {
                        Button {
                            withAnimation(motion) { store.undoLastChange() }
                        } label: {
                            Label("撤销", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accentText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(theme.subtle, in: Capsule())
                        }
                        .buttonStyle(QingPressStyle())
                        .fixedSize()
                        .disabled(store.isReadOnly || editingID != nil)
                    }
                } else {
                    Text("本地保存")
                    Spacer()
                    if preferences.shortcut != .disabled {
                        Text(preferences.shortcut.displayLabel)
                            .help("快速添加")
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.secondary)
            .frame(height: 32)
            .padding(.horizontal, 14)
        }
        .background(theme.canvas.opacity(0.92))
    }

    private func scheduler(for item: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(theme.later)
                    .frame(width: 32, height: 32)
                    .background(theme.subtle, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义延后")
                        .font(.system(size: 15, weight: .semibold))
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(2)
                        .help(item.title)
                }
                Spacer(minLength: 0)
                Button(action: closeScheduler) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 26, height: 26)
                        .background(theme.subtle, in: Circle())
                }
                .buttonStyle(QingPressStyle())
                .accessibilityLabel("取消延后")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("自定义时间")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondary)
                HStack {
                    Text("日期").foregroundStyle(theme.secondary)
                    Spacer()
                    DatePicker("延后日期", selection: $scheduledDate, in: Date()..., displayedComponents: .date)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                }
                HStack {
                    Text("时间").foregroundStyle(theme.secondary)
                    Spacer()
                    DatePicker("延后时间", selection: $scheduledDate, in: Date()..., displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.canvas, in: RoundedRectangle(cornerRadius: 10))

            if let error = store.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(error)
            }

            Button {
                postpone(item, to: scheduledDate)
            } label: {
                HStack(spacing: 7) {
                    Text("确认延后")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(theme.action, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(QingPressStyle())
            .disabled(scheduledDate <= Date() || store.isReadOnly)

            Text("到时间自动返回「现在」。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 24, x: 0, y: 8)
    }

    private func count(for candidate: TaskPage) -> Int {
        switch candidate {
        case .now: store.activeItems.filter { workspaceScope.includes($0) }.count
        case .later: store.deferredItems.filter { workspaceScope.includes($0) }.count
        case .all: store.items.filter { workspaceScope.includes($0) }.count
        case .tags: store.allTags.count
        }
    }

    private func addTask() {
        guard !store.isReadOnly, editingID == nil else { return }
        let tag = composerTag
        withAnimation(motion) {
            if store.add(draft, tag: tag, projectId: workspaceScope.projectId, regionId: workspaceScope.regionId) {
                draft = ""
                search = ""
                if let tag {
                    selectedTag = tag
                    page = .tags
                } else {
                    page = .now
                }
            }
        }
        composerFocused = true
    }

    private func changeCompletion(_ item: TodoItem) {
        guard editingID == nil else { return }
        expandedID = nil
        withAnimation(motion) {
            if item.isCompleted { store.restore(item.id) }
            else { store.complete(item.id) }
        }
    }

    private func openScheduler(_ item: TodoItem) {
        guard !store.isReadOnly, !item.isCompleted, editingID == nil else { return }
        composerFocused = false
        expandedID = nil
        scheduledDate = item.deferredUntil.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(3600)
        schedulingItem = item
    }

    private func closeScheduler() {
        schedulingItem = nil
    }

    private func postpone(_ item: TodoItem, to date: Date) {
        guard date > Date(), !store.isReadOnly else { return }
        withAnimation(motion) {
            if store.postpone(item.id, until: date) {
                schedulingItem = nil
                expandedID = nil
            }
        }
    }

    private func selectPage(_ candidate: TaskPage, filter: HistoryFilter? = nil) {
        guard editingID == nil else {
            interactionMessage = "请先保存或取消当前编辑，再切换列表。"
            return
        }
        panelMode = .tasks
        page = candidate
        if let filter { historyFilter = filter }
        expandedID = nil
    }

    private func toggleQuickActions(_ item: TodoItem) {
        guard !store.isReadOnly, !item.isCompleted, editingID == nil else { return }
        composerFocused = false
        withAnimation(iconMotion) { expandedID = expandedID == item.id ? nil : item.id }
    }

    private func beginEditing(_ item: TodoItem) {
        guard !store.isReadOnly else { return }
        if let editingID, editingID != item.id {
            interactionMessage = "请先保存或取消当前编辑，再编辑另一条。"
            return
        }
        guard editingID == nil else { return }
        composerFocused = false
        expandedID = nil
        editingDraft = item.title
        editingError = nil
        editingID = item.id
    }

    private func openDetails(_ item: TodoItem) {
        guard editingID == nil else {
            interactionMessage = "请先保存或取消当前编辑，再打开详情。"
            return
        }
        presentation.requestItem(item.id)
    }

    @discardableResult
    private func openPendingItemIfPossible() -> Bool {
        guard presentation.isPresented,
              let id = presentation.takeRequestedItem(),
              store.items.contains(where: { $0.id == id }) else { return false }
        composerFocused = false
        panelMode = .tasks
        schedulingItem = nil
        expandedID = nil
        detailsAreDirty = false
        withAnimation(motion) { detailsID = id }
        return true
    }

    private func closeDetails() {
        detailsAreDirty = false
        withAnimation(motion) { detailsID = nil }
    }

    private func saveEditing() {
        guard let id = editingID else { return }
        guard !editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            editingError = "内容不能为空。"
            return
        }
        if store.rename(id, to: editingDraft) {
            cancelEditing()
        } else {
            editingError = store.errorMessage ?? "未能保存，请保留内容后重试。"
        }
    }

    private func cancelEditing() {
        editingID = nil
        editingDraft = ""
        editingError = nil
        interactionMessage = nil
    }

    private func requestComposerFocus() {
        focusTask?.cancel()
        schedulingItem = nil
        expandedID = nil
        detailsID = nil
        detailsAreDirty = false
        panelMode = .tasks
        guard editingID == nil else {
            interactionMessage = "当前编辑尚未结束；保存或取消后即可添加新事项。"
            return
        }
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, presentation.isPresented else { return }
            composerFocused = true
        }
    }

    private func reportHeight(_ height: CGFloat) {
        heightTask?.cancel()
        heightTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            onHeightChange(height)
        }
    }

    private func handleEscape() {
        guard panelMode != .ledger else { return }
        if detailsID != nil {
            if !detailsAreDirty { closeDetails() }
        }
        else if schedulingItem != nil { closeScheduler() }
        else if editingID != nil { cancelEditing() }
        else if expandedID != nil { expandedID = nil }
        else { onClose() }
    }
}

private enum RowDragAxis {
    case horizontal
    case delete
    case ignored
}

private struct TodoRow: View {
    let item: TodoItem
    let assignmentLabel: String
    let now: Date
    let isReadOnly: Bool
    let isPresented: Bool
    let isEditing: Bool
    let isAnotherItemEditing: Bool
    @Binding var editingDraft: String
    let editingError: String?
    let quickActionsExpanded: Bool
    let draggingID: UUID?
    let canShowDrop: Bool
    let dropAfter: Bool
    let onComplete: () -> Void
    let onPostpone: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onDetails: () -> Void
    let onTogglePin: () -> Void
    let onReorder: (UUID) -> Void
    let onDragStateChange: (Bool) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onSelect: () -> Void
    let onPreset: (PostponePreset) -> Void
    let onCustom: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var editorFocused: Bool
    @NativeState private var swipeOffset: CGFloat = 0
    @NativeState private var verticalOffset: CGFloat = 0
    @NativeState private var isHovered = false
    @NativeState private var dragAxis: RowDragAxis?
    @NativeState private var isDropTarget = false
    @NativeState private var deleteArmed = false
    @NativeState private var isDeleting = false
    @NativeState private var handlePressed = false
    @NativeState private var snapshotReference = ReorderSnapshotReference()

    private let actionThreshold: CGFloat = 72
    private let deleteThreshold: CGFloat = 86
    private var theme: QingTheme { QingTheme(scheme: colorScheme) }
    private var deferred: Bool { item.isDeferred(at: now) }
    private var canAct: Bool { !isReadOnly && !isEditing && !isAnotherItemEditing && isPresented }
    private var isDragging: Bool { draggingID == item.id }
    private var deleteProgress: CGFloat { min(1, verticalOffset / deleteThreshold) }
    private var deleteCardOffset: CGFloat { isDeleting ? 64 : min(26, verticalOffset * 0.30) }
    private var deleteCardScale: CGFloat { isDeleting ? 0.97 : 1 - deleteProgress * 0.015 }
    private var deleteContentOpacity: Double { isDeleting ? 0 : 1 - Double(deleteProgress) * 0.22 }

    var body: some View {
        VStack(spacing: 0) {
            swipeableContent
                .opacity(isDragging ? 0.22 : 1)
            if quickActionsExpanded && !isEditing {
                quickActions
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isDragging ? theme.subtle : theme.surface)
        .background { ReorderSnapshotAnchor(reference: snapshotReference) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDragging || (isDropTarget && canShowDrop) ? theme.accent.opacity(0.42)
                        : isEditing || isHovered ? theme.accent.opacity(0.40) : theme.line,
                    style: StrokeStyle(lineWidth: 1, dash: isDragging ? [4, 4] : [])
                )
        }
        .overlay(alignment: dropAfter ? .bottom : .top) {
            if isDropTarget && canShowDrop {
                HStack(spacing: 0) {
                    Circle().frame(width: 4, height: 4)
                    Rectangle().frame(height: 2)
                    Circle().frame(width: 4, height: 4)
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 5)
                .offset(y: dropAfter ? 3 : -3)
                .accessibilityHidden(true)
            }
        }
        .onDrop(of: [UTType.plainText], isTargeted: $isDropTarget, perform: acceptDrop)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDropTarget)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDragging)
        .contextMenu {
            Button("查看详情", systemImage: "info.circle", action: onDetails)
                .disabled(isAnotherItemEditing)
            Button("编辑内容", systemImage: "pencil", action: onEdit)
                .disabled(isReadOnly || isAnotherItemEditing)
            Button(item.isPinned ? "取消星标" : "星标置顶", systemImage: item.isPinned ? "star.slash" : "star", action: onTogglePin)
                .disabled(!canAct)
            Button(item.isCompleted ? "恢复到现在" : "标记完成", systemImage: item.isCompleted ? "arrow.uturn.backward" : "checkmark", action: onComplete)
                .disabled(!canAct)
            if !item.isCompleted {
                Button("延后…", systemImage: "clock", action: onPostpone)
                    .disabled(!canAct)
                if deferred {
                    Button("现在就做", systemImage: "sun.max", action: onResume)
                        .disabled(!canAct)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "编辑内容") {
            if !isReadOnly && !isAnotherItemEditing { onEdit() }
        }
        .accessibilityAction(named: item.isCompleted ? "恢复到现在" : "标记完成") {
            if canAct { onComplete() }
        }
        .accessibilityAction(named: "延后") {
            if canAct && !item.isCompleted { onPostpone() }
        }
        .accessibilityAction(named: "删除") {
            if canAct { onDelete() }
        }
        .onChange(of: isPresented) { _, visible in
            if !visible {
                swipeOffset = 0
                verticalOffset = 0
                dragAxis = nil
                deleteArmed = false
                isDeleting = false
                isHovered = false
                editorFocused = false
            }
        }
        .onChange(of: isEditing) { _, _ in
            swipeOffset = 0
            verticalOffset = 0
            dragAxis = nil
            deleteArmed = false
            isDeleting = false
        }
        .task(id: isPresented && isEditing) {
            guard isPresented && isEditing else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            editorFocused = true
        }
    }

    private var swipeableContent: some View {
        ZStack {
            swipeBackground
            if isEditing {
                editor
            } else {
                rowContent
                    .offset(x: swipeOffset, y: deleteCardOffset)
                    .scaleEffect(deleteCardScale)
                    .opacity(deleteContentOpacity)
                if verticalOffset > 0 {
                    deleteCue
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .background {
            if canAct {
                TrackpadSwipeBridge(onChange: updateSwipe, onEnd: endSwipe)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    guard canAct, !handlePressed else { return }
                    if dragAxis == nil {
                        let horizontal = abs(value.translation.width)
                        let vertical = abs(value.translation.height)
                        guard max(horizontal, vertical) >= 14 else { return }
                        if horizontal > vertical * 1.65 {
                            dragAxis = .horizontal
                        } else if vertical > horizontal * 1.65 {
                            dragAxis = value.translation.height > 0 ? .delete : .ignored
                        } else if max(horizontal, vertical) >= 24 {
                            dragAxis = .ignored
                        } else {
                            return
                        }
                    }
                    if dragAxis == .horizontal {
                        updateSwipe(value.translation.width)
                    } else if dragAxis == .delete {
                        swipeOffset = 0
                        let distance = max(0, min(120, value.translation.height))
                        verticalOffset = distance
                        let ready = distance >= deleteThreshold
                        if ready, !deleteArmed {
                            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                        }
                        deleteArmed = ready
                    }
                }
                .onEnded { value in
                    guard !handlePressed else {
                        dragAxis = nil
                        return
                    }
                    if dragAxis == .horizontal {
                        endSwipe(value.translation.width)
                    } else if dragAxis == .delete {
                        endVerticalSwipe(value.translation.height)
                    }
                    dragAxis = nil
                },
            including: canAct ? .all : .none
        )
        .onHover { hovered in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { isHovered = hovered }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("待办内容", text: $editingDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($editorFocused)
                .onSubmit(onSave)
                .onExitCommand(perform: onCancel)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(theme.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(editorFocused ? theme.accent : theme.line, lineWidth: 1)
                }
                .accessibilityLabel("编辑待办内容")
                .disabled(isReadOnly)

            HStack(spacing: 8) {
                Text("Enter 保存 · Esc 取消")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondary)
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .foregroundStyle(theme.secondary)
                Button("保存", action: onSave)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accentText)
                    .disabled(isReadOnly || editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)

            if let editingError {
                Text(editingError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(editingError)
            }
        }
        .padding(9)
        .background(theme.surface)
    }

    private var quickActions: some View {
        HStack(spacing: 5) {
            ForEach([PostponePreset.thirtyMinutes, .oneHour, .tomorrowMorning], id: \.self) { preset in
                Button { onPreset(preset) } label: {
                    Text(preset.title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 27)
                        .background(theme.subtle, in: RoundedRectangle(cornerRadius: 6))
                }
                .help("延后到 \(preset.date(from: Date()).formatted(.dateTime.month().day().hour().minute()))")
            }
            Button(action: onCustom) {
                Text("自定义")
                    .font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 27)
                    .background(theme.subtle, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .foregroundStyle(theme.accentText)
        .buttonStyle(QingPressStyle())
        .disabled(!canAct)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 7) {
            Button(action: onComplete) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(item.isCompleted ? theme.accent : Color.clear)
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(item.isCompleted ? Color.clear : theme.secondary.opacity(0.65), lineWidth: 1.2)
                    if item.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.accentInk)
                    }
                }
                .frame(width: 17, height: 17)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(QingPressStyle())
            .disabled(!canAct)
            .accessibilityLabel(item.isCompleted ? "恢复：\(item.title)" : "完成：\(item.title)")
            .help(item.isCompleted ? "恢复到现在" : "标记完成")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.isCompleted ? theme.secondary : theme.primary)
                    .strikethrough(item.isCompleted, color: theme.secondary.opacity(0.55))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if !isReadOnly && !isAnotherItemEditing { onEdit() }
                    }
                    .help("\(item.title)\n双击编辑内容")
                    .accessibilityHint("双击或使用编辑内容操作修改")

                if item.projectId != nil {
                    Text(assignmentLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .help(assignmentLabel)
                }

                if item.isCompleted, let date = item.completedAt {
                    Label("已完成 · \(timeDescription(date))", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                } else if deferred, let date = item.deferredUntil {
                    Label(timeDescription(date), systemImage: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.later)
                } else if !item.tags.isEmpty {
                    Text(item.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            if item.isPinned || isHovered {
                Button(action: onTogglePin) {
                    Image(systemName: item.isPinned ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(item.isPinned ? theme.accent : theme.secondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QingPressStyle())
                .disabled(!canAct)
                .help(item.isPinned ? "取消星标" : "星标置顶")
            }
            if !item.isCompleted {
                Button(action: onPostpone) {
                    Image(systemName: quickActionsExpanded ? "chevron.up" : "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(deferred ? theme.later : theme.secondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: 28, height: 30)
                        .background(isHovered ? theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(QingPressStyle())
                .disabled(!canAct)
                .help("选择延后时间")
                .accessibilityLabel("延后：\(item.title)")
            }

            ZStack {
                Text("详情")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.accentText)
                    .scaleEffect(handlePressed ? 0.92 : 1)
                    .accessibilityHidden(true)
                ReorderDragSource(
                    itemID: item.id,
                    title: item.title,
                    isEnabled: canAct,
                    canDrag: canAct && !item.isCompleted,
                    snapshotReference: snapshotReference,
                    onPressChange: { pressed in
                        handlePressed = pressed
                        if pressed {
                            swipeOffset = 0
                            verticalOffset = 0
                            deleteArmed = false
                            dragAxis = nil
                        }
                    },
                    onDragStateChange: onDragStateChange,
                    onClick: onDetails
                )
            }
            .frame(width: 28, height: 30)
            .background(isHovered || handlePressed ? theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
            .help(item.isCompleted ? "打开详情" : "打开详情；按住拖动排序")
            .accessibilityLabel("打开详情：\(item.title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(isHovered ? theme.hoverSurface : theme.surface)
    }

    private var swipeBackground: some View {
        ZStack {
            HStack {
            VStack(spacing: 4) {
                Image(systemName: item.isCompleted ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                Text(item.isCompleted ? "恢复" : "完成")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(theme.accentInk)
            .scaleEffect(reduceMotion ? 1 : abs(swipeOffset) >= actionThreshold ? 1.08 : 0.88)
            Spacer()
            if !item.isCompleted {
                VStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 17, weight: .semibold))
                    Text("延后").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .scaleEffect(reduceMotion ? 1 : abs(swipeOffset) >= actionThreshold ? 1.08 : 0.88)
            }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(verticalOffset > 0 ? theme.surface : (swipeOffset >= 0 ? theme.action : theme.later))

        }
        .onTapGesture(perform: onSelect)
        .accessibilityHidden(true)
    }

    private var deleteCue: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.04 + 0.08 * deleteProgress))
            Label(deleteArmed ? "松开删除" : "继续下拉", systemImage: deleteArmed ? "trash.fill" : "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(deleteArmed ? 0.92 : 0.78), in: Capsule())
                .scaleEffect(0.88 + 0.12 * deleteProgress)
                .opacity(min(1, Double(deleteProgress) * 1.8))
                .shadow(color: Color.red.opacity(0.22), radius: 8, y: 3)
                .padding(.top, 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func updateSwipe(_ distance: CGFloat) {
        guard canAct else { return }
        guard !item.isCompleted || distance >= 0 else { return }
        swipeOffset = max(-112, min(112, distance))
    }

    private func endSwipe(_ distance: CGFloat) {
        let shouldComplete = canAct && distance >= actionThreshold
        let shouldPostpone = canAct && distance <= -actionThreshold && !item.isCompleted
        withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.82)) {
            swipeOffset = 0
            if shouldComplete { onComplete() }
            else if shouldPostpone { onPostpone() }
        }
    }

    private func endVerticalSwipe(_ distance: CGFloat) {
        let shouldDelete = canAct && deleteArmed && distance >= deleteThreshold
        deleteArmed = false
        guard shouldDelete else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.86)) {
                verticalOffset = 0
            }
            return
        }
        guard !reduceMotion else {
            verticalOffset = 0
            onDelete()
            return
        }
        withAnimation(.easeIn(duration: 0.14)) {
            isDeleting = true
            verticalOffset = 120
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            onDelete()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isDeleting = false
                verticalOffset = 0
            }
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAct, let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { onReorder(id) }
        }
        return true
    }

    private func timeDescription(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        return date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }
}

private final class ReorderSnapshotReference {
    weak var view: NSView?
}

private struct ReorderSnapshotAnchor: NSViewRepresentable {
    let reference: ReorderSnapshotReference

    func makeNSView(context: Context) -> ReorderSnapshotView {
        let view = ReorderSnapshotView()
        reference.view = view
        return view
    }

    func updateNSView(_ nsView: ReorderSnapshotView, context: Context) {
        reference.view = nsView
    }
}

private final class ReorderSnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ReorderDragSource: NSViewRepresentable {
    let itemID: UUID
    let title: String
    let isEnabled: Bool
    let canDrag: Bool
    let snapshotReference: ReorderSnapshotReference
    let onPressChange: (Bool) -> Void
    let onDragStateChange: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> ReorderDragSourceView {
        let view = ReorderDragSourceView()
        view.configure(
            itemID: itemID,
            title: title,
            isEnabled: isEnabled,
            canDrag: canDrag,
            snapshotReference: snapshotReference,
            onPressChange: onPressChange,
            onDragStateChange: onDragStateChange,
            onClick: onClick
        )
        return view
    }

    func updateNSView(_ nsView: ReorderDragSourceView, context: Context) {
        nsView.configure(
            itemID: itemID,
            title: title,
            isEnabled: isEnabled,
            canDrag: canDrag,
            snapshotReference: snapshotReference,
            onPressChange: onPressChange,
            onDragStateChange: onDragStateChange,
            onClick: onClick
        )
    }
}

private final class ReorderDragSourceView: NSView, NSDraggingSource {
    private var itemID: UUID?
    private var title = ""
    private var snapshotReference: ReorderSnapshotReference?
    private var action: (() -> Void)?
    private var pressAction: ((Bool) -> Void)?
    private var dragStateAction: ((Bool) -> Void)?
    private var downPoint: NSPoint?
    private var downTime: TimeInterval?
    private var startedDrag = false
    private var interactionEnabled = true
    private var draggingAllowed = true

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(
        itemID: UUID,
        title: String,
        isEnabled: Bool,
        canDrag: Bool,
        snapshotReference: ReorderSnapshotReference,
        onPressChange: @escaping (Bool) -> Void,
        onDragStateChange: @escaping (Bool) -> Void,
        onClick: @escaping () -> Void
    ) {
        self.itemID = itemID
        self.title = title
        interactionEnabled = isEnabled
        draggingAllowed = canDrag
        self.snapshotReference = snapshotReference
        pressAction = onPressChange
        dragStateAction = onDragStateChange
        action = onClick
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(canDrag ? "打开详情；拖动排序" : "打开详情")
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        downPoint = convert(event.locationInWindow, from: nil)
        downTime = event.timestamp
        startedDrag = false
        pressAction?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionEnabled, draggingAllowed, !startedDrag,
              let itemID, let downPoint, let downTime else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 5 else { return }
        guard event.timestamp - downTime >= 0.12 else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(itemID.uuidString, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let (cardImage, cardFrame) = captureCardPreview() ?? fallbackCardPreview()
        draggingItem.setDraggingFrame(cardFrame, contents: cardImage)

        startedDrag = true
        dragStateAction?(true)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let distance = downPoint.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .infinity
        let shouldActivate = interactionEnabled
            && !startedDrag
            && distance < 4
            && bounds.insetBy(dx: -4, dy: -4).contains(point)
        let clickAction = action
        let endPress = pressAction
        defer {
            downPoint = nil
            downTime = nil
            startedDrag = false
        }
        DispatchQueue.main.async {
            endPress?(false)
            if shouldActivate { clickAction?() }
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        interactionEnabled ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        downPoint = nil
        downTime = nil
        startedDrag = false
        let endPress = pressAction
        let endDrag = dragStateAction
        DispatchQueue.main.async {
            endDrag?(false)
            endPress?(false)
        }
    }

    private func captureCardPreview() -> (NSImage, NSRect)? {
        guard let anchor = snapshotReference?.view,
              let window,
              anchor.window === window,
              let contentView = window.contentView else { return nil }
        let contentRect = anchor.convert(anchor.bounds, to: contentView)
        guard contentRect.width > 0, contentRect.height > 0,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentRect) else { return nil }
        contentView.cacheDisplay(in: contentRect, to: bitmap)
        let image = NSImage(size: contentRect.size)
        image.addRepresentation(bitmap)
        return (image, convert(anchor.bounds, from: anchor))
    }

    private func fallbackCardPreview() -> (NSImage, NSRect) {
        let size = NSSize(width: 312, height: 48)
        let title = self.title
        let image = NSImage(size: size, flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            NSColor.controlBackgroundColor.setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
            card.stroke()
            let checkbox = NSBezierPath(roundedRect: NSRect(x: 14, y: 15, width: 17, height: 17), xRadius: 5, yRadius: 5)
            checkbox.stroke()
            (title as NSString).draw(in: NSRect(x: 48, y: 13, width: rect.width - 65, height: 25), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
            return true
        }
        let frame = NSRect(x: bounds.maxX - size.width + 8, y: (bounds.height - size.height) / 2,
                           width: size.width, height: size.height)
        return (image, frame)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: draggingAllowed ? .openHand : interactionEnabled ? .pointingHand : .arrow)
    }

    override func accessibilityPerformPress() -> Bool {
        guard interactionEnabled else { return false }
        action?()
        return true
    }
}
