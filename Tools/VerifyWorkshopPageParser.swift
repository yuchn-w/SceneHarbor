import Foundation

@main enum VerifyWorkshopPageParser {
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }
    static func main() throws {
        let queries: [[String: Any]] = [["state": ["data": ["results": [["title": "Rain \"city\" 雨", "consumer_appid": 431960]], "total_count": 1]]]]
        let context = ["queryData": try json(["queries": queries])]
        let old = "<script>window.SSR.renderContext=JSON.parse(\(try json(try json(context))));</script>"
        let modern = "<script type=\"application/json\" id=\"valve-ssr-data\" nonce=\"fixture\">\(try json(["renderContext": context]))</script>"
        let reordered = "<script id='valve-ssr-data' type='application/json'>\(try json(["renderContext": context]))</script>"
        for page in [old, modern, reordered] {
            let parsed = HarborWorkshopPageParser.queries(in: page)!
            let actual = try json(parsed), expected = try json(queries)
            precondition(actual == expected)
        }
        for bad in ["", "<script>alert('no execution')</script>", modern.replacingOccurrences(of: "queryData", with: "unexpected"),
                    "<script type='application/json' id='valve-ssr-data'>{broken}</script>",
                    String(repeating: "x", count: HarborWorkshopPageParser.byteLimit + 1)] {
            precondition(HarborWorkshopPageParser.queries(in: bad) == nil)
        }
        if let path = CommandLine.arguments.dropFirst().first {
            let live = try String(contentsOfFile: path, encoding: .utf8)
            let decoded = HarborWorkshopPageParser.queries(in: live)!
            let counts = decoded.compactMap { ($0["state"] as? [String: Any])?["data"] as? [String: Any] }
                .compactMap { ($0["results"] as? [[String: Any]])?.count }
            precondition(counts.contains { $0 > 0 })
            print("PASS: real anonymous Steam response, result counts \(counts)")
        }
        print("PASS: legacy/current SSR, attribute order, escaped Unicode, malformed/oversized data, no JavaScript execution")
    }
}
