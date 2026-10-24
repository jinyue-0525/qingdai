import SwiftUI

@MainActor
struct WorkspaceScopePicker: View {
    @ObservedObject var store: TaskStore
    @Binding var scope: WorkspaceScope
    var includesUnassigned = false
    var includesCommon = false
    var includesArchived = false

    @Environment(\.colorScheme) private var colorScheme
    private var theme: QingTheme { QingTheme(scheme: colorScheme) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("项目").font(.system(size: 10)).foregroundStyle(theme.secondary)
                Picker("项目", selection: $scope.project) {
                    Text("全部项目").tag(ProjectSelection.all)
                    if includesUnassigned { Text("未分类").tag(ProjectSelection.unassigned) }
                    ForEach(store.projects.filter { includesArchived || !$0.isArchived || $0.id == scope.projectId }) { project in
                        Text(project.name + (project.isArchived ? "（归档）" : ""))
                            .tag(ProjectSelection.project(project.id))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scopeField(theme)
            VStack(alignment: .leading, spacing: 4) {
                Text("地区").font(.system(size: 10)).foregroundStyle(theme.secondary)
                Picker("地区", selection: $scope.region) {
                    Text("全部地区").tag(RegionSelection.all)
                    if includesCommon { Text("项目通用").tag(RegionSelection.common) }
                    ForEach(store.regions.filter {
                        $0.projectId == scope.projectId && (includesArchived || !$0.isArchived || $0.id == scope.regionId)
                    }) { region in
                        Text(region.name + (region.isArchived ? "（归档）" : ""))
                            .tag(RegionSelection.region(region.id))
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(scope.projectId == nil)
            }
            .scopeField(theme)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .font(.system(size: 11))
        .onChange(of: scope.project) { _, _ in scope.region = .all }
    }
}

private extension View {
    func scopeField(_ theme: QingTheme) -> some View {
        padding(8)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line) }
    }
}

@MainActor
struct TaskAssignmentFields: View {
    @ObservedObject var store: TaskStore
    @Binding var projectId: UUID?
    @Binding var regionId: UUID?
    @Binding var updateId: UUID?

    var body: some View {
        VStack(spacing: 8) {
            Picker("项目", selection: $projectId) {
                Text("未分类").tag(nil as UUID?)
                ForEach(store.projects.filter { !$0.isArchived || $0.id == projectId }) { project in
                    Text(project.name + (project.isArchived ? "（归档）" : "")).tag(Optional(project.id))
                }
            }
            Picker("地区", selection: $regionId) {
                Text("项目通用").tag(nil as UUID?)
                ForEach(store.regions.filter {
                    $0.projectId == projectId && (!$0.isArchived || $0.id == regionId)
                }) { region in
                    Text(region.name + (region.isArchived ? "（归档）" : "")).tag(Optional(region.id))
                }
            }
            .disabled(projectId == nil)
            if projectId != nil {
                Picker("关联更新", selection: $updateId) {
                    Text("不关联").tag(nil as UUID?)
                    ForEach(store.updates.filter { $0.projectId == projectId }.sorted { $0.createdAt > $1.createdAt }) { update in
                        Text(update.title).tag(Optional(update.id))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .controlSize(.small)
        .onChange(of: projectId) { _, _ in
            regionId = nil
            updateId = nil
        }
    }
}

struct UpdateStatusBadge: View {
    let status: UpdateStatus
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        let theme = QingTheme(scheme: colorScheme)
        switch status {
        case .pending, .inProgress: return theme.accentText
        case .failed: return theme.failureText
        case .updated: return theme.successText
        case .notApplicable: return theme.secondary
        }
    }

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}
