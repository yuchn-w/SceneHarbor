import Foundation

/// Categories that can be generated from the text metadata of wallpapers.
/// The classifier deliberately does not inspect pixels or contact a service.
enum HarborPlaylistAutoCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case rain
    case city
    case scenery
    case day
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rain: return "雨天"
        case .city: return "城市"
        case .scenery: return "風景"
        case .day: return "白天"
        case .night: return "夜晚"
        }
    }

    var symbol: String {
        switch self {
        case .rain: return "cloud.rain.fill"
        case .city: return "building.2.fill"
        case .scenery: return "mountain.2.fill"
        case .day: return "sun.max.fill"
        case .night: return "moon.stars.fill"
        }
    }

    var autoPlaylistName: String { "自動分類 · " + title }

    var explanatoryText: String {
        "依標題、檔名與作品標籤文字推測"
    }
}

/// A project plus the local text metadata available for conservative matching.
/// Workshop manifests are read locally; local imported videos normally have no
/// manifest tags and therefore use their title and stored filename only.
struct HarborPlaylistClassificationInput: Equatable, Sendable {
    let project: WallpaperEngineProject
    let manifestTags: [String]
}

struct HarborPlaylistClassificationMatch: Identifiable, Equatable, Sendable {
    let project: WallpaperEngineProject
    let evidence: [String]

    var id: String { project.directory.standardizedFileURL.path }
}

struct HarborPlaylistAutoClassification: Equatable, Sendable {
    let candidates: [WallpaperEngineProject]
    let matchesByCategory: [HarborPlaylistAutoCategory: [HarborPlaylistClassificationMatch]]

    func matches(for category: HarborPlaylistAutoCategory) -> [HarborPlaylistClassificationMatch] {
        matchesByCategory[category] ?? []
    }

    func paths(for category: HarborPlaylistAutoCategory) -> [String] {
        var seen = Set<String>()
        return matches(for: category).compactMap { match in
            let path = match.project.directory.standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }

    var matchedCandidatePaths: Set<String> {
        Set(matchesByCategory.values.flatMap { $0 }.map { $0.project.directory.standardizedFileURL.path })
    }

    var unmatchedCount: Int {
        max(0, candidates.count - matchedCandidatePaths.count)
    }
}

/// Conservative, local-only classification for the playlist composer.
///
/// A match is a text hint, not a visual claim. Each result keeps the source
/// field and matched term so the UI can show the user why a project was placed
/// in a category before a new playlist is created.
enum HarborPlaylistAutoClassifier {
    private struct TextField {
        let label: String
        let value: String
    }

    private static let keywords: [HarborPlaylistAutoCategory: [String]] = [
        .rain: ["rain", "raining", "rainy", "rainstorm", "storm", "thunderstorm", "thunder", "drizzle", "downpour", "waterdrop", "雨", "雨天", "下雨", "暴雨", "雷雨"],
        .city: ["city", "cityscape", "urban", "street", "streetview", "neon", "cyberpunk", "tokyo", "shanghai", "hong kong", "城市", "都市", "街景", "街道", "霓虹"],
        .scenery: ["scenery", "landscape", "nature", "mountain", "forest", "lake", "ocean", "sea", "river", "waterfall", "sunset", "風景", "自然", "山", "森林", "湖", "海", "河", "瀑布", "夕陽"],
        .day: ["day", "daytime", "sunrise", "sunny", "sunlight", "morning", "dawn", "sun", "白天", "日間", "清晨", "日出", "陽光"],
        .night: ["night", "nighttime", "midnight", "evening", "moon", "moonlight", "starlight", "stars", "夜", "夜晚", "夜景", "深夜", "月", "星空", "暮色"]
    ]

    /// Build inputs from the already scanned local projects. Reading
    /// `project.json` here is local filesystem work and is safe to run from a
    /// detached utility task. No Steam request or image analysis is involved.
    static func inputs(for projects: [WallpaperEngineProject]) -> [HarborPlaylistClassificationInput] {
        var seen = Set<String>()
        return projects.compactMap { project in
            guard isPlayableCandidate(project) else { return nil }
            let path = project.directory.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return HarborPlaylistClassificationInput(project: project, manifestTags: manifestTags(for: project))
        }
    }

    static func classify(projects: [WallpaperEngineProject]) -> HarborPlaylistAutoClassification {
        classify(inputs: inputs(for: projects))
    }

    static func classify(inputs: [HarborPlaylistClassificationInput]) -> HarborPlaylistAutoClassification {
        var candidates: [WallpaperEngineProject] = []
        var seen = Set<String>()
        var matches: [HarborPlaylistAutoCategory: [HarborPlaylistClassificationMatch]] = [:]

        for input in inputs where isPlayableCandidate(input.project) {
            let path = input.project.directory.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            candidates.append(input.project)

            let fields = [
                TextField(label: "標題", value: input.project.title),
                TextField(label: "檔名", value: input.project.entrypoint?.lastPathComponent ?? input.project.directory.lastPathComponent),
                TextField(label: "作品標籤", value: input.manifestTags.joined(separator: " "))
            ]
            for category in HarborPlaylistAutoCategory.allCases {
                var evidence: [String] = []
                for field in fields where !field.value.isEmpty {
                    for keyword in keywords[category] ?? [] where contains(keyword, in: field.value) {
                        let item = "\(field.label)：\(keyword)"
                        if !evidence.contains(item) { evidence.append(item) }
                    }
                }
                guard !evidence.isEmpty else { continue }
                matches[category, default: []].append(
                    HarborPlaylistClassificationMatch(project: input.project, evidence: evidence)
                )
            }
        }

        return HarborPlaylistAutoClassification(candidates: candidates, matchesByCategory: matches)
    }

    private static func isPlayableCandidate(_ project: WallpaperEngineProject) -> Bool {
        [.video, .scene, .web].contains(project.kind)
            && project.entrypoint.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    private static func manifestTags(for project: WallpaperEngineProject) -> [String] {
        let manifestURL = project.directory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = object["tags"] as? [String] else {
            return []
        }
        return tags.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func contains(_ keyword: String, in value: String) -> Bool {
        let text = normalize(value)
        let term = normalize(keyword)
        guard !text.isEmpty, !term.isEmpty else { return false }

        // English words use boundaries so a title such as "training" does
        // not become a rain match. CJK terms intentionally use containment so
        // titles such as "下雨的城市" remain discoverable.
        if term.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            let padded = " " + text + " "
            return padded.contains(" " + term + " ")
        }
        return text.contains(term)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return folded.map { character in
            character.isLetter || character.isNumber ? String(character) : " "
        }.joined()
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    }
}
