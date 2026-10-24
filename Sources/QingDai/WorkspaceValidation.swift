import Foundation

extension TaskArchive {
    static func validate(_ proposed: WorkspaceData) throws -> WorkspaceData {
        guard proposed.projects.count <= 1_000, proposed.regions.count <= 10_000,
              proposed.updates.count <= 10_000 else {
            throw TaskDataError.invalid("最多保存 1,000 个项目、10,000 个地区和 10,000 条更新。")
        }
        var checked = proposed
        checked.items = try validate(proposed.items)

        func checkIDs<T: Identifiable>(_ values: [T], label: String) throws where T.ID == UUID {
            guard Set(values.map(\.id)).count == values.count else {
                throw TaskDataError.invalid("\(label)包含重复 ID。")
            }
        }
        func name(_ value: String, label: String) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 80 else {
                throw TaskDataError.invalid("\(label)须为 1–80 个字。")
            }
            return trimmed
        }
        try checkIDs(checked.projects, label: "项目")
        try checkIDs(checked.regions, label: "地区")
        try checkIDs(checked.updates, label: "更新")
        var projectNames = Set<String>()
        for index in checked.projects.indices {
            let title = try name(checked.projects[index].name, label: "项目名称")
            guard projectNames.insert(title.lowercased()).inserted else {
                throw TaskDataError.invalid("项目名称重复，请使用不同名称。")
            }
            checked.projects[index].name = title
        }
        let projectIDs = Set(checked.projects.map(\.id))
        var regionNames: [UUID: Set<String>] = [:]
        for index in checked.regions.indices {
            let region = checked.regions[index]
            guard projectIDs.contains(region.projectId) else {
                throw TaskDataError.invalid("地区所属项目不存在。")
            }
            let title = try name(region.name, label: "地区名称")
            guard regionNames[region.projectId, default: []].insert(title.lowercased()).inserted else {
                throw TaskDataError.invalid("同一项目下的地区名称不能重复。")
            }
            checked.regions[index].name = title
        }
        let regions = Dictionary(uniqueKeysWithValues: checked.regions.map { ($0.id, $0) })
        var recordCount = 0
        var eventCount = 0
        for index in checked.updates.indices {
            var update = checked.updates[index]
            guard projectIDs.contains(update.projectId) else {
                throw TaskDataError.invalid("更新所属项目不存在。")
            }
            update.title = update.title.trimmingCharacters(in: .whitespacesAndNewlines)
            update.version = update.version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !update.title.isEmpty, update.title.count <= 500,
                  update.version.count <= 100, update.notes.count <= 10_000 else {
                throw TaskDataError.invalid("更新标题须为 1–500 个字，版本号最多 100 个字，备注最多 10,000 个字。")
            }
            guard !update.regions.isEmpty else { throw TaskDataError.invalid("请至少选择一个需要更新的地区。") }
            try checkIDs(update.regions, label: "更新地区")
            recordCount += update.regions.count
            for record in update.regions {
                guard regions[record.regionId]?.projectId == update.projectId else {
                    throw TaskDataError.invalid("更新地区不属于当前项目。")
                }
                guard record.notes.count <= 10_000, record.history.count <= 1_000 else {
                    throw TaskDataError.invalid("地区更新备注最多 10,000 个字，历史最多 1,000 条。")
                }
                try checkIDs(record.history, label: "更新历史")
                guard record.history.allSatisfy({ $0.notes.count <= 10_000 }) else {
                    throw TaskDataError.invalid("更新历史备注过长。")
                }
                guard (record.status == .updated) == (record.completedAt != nil) else {
                    throw TaskDataError.invalid("更新完成状态与完成时间不一致。")
                }
                if let last = record.history.last {
                    guard last.status == record.status, last.notes == record.notes else {
                        throw TaskDataError.invalid("更新状态与历史记录不一致。")
                    }
                }
                eventCount += record.history.count
            }
            checked.updates[index] = update
        }
        guard recordCount <= 100_000, eventCount <= 200_000 else {
            throw TaskDataError.invalid("地区更新记录或历史记录数量过多。")
        }
        let updates = Dictionary(uniqueKeysWithValues: checked.updates.map { ($0.id, $0) })
        for item in checked.items {
            if let projectId = item.projectId {
                guard projectIDs.contains(projectId) else { throw TaskDataError.invalid("待办所属项目不存在。") }
            }
            if let regionId = item.regionId {
                guard let region = regions[regionId], region.projectId == item.projectId else {
                    throw TaskDataError.invalid("待办地区不属于所选项目。")
                }
            }
            if let updateId = item.updateId {
                guard let update = updates[updateId], update.projectId == item.projectId else {
                    throw TaskDataError.invalid("待办关联的更新不属于所选项目。")
                }
            }
        }
        return checked
    }
}
