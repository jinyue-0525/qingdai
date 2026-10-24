import Combine
import Foundation

@MainActor
final class PanelPresentation: ObservableObject {
    @Published private(set) var focusRequest = 0
    @Published private(set) var itemRequest = 0
    @Published var isPresented = false
    private(set) var requestedItemID: UUID?

    func requestComposerFocus() {
        focusRequest &+= 1
    }

    func requestItem(_ id: UUID) {
        requestedItemID = id
        itemRequest &+= 1
    }

    func takeRequestedItem() -> UUID? {
        defer { requestedItemID = nil }
        return requestedItemID
    }
}

enum PostponePreset: String, CaseIterable, Identifiable {
    case thirtyMinutes, oneHour, tomorrowMorning

    var id: Self { self }

    var title: String {
        switch self {
        case .thirtyMinutes: "30 分钟"
        case .oneHour: "1 小时"
        case .tomorrowMorning: "明天 9:00"
        }
    }

    func date(from now: Date = Date()) -> Date {
        switch self {
        case .thirtyMinutes:
            return now.addingTimeInterval(30 * 60)
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .tomorrowMorning:
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }
}
