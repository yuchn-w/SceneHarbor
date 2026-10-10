import Foundation

/// Decode Steam's public data block as JSON only; never execute page scripts.
enum HarborWorkshopPageParser {
    static let byteLimit = 8 * 1024 * 1024
    static func queries(in html: String) -> [[String: Any]]? {
        guard html.utf8.count <= byteLimit else { return nil }
        let context: [String: Any]?
        let pattern = #"(?is)<script\b(?=[^>]*\bid\s*=\s*["']valve-ssr-data["'])(?=[^>]*\btype\s*=\s*["']application/json["'])[^>]*>(.*?)</script\s*>"#
        if let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html),
           let object = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any] {
            context = object["renderContext"] as? [String: Any]
        } else if let literal = legacyContext(in: html),
                  let object = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: Any] {
            context = object
        } else { return nil }
        guard let serialized = context?["queryData"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any] else { return nil }
        return object["queries"] as? [[String: Any]]
    }

    private static func legacyContext(in html: String) -> String? {
        guard let marker = html.range(of: "window.SSR.renderContext=JSON.parse(") else { return nil }
        var index = marker.upperBound
        guard index < html.endIndex, html[index] == "\"" else { return nil }
        let start = index
        index = html.index(after: index)
        var escaped = false
        while index < html.endIndex {
            let character = html[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" {
                return (try? JSONSerialization.jsonObject(with: Data(html[start...index].utf8), options: [.fragmentsAllowed])) as? String
            }
            index = html.index(after: index)
        }
        return nil
    }
}
