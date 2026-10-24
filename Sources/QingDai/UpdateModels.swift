import Foundation

struct ManagedProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isArchived = false
}

struct ProjectRegion: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectId: UUID
    var name: String
    var isArchived = false
}

enum UpdateStatus: String, CaseIterable, Codable, Identifiable {
    case pending, inProgress, updated, failed, notApplicable

    var id: Self { self }
    var title: String {
        switch self {
        case .pending: "待更新"
        case .inProgress: "更新中"
        case .updated: "已更新"
        case .failed: "更新失败"
        case .notApplicable: "不适用"
        }
    }
    var symbol: String {
        switch self {
        case .pending: "clock"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .updated: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .notApplicable: "minus.circle"
        }
    }
    var isOutstanding: Bool { self == .pending || self == .inProgress || self == .failed }
}

struct UpdateEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var status: UpdateStatus
    var notes: String
    var date = Date()
    var completedAt: Date?
}

struct RegionUpdate: Identifiable, Codable, Equatable {
    var regionId: UUID
    var status: UpdateStatus = .pending
    var notes = ""
    var completedAt: Date?
    var history: [UpdateEvent] = []

    var id: UUID { regionId }
}

struct ProjectUpdate: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectId: UUID
    var title: String
    var version = ""
    var notes = ""
    var createdAt = Date()
    var regions: [RegionUpdate] = []

    var outstandingCount: Int { regions.filter { $0.status.isOutstanding }.count }
}

struct WorkspaceData: Equatable {
    var items: [TodoItem] = []
    var projects: [ManagedProject] = []
    var regions: [ProjectRegion] = []
    var updates: [ProjectUpdate] = []

    func merging(_ incoming: WorkspaceData) -> WorkspaceData {
        // As with task imports, existing IDs win; never overwrite local progress.
        func merged<T: Identifiable>(_ local: [T], _ other: [T]) -> [T] where T.ID == UUID {
            let ids = Set(local.map(\.id))
            return local + other.filter { !ids.contains($0.id) }
        }
        return WorkspaceData(
            items: merged(items, incoming.items),
            projects: merged(projects, incoming.projects),
            regions: merged(regions, incoming.regions),
            updates: merged(updates, incoming.updates)
        )
    }
}

enum ProjectSelection: Hashable {
    case all, unassigned, project(UUID)
}

enum RegionSelection: Hashable {
    case all, common, region(UUID)
}

struct WorkspaceScope: Equatable {
    var project: ProjectSelection = .all
    var region: RegionSelection = .all

    var projectId: UUID? {
        if case .project(let id) = project { return id }
        return nil
    }
    var regionId: UUID? {
        if case .region(let id) = region { return id }
        return nil
    }

    func includes(_ item: TodoItem) -> Bool {
        switch project {
        case .all: return true
        case .unassigned: return item.projectId == nil
        case .project(let id):
            guard item.projectId == id else { return false }
            switch region {
            case .all: return true
            case .common: return item.regionId == nil
            case .region(let regionId): return item.regionId == regionId
            }
        }
    }
}
