import SwiftUI

private typealias LedgerState<Value> = SwiftUI.State<Value>

private enum LedgerSection: String, CaseIterable {
    case regions = "按地区", updates = "按更新", projects = "项目管理"
}

private enum LedgerDestination {
    case project(UUID?)
    case region(UUID, UUID?)
    case update(UUID?)
    case detail(UUID)
    case progress(UUID, UUID)
}

@MainActor
struct UpdateLedgerView: View {
    @ObservedObject var store: TaskStore
    @Binding var scope: WorkspaceScope
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @LedgerState private var section: LedgerSection = .regions
    @LedgerState private var includesFinished = false
    @LedgerState private var includesArchived = false
    @LedgerState private var query = ""
    @LedgerState private var destination: LedgerDestination?

    private var theme: QingTheme { QingTheme(scheme: colorScheme) }
    private var scopedRegions: [ProjectRegion] {
        store.regions.filter {
            (includesArchived || store.isActive($0)) &&
            (scope.projectId == nil || $0.projectId == scope.projectId) &&
            (scope.regionId == nil || $0.id == scope.regionId)
        }
    }
    private func records(for update: ProjectUpdate) -> [RegionUpdate] {
        let ids = Set(scopedRegions.map(\.id))
        return update.regions.filter { ids.contains($0.regionId) }
    }
    private var pendingCount: Int {
        store.updates.reduce(0) { $0 + records(for: $1).filter { $0.status.isOutstanding }.count }
    }
    private var pendingRegionCount: Int {
        scopedRegions.filter { !store.outstandingUpdates(in: $0.id).isEmpty }.count
    }
    private func matches(_ values: String...) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || values.contains { $0.localizedStandardContains(text) }
    }

    var body: some View {
        Group {
            if let destination {
                destinationView(destination)
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func destinationView(_ destination: LedgerDestination) -> some View {
        switch destination {
        case .project(let id):
            ProjectEditor(store: store, projectId: id, onClose: closeDestination)
        case .region(let projectId, let id):
            RegionEditor(store: store, projectId: projectId, regionId: id, onClose: closeDestination)
        case .update(let id):
            UpdateEditor(store: store, updateId: id, defaultProjectId: scope.projectId, onClose: closeDestination)
        case .detail(let id):
            updateDetail(id)
        case .progress(let updateId, let regionId):
            RegionProgressEditor(store: store, updateId: updateId, regionId: regionId) {
                self.destination = .detail(updateId)
            }
        }
    }

    private var overview: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section == .projects ? "项目与地区" : "待更新 \(pendingCount) 项")
                        .font(.system(size: 13, weight: .semibold))
                    if section != .projects && pendingRegionCount > 0 {
                        Text("涉及 \(pendingRegionCount) 个地区")
                            .font(.system(size: 10)).foregroundStyle(theme.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    store.clearError()
                    destination = section == .projects ? .project(nil) : .update(nil)
                } label: {
                    Label(section == .projects ? "新增项目" : "登记更新", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.isReadOnly || (section != .projects && store.activeProjects.isEmpty))
            }
            WorkspaceScopePicker(store: store, scope: $scope, includesArchived: includesArchived)
            Picker("台账视图", selection: $section) {
                ForEach(LedgerSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField(section == .projects ? "搜索项目或地区" : "搜索地区或更新", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索项目、地区或更新")
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line) }
                Menu {
                    Toggle("显示已更新及不适用", isOn: $includesFinished)
                    Toggle("包含归档", isOn: $includesArchived)
                } label: {
                    Label(includesArchived || includesFinished ? "已筛选" : "筛选", systemImage: "line.3.horizontal.decrease")
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(includesArchived || includesFinished ? theme.subtle : theme.surface,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line) }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("筛选")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.secondary)
            if let error = store.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(theme.failureText)
                    .lineLimit(3).help(error).textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    switch section {
                    case .regions: regionOverview
                    case .updates: updateOverview
                    case .projects: projectManagement
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 14)
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private var regionOverview: some View {
        let regions = scopedRegions.filter { region in
            let updates = store.updates.filter { update in
                update.regions.contains { $0.regionId == region.id && (includesFinished || $0.status.isOutstanding) }
            }
            return (includesFinished || !updates.isEmpty) &&
                (matches(region.name, store.projectName(region.projectId)) || updates.contains { matches($0.title, $0.version, $0.notes) })
        }.sorted { store.outstandingUpdates(in: $0.id).count > store.outstandingUpdates(in: $1.id).count }
        if regions.isEmpty {
            emptyMessage(store.activeProjects.isEmpty ? "暂无项目" : scopedRegions.isEmpty ? "暂无地区" : "暂无待更新记录")
            if store.activeProjects.isEmpty {
                Button("新增项目", systemImage: "plus") { destination = .project(nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isReadOnly)
            } else if scopedRegions.isEmpty {
                Button("添加地区", systemImage: "plus") { section = .projects }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        ForEach(regions) { region in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(region.name).font(.system(size: 13, weight: .semibold))
                        Text(store.projectName(region.projectId) + (store.isActive(region) ? "" : " · 已归档"))
                            .font(.system(size: 10)).foregroundStyle(theme.secondary)
                    }
                    Spacer()
                    Text("\(store.outstandingUpdates(in: region.id).count) 项待更新")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
                }
                let updates = store.updates.filter { update in
                    update.regions.contains { $0.regionId == region.id && (includesFinished || $0.status.isOutstanding) }
                }.sorted { $0.createdAt > $1.createdAt }
                if updates.isEmpty { Text("暂无更新记录").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                ForEach(updates) { update in
                    if let record = update.regions.first(where: { $0.regionId == region.id }) {
                        Button { destination = .progress(update.id, region.id) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(update.title).font(.system(size: 12)).multilineTextAlignment(.leading)
                                    if !update.version.isEmpty {
                                        Text(update.version).font(.system(size: 10)).foregroundStyle(theme.secondary)
                                    }
                                }
                                Spacer(minLength: 2)
                                UpdateStatusBadge(status: record.status)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QingPressStyle())
                    }
                }
            }
            .ledgerSection(theme)
        }
    }

    @ViewBuilder
    private var updateOverview: some View {
        let updates = store.updates.filter {
            let scoped = records(for: $0)
            return !scoped.isEmpty && (includesFinished || scoped.contains { $0.status.isOutstanding }) &&
                matches($0.title, $0.version, $0.notes, store.projectName($0.projectId),
                        scoped.map { store.regionName($0.regionId) }.joined(separator: " "))
        }.sorted { $0.createdAt > $1.createdAt }
        if updates.isEmpty { emptyMessage("暂无更新") }
        ForEach(updates) { update in
            Button { destination = .detail(update.id) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Text(update.title).font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(theme.secondary)
                    }
                    Text([store.projectName(update.projectId), update.version].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(theme.secondary)
                    ForEach(records(for: update)) { record in
                        HStack {
                            Text(store.regionName(record.regionId)).font(.system(size: 12))
                            Spacer()
                            UpdateStatusBadge(status: record.status)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .ledgerSection(theme)
                .contentShape(Rectangle())
            }
            .buttonStyle(QingPressStyle())
        }
    }

    @ViewBuilder
    private var projectManagement: some View {
        let projects = store.projects.filter { project in
            (includesArchived || !project.isArchived) && (scope.projectId == nil || scope.projectId == project.id) &&
            (matches(project.name) || store.regions.contains { $0.projectId == project.id && matches($0.name) })
        }
        if projects.isEmpty { emptyMessage("暂无项目") }
        ForEach(projects) { project in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(project.name + (project.isArchived ? " · 已归档" : ""))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 2)
                    Button("编辑") { destination = .project(project.id) }
                        .font(.system(size: 11)).buttonStyle(.borderless).disabled(store.isReadOnly)
                    Menu {
                        Button("重命名") { destination = .project(project.id) }
                        Button("新增地区") { destination = .region(project.id, nil) }.disabled(project.isArchived)
                        Button("向上移动") { store.moveProject(project.id, by: -1) }
                            .disabled(store.projects.first?.id == project.id)
                        Button("向下移动") { store.moveProject(project.id, by: 1) }
                            .disabled(store.projects.last?.id == project.id)
                        Divider()
                        Button(project.isArchived ? "恢复项目" : "归档项目") {
                            store.setProjectArchived(project.id, archived: !project.isArchived)
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("管理项目 \(project.name)")
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(store.isReadOnly)
                }
                let regions = store.regions.filter { $0.projectId == project.id && (includesArchived || !$0.isArchived) }
                ForEach(regions) { region in
                    HStack {
                        Text(region.name + (region.isArchived ? " · 已归档" : ""))
                            .font(.system(size: 12))
                        Spacer(minLength: 2)
                        Button("编辑") { destination = .region(project.id, region.id) }
                            .font(.system(size: 11)).buttonStyle(.borderless).disabled(store.isReadOnly)
                        Menu {
                            Button("重命名") { destination = .region(project.id, region.id) }
                            Button("向上移动") { store.moveRegion(region.id, by: -1) }
                                .disabled(store.regions.filter { $0.projectId == project.id }.first?.id == region.id)
                            Button("向下移动") { store.moveRegion(region.id, by: 1) }
                                .disabled(store.regions.filter { $0.projectId == project.id }.last?.id == region.id)
                            Divider()
                            Button(region.isArchived ? "恢复地区" : "归档地区") {
                                store.setRegionArchived(region.id, archived: !region.isArchived)
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("管理地区 \(region.name)")
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(store.isReadOnly)
                    }
                }
                if !project.isArchived {
                    Button { destination = .region(project.id, nil) } label: {
                        Label("添加地区", systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isReadOnly)
                }
            }
            .ledgerSection(theme)
        }
    }

    @ViewBuilder
    private func updateDetail(_ id: UUID) -> some View {
        if let update = store.updates.first(where: { $0.id == id }) {
            VStack(spacing: 8) {
                HStack {
                    Button("返回", systemImage: "chevron.left", action: closeDestination)
                    Spacer()
                    Button("编辑更新") { destination = .update(id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.isReadOnly)
                }
                .font(.system(size: 12))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(update.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                        Text([store.projectName(update.projectId), update.version].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(theme.secondary)
                        Text("登记于 \(update.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(theme.secondary)
                        if !update.notes.isEmpty {
                            Text(update.notes).font(.system(size: 12)).textSelection(.enabled)
                        }
                        Text("各地区进度 · \(update.outstandingCount) 项未完成")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(update.regions) { record in
                            Button { destination = .progress(update.id, record.regionId) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(store.regionName(record.regionId)).font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        UpdateStatusBadge(status: record.status)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.secondary)
                                    }
                                    if let date = record.completedAt {
                                        Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 10)).foregroundStyle(theme.secondary)
                                    }
                                    if !record.notes.isEmpty {
                                        Text(record.notes).font(.system(size: 11)).foregroundStyle(theme.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .ledgerSection(theme)
                            }
                            .buttonStyle(QingPressStyle())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .onExitCommand(perform: closeDestination)
        } else {
            VStack { emptyMessage("更新记录已不存在"); Button("返回", action: closeDestination) }
        }
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12)).foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.vertical, 16)
    }

    private func closeDestination() { destination = nil }
}

extension View {
    func ledgerSection(_ theme: QingTheme) -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line) }
    }
}
