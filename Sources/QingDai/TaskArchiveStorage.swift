import Darwin
import Foundation

struct TaskArchive {
    static let currentVersion = 4
    static let maximumItems = 10_000
    static let maximumBytes = 32 * 1024 * 1024

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func decode(_ data: Data) throws -> WorkspaceData {
        guard data.count <= maximumBytes else { throw TaskDataError.invalid("数据文件不能超过 32 MiB。") }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = root["version"] as? Int,
            (1...currentVersion).contains(version),
            let rawItems = root["items"] as? [[String: Any]]
        else { throw TaskDataError.invalid("不是有效的轻待备份文件。") }
        guard rawItems.count <= maximumItems else { throw TaskDataError.invalid("最多保存 10,000 条事项。") }
        var archive = WorkspaceData(items: try rawItems.map { try decodeItem($0, version: version) })
        if version >= 4 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                return try decodeDate(text, version: version)
            }
            func records<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
                guard let value = root[key] as? [Any] else {
                    throw TaskDataError.invalid("备份缺少有效的 \(key) 数据。")
                }
                return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value))
            }
            archive.projects = try records("projects", as: [ManagedProject].self)
            archive.regions = try records("regions", as: [ProjectRegion].self)
            archive.updates = try records("updates", as: [ProjectUpdate].self)
        }
        return try validate(archive)
    }

    static func encode(_ archive: WorkspaceData) throws -> Data {
        let checked = try validate(archive)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
        func records<T: Encodable>(_ values: T) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(values))
        }
        let root: [String: Any] = [
            "version": currentVersion, "items": checked.items.map(encodeItem),
            "projects": try records(checked.projects), "regions": try records(checked.regions),
            "updates": try records(checked.updates),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= maximumBytes else { throw TaskDataError.invalid("数据文件不能超过 32 MiB。") }
        return data
    }

    static func validate(_ items: [TodoItem]) throws -> [TodoItem] {
        guard items.count <= maximumItems else { throw TaskDataError.invalid("最多保存 10,000 条事项。") }
        var ids = Set<UUID>()
        var generatedParents = Set<UUID>()
        return try items.map { item in
            guard ids.insert(item.id).inserted else { throw TaskDataError.invalid("数据包含重复的事项 ID。") }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 500 else { throw TaskDataError.invalid("事项标题须为 1–500 个字。") }
            guard item.notes.count <= 10_000 else { throw TaskDataError.invalid("备注最多 10,000 个字。") }
            let links = unique(item.links)
            let tags = unique(item.tags)
            guard links.count <= 10, tags.count <= 10 else {
                throw TaskDataError.invalid("每条事项最多包含 10 个链接和 10 个标签。")
            }
            guard tags.allSatisfy({ $0.count <= 30 }) else { throw TaskDataError.invalid("每个标签最多 30 个字。") }
            for link in links {
                guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
                    throw TaskDataError.invalid("链接格式不正确。")
                }
                let validWeb = (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
                let validFile = scheme == "file" && url.isFileURL && url.path.hasPrefix("/")
                guard validWeb || validFile else {
                    throw TaskDataError.invalid("链接仅支持 http、https 或本地绝对路径 file URL。")
                }
            }
            if let parent = item.generatedFromId {
                guard parent != item.id, generatedParents.insert(parent).inserted else {
                    throw TaskDataError.invalid("重复计划存在自引用或同一事项的多个后续项。")
                }
            }
            var copy = item
            copy.title = title
            copy.links = links
            copy.tags = tags
            return copy
        }
    }

    private static func decodeItem(_ raw: [String: Any], version: Int) throws -> TodoItem {
        guard
            let idText = raw["id"] as? String,
            let id = UUID(uuidString: idText),
            let title = raw["title"] as? String,
            let createdRaw = raw["createdAt"]
        else { throw TaskDataError.invalid("事项数据缺少必要字段。") }

        func date(_ key: String) throws -> Date? {
            guard let value = raw[key], !(value is NSNull) else { return nil }
            return try decodeDate(value, version: version)
        }
        func strings(_ key: String) throws -> [String] {
            guard let value = raw[key], !(value is NSNull) else { return [] }
            guard let result = value as? [String] else { throw TaskDataError.invalid("字段 \(key) 必须是文本列表。") }
            return result
        }
        func uuid(_ modern: String, _ legacy: String) throws -> UUID? {
            guard let value = raw[modern] ?? raw[legacy], !(value is NSNull) else { return nil }
            guard let text = value as? String, let result = UUID(uuidString: text) else {
                throw TaskDataError.invalid("事项包含无效 ID。")
            }
            return result
        }

        let repeatText = raw["repeatRule"] as? String ?? RepeatRule.none.rawValue
        guard let repeatRule = RepeatRule(rawValue: repeatText) else { throw TaskDataError.invalid("包含未知的重复规则。") }
        return TodoItem(
            id: id,
            title: title,
            createdAt: try decodeDate(createdRaw, version: version),
            completedAt: try date("completedAt"),
            deferredUntil: try date("deferredUntil"),
            isPinned: raw["isPinned"] as? Bool ?? false,
            notes: raw["notes"] as? String ?? "",
            links: try strings("links"),
            tags: try strings("tags"),
            reminderEnabled: raw["reminderEnabled"] as? Bool ?? false,
            reminderAt: try date("reminderAt"),
            repeatRule: repeatRule,
            repeatAnchor: try date("repeatAnchor"),
            seriesId: try uuid("seriesId", "seriesID"),
            generatedFromId: try uuid("generatedFromId", "generatedFromID"),
            projectId: try uuid("projectId", "projectId"),
            regionId: try uuid("regionId", "regionId"),
            updateId: try uuid("updateId", "updateId")
        )
    }

    private static func encodeItem(_ item: TodoItem) -> [String: Any] {
        func date(_ value: Date?) -> Any { value.map { isoFormatter.string(from: $0) } ?? NSNull() }
        return [
            "id": item.id.uuidString.lowercased(),
            "title": item.title,
            "createdAt": isoFormatter.string(from: item.createdAt),
            "completedAt": date(item.completedAt),
            "deferredUntil": date(item.deferredUntil),
            "isPinned": item.isPinned,
            "notes": item.notes,
            "links": item.links,
            "tags": item.tags,
            "reminderEnabled": item.reminderEnabled,
            "reminderAt": date(item.reminderAt),
            "repeatRule": item.repeatRule.rawValue,
            "repeatAnchor": date(item.repeatAnchor),
            "seriesId": item.seriesId.map { $0.uuidString.lowercased() } ?? NSNull(),
            "generatedFromId": item.generatedFromId.map { $0.uuidString.lowercased() } ?? NSNull(),
            "projectId": item.projectId.map { $0.uuidString.lowercased() } ?? NSNull(),
            "regionId": item.regionId.map { $0.uuidString.lowercased() } ?? NSNull(),
            "updateId": item.updateId.map { $0.uuidString.lowercased() } ?? NSNull(),
        ]
    }

    private static func decodeDate(_ raw: Any, version: Int) throws -> Date {
        if version <= 2, let number = raw as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        if let text = raw as? String,
           let date = isoFormatter.date(from: text) ?? fallbackISOFormatter.date(from: text) {
            return date
        }
        throw TaskDataError.invalid("日期格式不正确。")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

typealias TaskArchiveCodec = TaskArchive

final class ArchiveStorage {
    let directoryURL: URL
    let fileURL: URL
    let backupsURL: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = support.appendingPathComponent("QingDai", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("tasks.json")
        backupsURL = directoryURL.appendingPathComponent("Backups", isDirectory: true)
    }

    func read() throws -> Data? {
        try ensureDirectory(directoryURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        try requireRegularFile(fileURL)
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= TaskArchive.maximumBytes else { throw TaskDataError.storage("数据文件不能超过 32 MiB。") }
        try createDailyBackupIfNeeded()
        return data
    }

    func write(_ data: Data, forceBackup: Bool = false) throws {
        guard data.count <= TaskArchive.maximumBytes else { throw TaskDataError.storage("数据文件不能超过 32 MiB。") }
        try ensureDirectory(directoryURL)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        if exists {
            try requireRegularFile(fileURL)
            if forceBackup { _ = try createBackup(kind: .forced) }
            try createDailyBackupIfNeeded()
        }
        let temporary = directoryURL.appendingPathComponent(".qingdai-write-\(UUID().uuidString.lowercased()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let result = temporary.path.withCString { source in
            fileURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw TaskDataError.storage("保存记录失败：\(String(cString: strerror(errno)))") }
        if !exists { try createDailyBackupIfNeeded() }
    }

    func listBackups() throws -> [TaskBackup] {
        guard FileManager.default.fileExists(atPath: backupsURL.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard let identity = backupIdentity(url.lastPathComponent) else { return nil }
            return TaskBackup(
                id: url.lastPathComponent,
                url: url,
                createdAt: identity.date,
                automatic: identity.kind == .automatic
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func readBackup(_ backup: TaskBackup) throws -> Data {
        guard
            backupIdentity(backup.id) != nil,
            backup.url.deletingLastPathComponent().standardizedFileURL == backupsURL.standardizedFileURL
        else { throw TaskDataError.storage("备份文件无效。") }
        try requireRegularFile(backup.url)
        let data = try Data(contentsOf: backup.url, options: .mappedIfSafe)
        guard data.count <= TaskArchive.maximumBytes else { throw TaskDataError.storage("备份文件不能超过 32 MiB。") }
        return data
    }

    private func createDailyBackupIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if try listBackups().contains(where: { $0.automatic && Calendar.current.isDateInToday($0.createdAt) }) { return }
        _ = try createBackup(kind: .automatic)
        for backup in try listBackups().filter(\.automatic).dropFirst(30) {
            try FileManager.default.removeItem(at: backup.url)
        }
    }

    private func createBackup(kind: BackupKind) throws -> URL {
        try requireRegularFile(fileURL)
        try ensureDirectory(backupsURL)
        let microseconds = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let name = "qingdai-\(kind.rawValue)-\(microseconds)-\(UUID().uuidString.lowercased()).json"
        let destination = backupsURL.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination
    }

    private func backupIdentity(_ name: String) -> (kind: BackupKind, date: Date)? {
        let pattern = #"^qingdai-(auto|forced)-(\d{1,18})-([0-9a-fA-F-]{36})\.json$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
            let kindRange = Range(match.range(at: 1), in: name),
            let microsRange = Range(match.range(at: 2), in: name),
            let kind = BackupKind(rawValue: String(name[kindRange])),
            let microseconds = Int64(name[microsRange])
        else { return nil }
        return (kind, Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000))
    }

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw TaskDataError.storage("数据目录不是文件夹。") }
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TaskDataError.storage("数据必须是普通文件，不能是目录或符号链接。")
        }
    }
}
