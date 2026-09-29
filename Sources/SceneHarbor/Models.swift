import CoreGraphics
import Foundation

enum LibrarySection: String, CaseIterable, Identifiable {
    case all = "所有桌布"
    case favorites = "我的收藏"
    case recent = "最近加入"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        case .recent: return "clock.fill"
        }
    }
}

enum MainPage: String, CaseIterable, Identifiable {
    case workshop = "工坊"
    case home = "本機首頁"
    case media = "我的媒體"
    case playlists = "播放清單"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .workshop: return "square.grid.2x2.fill"
        case .home: return "house.fill"
        case .media: return "folder.fill"
        case .playlists: return "rectangle.stack.fill"
        }
    }
}

struct WallpaperItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    let videoPath: String
    let thumbnailPath: String?
    let duration: Double
    let width: Int
    let height: Int
    var fileSizeBytes: Int64?
    var isFavorite: Bool
    let dateAdded: Date

    var resolutionText: String {
        guard width > 0, height > 0 else { return "未知解析度" }
        return "\(width) × \(height)"
    }

    var durationText: String {
        guard duration.isFinite, duration > 0 else { return "循環影片" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var fileURL: URL { URL(fileURLWithPath: videoPath) }

    var fileSizeText: String {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var dateAddedText: String {
        dateAdded.formatted(date: .abbreviated, time: .omitted)
    }

    var isFourK: Bool { width >= 3_840 || height >= 2_160 }

    var isWidescreen: Bool {
        guard height > 0 else { return false }
        return abs((Double(width) / Double(height)) - (16.0 / 9.0)) < 0.08
    }
}

struct DisplayTarget: Identifiable, Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let isBuiltIn: Bool

    var resolutionText: String { "\(width) × \(height)" }
}

struct WallpaperPlaylist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var itemIDs: [UUID]
    let dateCreated: Date
    var kind: WallpaperPlaylistKind
    var dayItemIDs: [UUID]
    var nightItemIDs: [UUID]
    /// 只供 0.4.0 舊資料遷移使用，新資料一律寫入 `kind` 與日夜分區。
    var schedulePeriod: WallpaperSchedulePeriod?

    init(
        id: UUID,
        title: String,
        itemIDs: [UUID],
        dateCreated: Date,
        kind: WallpaperPlaylistKind = .standard,
        dayItemIDs: [UUID] = [],
        nightItemIDs: [UUID] = [],
        schedulePeriod: WallpaperSchedulePeriod? = nil
    ) {
        self.id = id
        self.title = title
        self.itemIDs = itemIDs
        self.dateCreated = dateCreated
        self.kind = kind
        self.dayItemIDs = dayItemIDs
        self.nightItemIDs = nightItemIDs
        self.schedulePeriod = schedulePeriod
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, itemIDs, dateCreated, kind, dayItemIDs, nightItemIDs, schedulePeriod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        itemIDs = try container.decodeIfPresent([UUID].self, forKey: .itemIDs) ?? []
        dateCreated = try container.decode(Date.self, forKey: .dateCreated)
        kind = try container.decodeIfPresent(WallpaperPlaylistKind.self, forKey: .kind) ?? .standard
        dayItemIDs = try container.decodeIfPresent([UUID].self, forKey: .dayItemIDs) ?? []
        nightItemIDs = try container.decodeIfPresent([UUID].self, forKey: .nightItemIDs) ?? []
        schedulePeriod = try container.decodeIfPresent(WallpaperSchedulePeriod.self, forKey: .schedulePeriod)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(itemIDs, forKey: .itemIDs)
        try container.encode(dateCreated, forKey: .dateCreated)
        try container.encode(kind, forKey: .kind)
        try container.encode(dayItemIDs, forKey: .dayItemIDs)
        try container.encode(nightItemIDs, forKey: .nightItemIDs)
    }
}

enum WallpaperPlaylistKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "一般"
    case dayNight = "日夜輪播"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .standard: return "rectangle.stack.fill"
        case .dayNight: return "sun.and.horizon.fill"
        }
    }
}

enum WallpaperSchedulePeriod: String, CaseIterable, Identifiable, Codable, Sendable {
    case day = "白天"
    case night = "夜晚"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .day: return "sun.max.fill"
        case .night: return "moon.stars.fill"
        }
    }

    var timeRangeText: String {
        switch self {
        case .day: return "06:00–18:00"
        case .night: return "18:00–隔日 06:00"
        }
    }
}

enum PlayerScalingMode: String, CaseIterable, Identifiable {
    case fill = "填滿"
    case fit = "完整顯示"

    var id: String { rawValue }
}

enum PlaybackQuality: String, CaseIterable, Identifiable {
    case original = "原始畫質"
    case fourK = "最高 4K"
    case twoK = "最高 1440p"
    case fullHD = "最高 1080p"

    var id: String { rawValue }

    var maximumResolution: CGSize {
        switch self {
        case .original: return .zero
        case .fourK: return CGSize(width: 3_840, height: 2_160)
        case .twoK: return CGSize(width: 2_560, height: 1_440)
        case .fullHD: return CGSize(width: 1_920, height: 1_080)
        }
    }
}
