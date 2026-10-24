import Foundation

enum RepeatRule: String, CaseIterable, Codable, Identifiable {
    case none
    case daily
    case weekdays
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "不重复"
        case .daily: "每天"
        case .weekdays: "周一至周五"
        case .weekly: "每周"
        }
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var completedAt: Date?
    var deferredUntil: Date?
    var isPinned: Bool
    var notes: String
    var links: [String]
    var tags: [String]
    var reminderEnabled: Bool
    var reminderAt: Date?
    var repeatRule: RepeatRule
    var repeatAnchor: Date?
    var seriesId: UUID?
    var generatedFromId: UUID?
    var projectId: UUID?
    var regionId: UUID?
    var updateId: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        deferredUntil: Date? = nil,
        isPinned: Bool = false,
        notes: String = "",
        links: [String] = [],
        tags: [String] = [],
        reminderEnabled: Bool = false,
        reminderAt: Date? = nil,
        repeatRule: RepeatRule = .none,
        repeatAnchor: Date? = nil,
        seriesId: UUID? = nil,
        generatedFromId: UUID? = nil,
        projectId: UUID? = nil,
        regionId: UUID? = nil,
        updateId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.deferredUntil = deferredUntil
        self.isPinned = isPinned
        self.notes = notes
        self.links = links
        self.tags = tags
        self.reminderEnabled = reminderEnabled
        self.reminderAt = reminderAt
        self.repeatRule = repeatRule
        self.repeatAnchor = repeatAnchor
        self.seriesId = seriesId
        self.generatedFromId = generatedFromId
        self.projectId = projectId
        self.regionId = regionId
        self.updateId = updateId
    }

    var isCompleted: Bool { completedAt != nil }

    func isDeferred(at date: Date) -> Bool {
        !isCompleted && (deferredUntil.map { $0 > date } ?? false)
    }

    var notificationDate: Date? {
        guard !isCompleted, reminderEnabled else { return nil }
        return reminderAt ?? deferredUntil
    }

    // Keep the acronym spelling used by the original 1.4 archive and source API.
    var seriesID: UUID? {
        get { seriesId }
        set { seriesId = newValue }
    }

    var generatedFromID: UUID? {
        get { generatedFromId }
        set { generatedFromId = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, completedAt, deferredUntil, isPinned, notes, links, tags
        case reminderEnabled, reminderAt, repeatRule, repeatAnchor, seriesId, generatedFromId
        case seriesID, generatedFromID
        case projectId, regionId, updateId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        deferredUntil = try values.decodeIfPresent(Date.self, forKey: .deferredUntil)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        links = try values.decodeIfPresent([String].self, forKey: .links) ?? []
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        reminderEnabled = try values.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? false
        reminderAt = try values.decodeIfPresent(Date.self, forKey: .reminderAt)
        repeatRule = try values.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .none
        repeatAnchor = try values.decodeIfPresent(Date.self, forKey: .repeatAnchor)
        seriesId = try values.decodeIfPresent(UUID.self, forKey: .seriesId)
            ?? values.decodeIfPresent(UUID.self, forKey: .seriesID)
        generatedFromId = try values.decodeIfPresent(UUID.self, forKey: .generatedFromId)
            ?? values.decodeIfPresent(UUID.self, forKey: .generatedFromID)
        projectId = try values.decodeIfPresent(UUID.self, forKey: .projectId)
        regionId = try values.decodeIfPresent(UUID.self, forKey: .regionId)
        updateId = try values.decodeIfPresent(UUID.self, forKey: .updateId)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encodeIfPresent(deferredUntil, forKey: .deferredUntil)
        try values.encode(isPinned, forKey: .isPinned)
        try values.encode(notes, forKey: .notes)
        try values.encode(links, forKey: .links)
        try values.encode(tags, forKey: .tags)
        try values.encode(reminderEnabled, forKey: .reminderEnabled)
        try values.encodeIfPresent(reminderAt, forKey: .reminderAt)
        try values.encode(repeatRule, forKey: .repeatRule)
        try values.encodeIfPresent(repeatAnchor, forKey: .repeatAnchor)
        try values.encodeIfPresent(seriesId, forKey: .seriesId)
        try values.encodeIfPresent(generatedFromId, forKey: .generatedFromId)
        try values.encodeIfPresent(projectId, forKey: .projectId)
        try values.encodeIfPresent(regionId, forKey: .regionId)
        try values.encodeIfPresent(updateId, forKey: .updateId)
    }
}

struct TaskDetailsDraft: Equatable {
    var title: String
    var notes: String
    var linksText: String
    var tagsText: String
    var reminderEnabled: Bool
    var reminderAt: Date
    var repeatRule: RepeatRule
    var projectId: UUID?
    var regionId: UUID?
    var updateId: UUID?

    init(item: TodoItem) {
        title = item.title
        notes = item.notes
        linksText = item.links.joined(separator: "\n")
        tagsText = item.tags.joined(separator: "，")
        reminderEnabled = item.reminderEnabled
        reminderAt = item.reminderAt ?? item.deferredUntil ?? Date().addingTimeInterval(3600)
        repeatRule = item.repeatRule
        projectId = item.projectId
        regionId = item.regionId
        updateId = item.updateId
    }
}

typealias TaskDraft = TaskDetailsDraft

enum ImportMode {
    case merge
    case replace
}

enum BackupKind: String, Codable {
    case automatic = "auto"
    case forced
}

struct TaskBackup: Identifiable, Equatable {
    let id: String
    let url: URL
    let createdAt: Date
    let automatic: Bool

    var kind: BackupKind { automatic ? .automatic : .forced }
}

typealias BackupEntry = TaskBackup

enum TaskDataError: LocalizedError {
    case invalid(String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .storage(let message): message
        }
    }
}

typealias ArchiveError = TaskDataError
