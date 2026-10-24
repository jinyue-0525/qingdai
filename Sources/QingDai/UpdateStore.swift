import Foundation

extension TaskStore {
    var activeProjects: [ManagedProject] { projects.filter { !$0.isArchived } }

    func projectName(_ id: UUID?) -> String {
        projects.first { $0.id == id }?.name ?? "未分类"
    }

    func regionName(_ id: UUID?) -> String {
        regions.first { $0.id == id }?.name ?? "项目通用"
    }

    func assignmentLabel(for item: TodoItem) -> String {
        guard item.projectId != nil else { return "未分类" }
        return "\(projectName(item.projectId)) · \(regionName(item.regionId))"
    }

    func activeRegions(in projectId: UUID) -> [ProjectRegion] {
        regions.filter { $0.projectId == projectId && !$0.isArchived }
    }

    func isActive(_ region: ProjectRegion) -> Bool {
        !region.isArchived && projects.contains { $0.id == region.projectId && !$0.isArchived }
    }

    func outstandingUpdates(in regionId: UUID) -> [ProjectUpdate] {
        updates.filter { update in
            update.regions.contains { $0.regionId == regionId && $0.status.isOutstanding }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var outstandingUpdateCount: Int {
        let active = Set(regions.filter { isActive($0) }.map(\.id))
        return updates.reduce(0) { total, update in
            total + update.regions.filter { active.contains($0.regionId) && $0.status.isOutstanding }.count
        }
    }

    var outstandingRegionCount: Int {
        regions.filter { isActive($0) && !outstandingUpdates(in: $0.id).isEmpty }.count
    }

    @discardableResult
    func saveProject(id: UUID?, name: String) -> Bool {
        var archive = snapshot
        if let id {
            guard let index = archive.projects.firstIndex(where: { $0.id == id }) else {
                errorMessage = "项目已不存在，请重新打开。"; return false
            }
            archive.projects[index].name = name
        } else {
            archive.projects.append(ManagedProject(name: name))
        }
        return commit(archive, message: id == nil ? "已添加项目" : "已保存项目")
    }

    @discardableResult
    func saveRegion(id: UUID?, projectId: UUID, name: String) -> Bool {
        var archive = snapshot
        if let id {
            guard let index = archive.regions.firstIndex(where: { $0.id == id }),
                  archive.regions[index].projectId == projectId else {
                errorMessage = "地区已不存在，请重新打开。"; return false
            }
            archive.regions[index].name = name
        } else {
            archive.regions.append(ProjectRegion(projectId: projectId, name: name))
        }
        return commit(archive, message: id == nil ? "已添加地区" : "已保存地区")
    }

    func setProjectArchived(_ id: UUID, archived: Bool) {
        var archive = snapshot
        guard let index = archive.projects.firstIndex(where: { $0.id == id }) else { return }
        archive.projects[index].isArchived = archived
        _ = commit(archive, message: archived ? "项目已归档" : "项目已恢复")
    }

    func setRegionArchived(_ id: UUID, archived: Bool) {
        var archive = snapshot
        guard let index = archive.regions.firstIndex(where: { $0.id == id }) else { return }
        archive.regions[index].isArchived = archived
        _ = commit(archive, message: archived ? "地区已归档" : "地区已恢复")
    }

    func moveProject(_ id: UUID, by offset: Int) {
        var archive = snapshot
        guard let index = archive.projects.firstIndex(where: { $0.id == id }),
              archive.projects.indices.contains(index + offset) else { return }
        archive.projects.swapAt(index, index + offset)
        _ = commit(archive, message: "已调整项目顺序")
    }

    func moveRegion(_ id: UUID, by offset: Int) {
        var archive = snapshot
        guard let region = regions.first(where: { $0.id == id }) else { return }
        let indices = archive.regions.indices.filter { archive.regions[$0].projectId == region.projectId }
        guard let position = indices.firstIndex(where: { archive.regions[$0].id == id }),
              indices.indices.contains(position + offset) else { return }
        archive.regions.swapAt(indices[position], indices[position + offset])
        _ = commit(archive, message: "已调整地区顺序")
    }

    @discardableResult
    func saveUpdate(id: UUID?, projectId: UUID, title: String, version: String,
                    notes: String, regionIds: Set<UUID>) -> Bool {
        var archive = snapshot
        var update: ProjectUpdate
        if let id {
            guard let existing = updates.first(where: { $0.id == id }), existing.projectId == projectId else {
                errorMessage = "更新已不存在或所属项目发生变化，请重新打开。"; return false
            }
            update = existing
            // Progress and history are retained. Remove applicability by recording 不适用.
            guard Set(existing.regions.map(\.regionId)).isSubset(of: regionIds) else {
                errorMessage = "已有地区不能移除，请在地区进度中标记为“不适用”。"; return false
            }
        } else {
            update = ProjectUpdate(projectId: projectId, title: title)
        }
        update.title = title
        update.version = version
        update.notes = notes
        let previousIDs = Set(update.regions.map(\.regionId))
        for region in regions where regionIds.contains(region.id) && !previousIDs.contains(region.id) {
            update.regions.append(RegionUpdate(
                regionId: region.id, history: [UpdateEvent(status: .pending, notes: "")]
            ))
        }
        guard Set(update.regions.map(\.regionId)) == regionIds else {
            errorMessage = "部分地区已不存在，请重新选择。"; return false
        }
        if let index = archive.updates.firstIndex(where: { $0.id == update.id }) {
            archive.updates[index] = update
        } else {
            archive.updates.append(update)
        }
        return commit(archive, message: id == nil ? "更新已登记" : "更新已保存")
    }

    @discardableResult
    func saveProgress(updateId: UUID, regionId: UUID, status: UpdateStatus,
                      notes: String, completedAt: Date? = nil) -> Bool {
        var archive = snapshot
        guard let updateIndex = archive.updates.firstIndex(where: { $0.id == updateId }),
              let regionIndex = archive.updates[updateIndex].regions.firstIndex(where: { $0.regionId == regionId }) else {
            errorMessage = "这条地区更新记录已不存在，请重新打开。"; return false
        }
        var record = archive.updates[updateIndex].regions[regionIndex]
        let completion = status == .updated ? (completedAt ?? record.completedAt ?? Date()) : nil
        if let completion, completion > Date() {
            errorMessage = "实际完成时间不能晚于现在。"; return false
        }
        guard record.status != status || record.notes != notes || record.completedAt != completion else {
            clearError(); return true
        }
        record.completedAt = completion
        record.status = status
        record.notes = notes
        record.history.append(UpdateEvent(status: status, notes: notes, completedAt: completion))
        archive.updates[updateIndex].regions[regionIndex] = record
        return commit(archive, message: "\(regionName(regionId)) · \(status.title)")
    }

    @discardableResult
    func addUpdateTodo(updateId: UUID, regionId: UUID) -> Bool {
        guard let update = updates.first(where: { $0.id == updateId }),
              update.regions.contains(where: { $0.regionId == regionId }) else {
            errorMessage = "更新或地区已不存在。"; return false
        }
        guard !items.contains(where: { !$0.isCompleted && $0.updateId == updateId && $0.regionId == regionId }) else {
            errorMessage = "这项更新已经有未完成的待办。"; return false
        }
        var archive = snapshot
        archive.items.insert(TodoItem(
            title: update.title, notes: update.notes,
            projectId: update.projectId, regionId: regionId, updateId: updateId
        ), at: 0)
        return commit(archive, message: "已加入待办")
    }
}
