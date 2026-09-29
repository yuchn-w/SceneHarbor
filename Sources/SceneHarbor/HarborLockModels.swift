import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// The lock renderer deliberately accepts only local, already-installed
/// video and scene sources.  Web projects never enter this model.
enum HarborLockWallpaperKind: String, Codable, CaseIterable, Sendable {
    case video
    case scene
}

enum HarborLockMode: String, Codable, Sendable {
    /// macOS 26+ Wallpaper Extension.  This is the only mode that can
    /// represent the real lock-screen surface; a ScreenSaverView is kept as
    /// a separate integration and must never be reported as this mode.
    case wallpaperExtension
    case screenSaver
}

enum HarborLockFillMode: String, Codable, Sendable {
    case cover
    case contain
    case stretch

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "contain", "fit", "完整顯示": self = .contain
        case "stretch", "拉伸": self = .stretch
        default: self = .cover
        }
    }
}

/// Codable representation for the small subset of Wallpaper Engine
/// properties that can be passed to a lock renderer.  It intentionally does
/// not preserve arbitrary class instances or closures from the UI settings.
enum HarborLockAnyValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: HarborLockAnyValue])
    case array([HarborLockAnyValue])
    case null

    init(_ value: Any) {
        switch value {
        case let value as NSNumber:
            #if canImport(CoreFoundation)
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
            #else
            self = .number(value.doubleValue)
            #endif
        case let value as Bool:
            self = .bool(value)
        case let value as String:
            self = .string(value)
        case let value as NSString:
            self = .string(value as String)
        case let value as [String: Any]:
            self = .object(value.mapValues(Self.init))
        case let value as [Any]:
            self = .array(value.map(Self.init))
        default:
            self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: HarborLockAnyValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([HarborLockAnyValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var foundationValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues(\.foundationValue)
        case let .array(value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

struct HarborLockDisplayConfiguration: Codable, Equatable, Sendable {
    let displayID: UInt32
    let wallpaperID: String
    let title: String
    let kind: HarborLockWallpaperKind
    let renderDirectory: String
    let entryPath: String
    let previewPath: String?
    let runtimeProperties: [String: HarborLockAnyValue]
    let fps: Int
    let fillMode: HarborLockFillMode
    let audioMuted: Bool
    let sourceFingerprint: String
    var desktopFallbackPath: String?

    var isSafeForLockRenderer: Bool {
        audioMuted && (10...60).contains(fps)
            && (kind == .video || kind == .scene)
    }
}

struct HarborLockConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let enabled: Bool
    let mode: HarborLockMode
    let displays: [String: HarborLockDisplayConfiguration]
    let updatedAt: Date

    var isValid: Bool {
        version == Self.currentVersion
            && !displays.isEmpty
            && displays.values.allSatisfy(\.isSafeForLockRenderer)
    }
}

struct HarborLockUpdateResult: Equatable, Sendable {
    let mode: HarborLockMode
    let wallpaperID: String
    let title: String
    let displayIDs: [UInt32]
    let configurationURL: URL
    let configurationDigest: String
}

enum HarborLockStoreRecovery: Equatable, Sendable {
    case clean
    case rolledBack
    case conflict
}

enum HarborLockError: LocalizedError, Equatable {
    case unsupportedOperatingSystem(String)
    case unsupportedWallpaperKind(String)
    case missingEntrypoint
    case invalidEntrypoint(String)
    case invalidRenderDirectory(String)
    case symbolicLinkNotAllowed(String)
    case unsupportedFileExtension(String)
    case invalidConfiguration
    case configurationConflict
    case activeTransaction
    case orphanedBackup
    case noTransaction
    case recoveryConflict
    case sharedContainerUnavailable
    case runtimeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedOperatingSystem(message): return "目前 macOS 不支援動態鎖定畫面：" + message
        case let .unsupportedWallpaperKind(kind): return "鎖定畫面只支援本機影片或 Scene，目前是：" + kind
        case .missingEntrypoint: return "找不到桌布的本機播放入口"
        case let .invalidEntrypoint(path): return "桌布播放入口無效：" + path
        case let .invalidRenderDirectory(path): return "桌布資源目錄無效：" + path
        case let .symbolicLinkNotAllowed(path): return "鎖定畫面不接受符號連結資源：" + path
        case let .unsupportedFileExtension(ext): return "鎖定畫面不支援此檔案格式：" + ext
        case .invalidConfiguration: return "鎖定畫面設定無效"
        case .configurationConflict: return "鎖定畫面設定在更新期間已被其他來源修改"
        case .activeTransaction: return "鎖定畫面仍有未完成的更新交易"
        case .orphanedBackup: return "找到未完成的鎖定畫面備份，為保護使用者設定暫停更新"
        case .noTransaction: return "沒有可復原的鎖定畫面交易"
        case .recoveryConflict: return "復原時發現使用者設定已改變，未覆寫目前內容"
        case .sharedContainerUnavailable: return "鎖定畫面共享容器尚未可用"
        case let .runtimeUnavailable(message): return "鎖定畫面 renderer 尚未就緒：" + message
        }
    }
}
