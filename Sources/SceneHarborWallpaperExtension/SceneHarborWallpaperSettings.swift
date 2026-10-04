// SceneHarbor Wallpaper Extension
//
// This small Codable/XPC adapter follows the macOS 26 Wallpaper settings
// object shape observed in MirageWallpaper GPL-3.0 at commit
// d1f7ca76d5b93e235467f1c4f7c0c05c1aace454.  It is kept separate from the
// renderer so a provider can expose one selectable choice per display.

import Foundation
import ImageIO

private struct SceneHarborSettingsViewModels: Codable {
    let desktop: SceneHarborSettingsViewModel?
    let screenSaver: SceneHarborSettingsViewModel?
}

private struct SceneHarborSettingsViewModel: Codable {
    let groups: [SceneHarborSettingsGroup]
    let refreshPolicy: SceneHarborRefreshPolicy
    let isModificationDisabled: Bool
}

private struct SceneHarborSettingsGroup: Codable {
    let id: SceneHarborGroupID
    let items: [SceneHarborSettingsItem]
    let localizedName: String
    let disposability: SceneHarborDisposability
    let sortOrder: Int
    let sortID: SceneHarborGroupSortID?
    let allChoiceID: SceneHarborChoiceID?
    let shouldHideItemLabels: Bool?
    let contextMenu: SceneHarborContextMenu?
    let thumbnail: Data?
}

private struct SceneHarborSettingsItem: Codable {
    let id: SceneHarborChoiceID
    let localizedName: String
    let thumbnail: SceneHarborThumbnail
    let choice: SceneHarborChoiceDescriptor
    let contentBadge: SceneHarborContentBadge
    let showInTopLevel: Bool
    let sortOrder: Int
    let disposability: SceneHarborDisposability
}

private struct SceneHarborChoiceID: Codable {
    let id: String
    let descriptor: SceneHarborChoiceIDDescriptor
}

private struct SceneHarborChoiceIDDescriptor: Codable {
    let provider: SceneHarborChoiceProviderID
    let identifier: String
    let files: [URL]
    let configuration: Data
}

private struct SceneHarborChoiceDescriptor: Codable {
    let id: SceneHarborChoiceID
    let provider: SceneHarborChoiceProviderID
    let identifier: String
    let name: String?
    let localizedDescription: String
    let thumbnail: SceneHarborThumbnail
    let isDownloaded: Bool
    let options: [SceneHarborWallpaperOption]
}

private struct SceneHarborChoiceProviderID: Codable {
    let rawValue: String

    init(_ value: String) { rawValue = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private struct SceneHarborWallpaperOption: Codable {}
private struct SceneHarborGroupID: Codable { let id: String }
private struct SceneHarborGroupSortID: Codable { let id: String }

private enum SceneHarborDisposability: Codable {
    case none
    case removable
    case purgeable

    private enum Keys: String, CodingKey { case none, removable, purgeable }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .none: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .none)
        case .removable: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .removable)
        case .purgeable: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .purgeable)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.removable) { self = .removable }
        else if container.contains(.purgeable) { self = .purgeable }
        else { self = .none }
    }
}

private enum SceneHarborContentBadge: Codable {
    case none
    case video
    case dynamic

    private enum Keys: String, CodingKey { case none, video, dynamic }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .none: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .none)
        case .video: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .video)
        case .dynamic: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .dynamic)
        }
    }

    init(from decoder: Decoder) throws { self = .none }
}

private enum SceneHarborRefreshPolicy: Codable {
    case discretionary
    private enum Keys: String, CodingKey { case discretionary }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .discretionary)
    }

    init(from decoder: Decoder) throws { self = .discretionary }
}

private enum SceneHarborThumbnail: Codable {
    case image(URL)

    private enum Keys: String, CodingKey { case image }
    private enum ImageKeys: String, CodingKey { case url }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        var image = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
        try image.encode(value, forKey: .url)
    }

    private var value: URL {
        if case let .image(url) = self { return url }
        fatalError("unreachable")
    }

    init(from decoder: Decoder) throws {
        self = .image(URL(fileURLWithPath: "/"))
    }
}

private struct SceneHarborContextMenu: Codable { let items: [SceneHarborContextMenuItem] }
private struct SceneHarborContextMenuItem: Codable { let identifier: String; let name: String }
private enum EmptyKeys: String, CodingKey { case value }

@objc(SceneHarborShimViewModelsXPC)
private final class SceneHarborShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let value: SceneHarborSettingsViewModels

    init(value: SceneHarborSettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder: NSCoder) { return nil }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else { return }
        try? archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
    }
}

func sceneHarborSettingsViewModels(configuration: HarborLockConfiguration) -> AnyObject? {
    let provider = SceneHarborChoiceProviderID(Bundle.main.bundleIdentifier ?? "org.sceneharbor.SceneHarbor.WallpaperExtension")
    let fallback = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarDisplay.icns")
    let displays = configuration.displays.values.sorted { $0.displayID < $1.displayID }
    let items = displays.map { display in
        let identifier = "display-\(display.displayID)"
        let choiceID = SceneHarborChoiceID(
            id: identifier,
            descriptor: SceneHarborChoiceIDDescriptor(provider: provider, identifier: identifier,
                                                      files: [], configuration: Data(identifier.utf8)))
        let thumbnailURL = display.previewPath.map(URL.init(fileURLWithPath:)) ?? fallback
        let thumbnail = SceneHarborThumbnail.image(thumbnailURL)
        return SceneHarborSettingsItem(
            id: choiceID,
            localizedName: "SceneHarbor · \(display.title)",
            thumbnail: thumbnail,
            choice: SceneHarborChoiceDescriptor(
                id: choiceID, provider: provider, identifier: identifier, name: display.title,
                localizedDescription: "SceneHarbor 動態鎖定畫面",
                thumbnail: thumbnail, isDownloaded: true, options: []),
            contentBadge: display.kind == .scene ? .dynamic : .video,
            showInTopLevel: true, sortOrder: Int(display.displayID), disposability: .none)
    }
    let group = SceneHarborSettingsGroup(
        id: SceneHarborGroupID(id: "sceneharbor-dynamic-lock-screen"), items: items,
        localizedName: "SceneHarbor 動態鎖定畫面", disposability: .none, sortOrder: -100,
        sortID: SceneHarborGroupSortID(id: "com.apple.wallpaper.aerials"), allChoiceID: nil,
        shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil)
    let models = SceneHarborSettingsViewModels(
        desktop: SceneHarborSettingsViewModel(groups: configuration.enabled ? [group] : [],
                                              refreshPolicy: .discretionary, isModificationDisabled: false),
        screenSaver: SceneHarborSettingsViewModel(groups: configuration.enabled ? [group] : [],
                                                 refreshPolicy: .discretionary, isModificationDisabled: false))
    guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: SceneHarborShimViewModelsXPC(value: models), requiringSecureCoding: false),
          let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    let realClass: AnyClass? = "WallpaperSettingsViewModelsXPC".withCString { pointer in
        objc_getClass(pointer) as? AnyClass
    }
    guard let realClass else { return nil }
    unarchiver.requiresSecureCoding = false
    unarchiver.setClass(realClass, forClassName: "SceneHarborShimViewModelsXPC")
    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    unarchiver.finishDecoding()
    return result as AnyObject?
}
