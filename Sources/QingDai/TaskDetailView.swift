import AppKit
import SwiftUI

private typealias DetailState<Value> = SwiftUI.State<Value>

struct TaskDetailView: View {
    @ObservedObject var store: TaskStore
    let item: TodoItem
    let onDirtyChange: (Bool) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var notesFocused: Bool
    @FocusState private var linksFocused: Bool
    @FocusState private var tagSearchFocused: Bool
    @DetailState private var draft: TaskDetailsDraft
    @DetailState private var tagPickerExpanded = false
    @DetailState private var tagQuery = ""
    @DetailState private var tagError: String?
    @DetailState private var showsDiscardConfirmation = false
    @DetailState private var saveError: String?
    private let originalDraft: TaskDetailsDraft

    private var theme: QingTheme { QingTheme(scheme: colorScheme) }
    private var isDirty: Bool { draft != originalDraft }
    private var tagAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.88)
    }

    init(
        store: TaskStore,
        item: TodoItem,
        onDirtyChange: @escaping (Bool) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.item = item
        self.onDirtyChange = onDirtyChange
        self.onClose = onClose
        let initial = TaskDetailsDraft(item: item)
        originalDraft = initial
        _draft = DetailState(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.line).frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("内容")
                        contentCard
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("项目与地区")
                        TaskAssignmentFields(store: store, projectId: $draft.projectId,
                                             regionId: $draft.regionId, updateId: $draft.updateId)
                            .padding(10)
                            .detailCard(theme)
                        if draft.updateId != nil {
                            Text("完成后需登记更新状态")
                                .font(.system(size: 10)).foregroundStyle(theme.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("整理")
                        organizationCard
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("时间")
                        scheduleCard
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .background(theme.canvas)

            footer
        }
        .frame(width: 340, height: 373)
        .background(theme.surface)
        .foregroundStyle(theme.primary)
        .tint(theme.accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: draft.reminderEnabled)
        .onAppear { onDirtyChange(isDirty) }
        .onChange(of: isDirty) { _, dirty in onDirtyChange(dirty) }
        .onChange(of: draft) { _, _ in saveError = nil }
        .alert("放弃未保存的修改？", isPresented: $showsDiscardConfirmation) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { onClose() }
        } message: {
            Text("标题、备注、标签或时间设置还没有保存。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("事项详情")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            Button(action: requestClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 26, height: 26)
                    .background(theme.subtle, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(QingPressStyle())
            .accessibilityLabel("返回待办列表")
            .help("返回待办列表")
        }
        .padding(.horizontal, 14)
        .frame(height: 47)
        .background(theme.surface)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondary)
            .padding(.leading, 2)
    }

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                    .frame(width: 18)
                TextField("待办标题", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityLabel("待办标题")
            }
            .frame(minHeight: 35)

            fieldDivider

            ZStack(alignment: .topLeading) {
                if draft.notes.isEmpty && !notesFocused {
                    Text("添加备注…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondary.opacity(0.65))
                        .padding(.leading, 5)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.notes)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(height: 44)
                    .focused($notesFocused)
                    .accessibilityLabel("备注")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .detailCard(theme)
    }

    private var organizationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            tagPicker

            fieldDivider

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                    .frame(width: 18)
                    .padding(.top, 7)
                ZStack(alignment: .topLeading) {
                    if draft.linksText.isEmpty && !linksFocused {
                        Text("网页或本地文件链接，每行一个")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondary.opacity(0.65))
                            .padding(.leading, 5)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft.linksText)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(height: 34)
                        .focused($linksFocused)
                        .accessibilityLabel("链接")
                }
            }
            .padding(.top, 5)

            if !validLinks.isEmpty {
                fieldDivider
                ForEach(Array(validLinks.enumerated()), id: \.offset) { entry in
                    Button {
                        NSWorkspace.shared.open(entry.element)
                    } label: {
                        Label(linkTitle(entry.element), systemImage: entry.element.isFileURL ? "doc" : "arrow.up.right")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accentText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(QingPressStyle())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .detailCard(theme)
    }

    private var tagPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(tagAnimation) {
                    tagPickerExpanded.toggle()
                    if !tagPickerExpanded {
                        tagQuery = ""
                        tagError = nil
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accent)
                        .frame(width: 18)
                    Text("标签")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.primary)
                    Spacer(minLength: 2)

                    if selectedTags.isEmpty {
                        Text("未选择")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondary)
                    } else {
                        ForEach(Array(selectedTags.prefix(2)), id: \.self) { tag in
                            Text(shortTagLabel(tag))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.accentText)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(theme.subtle, in: Capsule())
                        }
                        if selectedTags.count > 2 {
                            Text("+\(selectedTags.count - 2)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.secondary)
                        }
                    }

                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .rotationEffect(.degrees(tagPickerExpanded ? 45 : 0))
                        .frame(width: 26, height: 26)
                        .background(theme.subtle, in: RoundedRectangle(cornerRadius: 7))
                }
                .frame(height: 35)
                .contentShape(Rectangle())
            }
            .buttonStyle(QingPressStyle())
            .accessibilityLabel("标签，\(selectedTags.isEmpty ? "未选择" : selectedTags.joined(separator: "、"))，\(tagPickerExpanded ? "收起" : "展开")")
            .help(tagPickerExpanded ? "收起标签选择" : "选择或新建标签")

            if tagPickerExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondary)
                        TextField("搜索或新建标签", text: $tagQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .focused($tagSearchFocused)
                            .onSubmit(submitTagQuery)
                            .onExitCommand {
                                withAnimation(tagAnimation) {
                                    tagPickerExpanded = false
                                    tagQuery = ""
                                    tagError = nil
                                }
                            }
                            .accessibilityLabel("搜索或新建标签")
                        if !tagQuery.isEmpty {
                            Button {
                                tagQuery = ""
                                tagError = nil
                                tagSearchFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.secondary)
                            }
                            .buttonStyle(QingPressStyle())
                            .accessibilityLabel("清空标签搜索")
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(tagSearchFocused ? theme.accent.opacity(0.5) : theme.line)
                    }

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(matchingTags, id: \.self) { tag in
                                tagOption(tag)
                            }
                            if matchingTags.isEmpty && !canCreateQueriedTag {
                                Text(tagQuery.isEmpty ? "还没有标签，输入名称即可创建" : "没有匹配的标签")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: 28)
                                    .padding(.horizontal, 7)
                            }
                            if canCreateQueriedTag {
                                Button {
                                    withAnimation(tagAnimation) { _ = addNewTag() }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 12))
                                        Text("创建并选中 #\(normalizedTagQuery)")
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(theme.accentText)
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .background(theme.subtle, in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(QingPressStyle())
                                .accessibilityLabel("创建并选中标签 \(normalizedTagQuery)")
                            }
                        }
                    }
                    .frame(height: min(CGFloat(max(1, matchingTags.count + (canCreateQueriedTag ? 1 : 0))) * 32, 144))
                    .scrollIndicators(.hidden)

                    if let tagError {
                        Text(tagError)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("标签错误：\(tagError)")
                    } else if selectedTags.count == 10 {
                        Text("最多选择 10 个标签")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondary)
                    }
                }
                .padding(.top, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 4)
        .onChange(of: tagPickerExpanded) { _, expanded in
            if expanded {
                Task { @MainActor in
                    await Task.yield()
                    if tagPickerExpanded { tagSearchFocused = true }
                }
            } else {
                tagSearchFocused = false
            }
        }
        .onChange(of: tagQuery) { _, _ in tagError = nil }
    }

    private func tagOption(_ tag: String) -> some View {
        let selected = selectedTags.contains(tag)
        return Button {
            withAnimation(tagAnimation) { toggleTag(tag) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? theme.accent : theme.secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                Text(tag)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.accentText : theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? theme.subtle : theme.canvas, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(QingPressStyle())
        .disabled(!selected && selectedTags.count >= 10)
        .accessibilityLabel("\(tag)，\(selected ? "已选择，点击移除" : "点击选择")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(tag)
    }

    private var selectedTags: [String] {
        var seen = Set<String>()
        return draft.tagsText
            .split(whereSeparator: { ",，\n".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var availableTags: [String] {
        let saved = store.allTags
        let savedSet = Set(saved)
        return saved + selectedTags.filter { !savedSet.contains($0) }
    }

    private var normalizedTagQuery: String {
        tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingTags: [String] {
        let query = normalizedTagQuery
        guard !query.isEmpty else { return availableTags }
        return availableTags.filter { $0.localizedStandardContains(query) }
    }

    private var exactMatchingTag: String? {
        let query = normalizedTagQuery
        guard !query.isEmpty else { return nil }
        return availableTags.first { $0.localizedStandardCompare(query) == .orderedSame }
    }

    private var canCreateQueriedTag: Bool {
        let query = normalizedTagQuery
        return !query.isEmpty && query.count <= 30
            && !query.contains(where: { ",，\n".contains($0) })
            && exactMatchingTag == nil && selectedTags.count < 10
    }

    private func shortTagLabel(_ tag: String) -> String {
        tag.count > 4 ? String(tag.prefix(4)) + "…" : tag
    }

    private func toggleTag(_ tag: String) {
        var tags = selectedTags
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            guard tags.count < 10 else {
                tagError = "每条事项最多选择 10 个标签。"
                return
            }
            tags.append(tag)
        }
        draft.tagsText = tags.joined(separator: "，")
        tagError = nil
    }

    private func submitTagQuery() {
        guard !normalizedTagQuery.isEmpty else { return }
        if let match = exactMatchingTag ?? (matchingTags.count == 1 ? matchingTags.first : nil) {
            if !selectedTags.contains(match) {
                guard selectedTags.count < 10 else {
                    tagError = "每条事项最多选择 10 个标签。"
                    return
                }
                withAnimation(tagAnimation) { toggleTag(match) }
            }
            tagQuery = ""
        } else if !matchingTags.isEmpty {
            tagError = "请选择一个匹配的标签，或点“创建并选中”。"
        } else {
            withAnimation(tagAnimation) { _ = addNewTag() }
        }
    }

    @discardableResult
    private func addNewTag() -> Bool {
        let tag = normalizedTagQuery
        guard !tag.isEmpty else { return false }
        guard tag.count <= 30 else {
            tagError = "每个标签最多 30 个字。"
            return false
        }
        guard !tag.contains(where: { ",，\n".contains($0) }) else {
            tagError = "标签名称不能包含逗号或换行。"
            return false
        }
        if let existing = exactMatchingTag {
            if !selectedTags.contains(existing) {
                guard selectedTags.count < 10 else {
                    tagError = "每条事项最多选择 10 个标签。"
                    return false
                }
                toggleTag(existing)
            }
            tagQuery = ""
            return true
        }
        guard selectedTags.count < 10 else {
            tagError = "每条事项最多选择 10 个标签。"
            return false
        }
        draft.tagsText = (selectedTags + [tag]).joined(separator: "，")
        tagQuery = ""
        tagError = nil
        return true
    }

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $draft.reminderEnabled) {
                Label("到时提醒", systemImage: "bell")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(minHeight: 35)

            if draft.reminderEnabled {
                fieldDivider
                HStack {
                    Text("提醒时间")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondary)
                    Spacer(minLength: 4)
                    DatePicker(
                        "提醒时间",
                        selection: $draft.reminderAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                .frame(minHeight: 35)
            }

            fieldDivider
            HStack {
                Label("重复", systemImage: "repeat")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Picker("重复", selection: $draft.repeatRule) {
                    ForEach(RepeatRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .frame(minHeight: 35)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .detailCard(theme)
    }

    private var fieldDivider: some View {
        Rectangle()
            .fill(theme.line)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(item.isCompleted ? "已完成" : "")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondary)
                Spacer()
                Button(action: requestClose) {
                    Text("取消")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondary)
                        .frame(height: 27)
                        .padding(.horizontal, 9)
                        .background(theme.subtle, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QingPressStyle())
                .keyboardShortcut(.cancelAction)

                Button(action: save) {
                    Text("保存")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accentInk)
                        .frame(height: 27)
                        .padding(.horizontal, 11)
                        .background(theme.action, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(QingPressStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            theme.canvas
                .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
        }
    }

    private var validLinks: [URL] {
        draft.linksText
            .split(whereSeparator: \.isNewline)
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { url in
                let scheme = url.scheme?.lowercased()
                let validWeb = (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
                let validFile = url.isFileURL && url.path.hasPrefix("/")
                return validWeb || validFile
            }
    }

    private func linkTitle(_ url: URL) -> String {
        if !url.lastPathComponent.isEmpty { return url.lastPathComponent }
        return url.host ?? url.absoluteString
    }

    private func save() {
        if store.update(item.id, draft: draft) {
            saveError = nil
            onDirtyChange(false)
            onClose()
        } else {
            saveError = store.errorMessage ?? "未能保存事项详情。"
        }
    }

    private func requestClose() {
        if isDirty {
            showsDiscardConfirmation = true
        } else {
            onClose()
        }
    }
}

private extension View {
    func detailCard(_ theme: QingTheme) -> some View {
        background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(theme.line) }
    }
}

typealias TaskDetailsView = TaskDetailView
