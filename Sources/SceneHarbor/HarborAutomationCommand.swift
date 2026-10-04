import Foundation

enum HarborAutomationAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case next, start, stop, pause, resume, profile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .next: return "下一張桌布"
        case .start: return "開始播放清單"
        case .stop: return "停止輪播"
        case .pause: return "暫停輪播"
        case .resume: return "繼續輪播"
        case .profile: return "套用設定組合"
        }
    }
}

struct HarborAutomationCommand: Equatable, Sendable {
    let action: HarborAutomationAction
    var displayID: String?
    var playlistID: UUID?
    var profileID: UUID?

    var url: URL? {
        var parts = URLComponents()
        parts.scheme = "sceneharbor"; parts.host = "automation"; parts.path = "/" + action.rawValue
        var items: [URLQueryItem] = []
        if let displayID { items.append(.init(name: "display", value: displayID)) }
        if let playlistID { items.append(.init(name: "playlist", value: playlistID.uuidString)) }
        if let profileID { items.append(.init(name: "profile", value: profileID.uuidString)) }
        parts.queryItems = items
        return parts.url
    }

    static func parse(_ url: URL) -> HarborAutomationCommand? {
        guard url.absoluteString.utf8.count < 2048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "sceneharbor", parts.host == "automation",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let action = HarborAutomationAction(rawValue: String(parts.path.dropFirst())) else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["display", "playlist", "profile"].contains($0.name) && $0.value != nil }) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        let playlist = values["playlist"].flatMap(UUID.init(uuidString:))
        let profile = values["profile"].flatMap(UUID.init(uuidString:))
        if values["playlist"] != nil && playlist == nil || values["profile"] != nil && profile == nil { return nil }
        if action == .profile {
            guard profile != nil, values["display"] == nil, playlist == nil else { return nil }
        } else {
            guard let display = values["display"], !display.isEmpty, display.count < 256, profile == nil else { return nil }
            guard action == .start ? playlist != nil : playlist == nil else { return nil }
        }
        return .init(action: action, displayID: values["display"], playlistID: playlist, profileID: profile)
    }
}

struct HarborApplicationProfileRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var appName: String
    var bundleID: String
    var profileID: UUID
    var enabled = true
}
