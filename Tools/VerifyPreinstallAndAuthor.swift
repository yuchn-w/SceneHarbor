import Foundation
@testable import SceneHarbor

final class AuthorFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        if request.httpMethod == "POST" {
            let stream = request.httpBodyStream!
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(buffer, count: n) }
            let body = String(decoding: request.httpBody ?? bytes, as: UTF8.self)
            let values = body.components(separatedBy: "&").dropFirst().compactMap { $0.components(separatedBy: "=").last }
            let items: [[String: Any]] = values.reversed().map { ["publishedfileid": $0, "result": 1, "consumer_app_id": 431960,
                "creator": "00000000000000001", "title": "Work \($0)", "file_size": 42, "tags": [["tag": "Video"]]] }
            data = try! JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": items]])
        } else {
            let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "p" }!.value!)!
            let start = (page - 1) * 30
            data = Data(("Showing \(start + 1)-\(min(start + 30, 71)) of 71 entries" + (start..<min(start + 30, 71)).map { "<div id=\"sharedfile_\($0 + 1)\">" }.joined()).utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct VerifyPreinstallAndAuthor {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthorFixture.self]
        let api = SteamWorkshopAPI(session: URLSession(configuration: config))
        var ids: [String] = []
        for page in 1...3 { let result = try await api.queryAuthor("00000000000000001", page: page); precondition(result.items.count <= 24); ids += result.items.map(\.id) }
        precondition(ids == (1...71).map(String.init), "author pages must preserve all IDs and source ordering")
        let profile = URL(string: "https://steamcommunity.com/profiles/00000000000000001/myworkshopfiles/?appid=431960")!
        precondition(HarborCommunityWebView.destination(profile).author == "00000000000000001")
        precondition(HarborCommunityWebView.destination(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=42")!).artwork == "42")
        precondition(HarborCommunityWebView.destination(URL(string: "https://example.com/sharedfiles/filedetails/?id=42")!).artwork == nil)
        print("PASS native author pagination: 71 unique works, 24/page, ordered batch details; community links route internally")
        var commands: [[String: Any]] = []
        let transfer = HarborPreviewTransfers { commands.append($0) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sceneharbor-preview-protocol-test")
        var progress = 0.0
        let first = Task { try await transfer.fetch("42", root: root, progress: { progress = $0 }) }
        let second = Task { try await transfer.fetch("43", root: root, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(40))
        precondition(commands.count == 1 && commands[0]["maxUncompressedBytes"] as? Int64 == 1_073_741_824)
        let firstID = commands[0]["taskId"] as! String
        precondition(transfer.handle(["type": "downloadState", "taskId": firstID, "state": "downloading", "receivedBytes": 50, "totalBytes": 100]))
        precondition(progress == 0.5)
        first.cancel(); try await Task.sleep(for: .milliseconds(40))
        precondition(commands.count == 2 && commands.last?["command"] as? String == "cancelDownload")
        transfer.handle(["type": "downloadState", "taskId": firstID, "state": "cancelled"])
        precondition(commands.count == 3, "next preview must wait for terminal acknowledgement")
        let secondID = commands.last!["taskId"] as! String
        transfer.handle(["type": "downloadState", "taskId": secondID, "state": "completed", "outputPath": root.appendingPathComponent("43").path])
        let output = try await second.value; precondition(output.lastPathComponent == "43")
        do { _ = try await first.value; preconditionFailure("cancelled transfer succeeded") } catch is CancellationError {} catch { fatalError("wrong cancellation error") }
        precondition(transfer.handle(["type": "downloadState", "taskId": firstID, "state": "completed"]), "late preview events must never reach normal installation handling")
        precondition(!transfer.handle(["type": "downloadState", "taskId": "installation-id", "state": "completed"]))
        let rejected = Task { try await transfer.fetch("44", root: root, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(20))
        transfer.handle(["type": "response", "requestId": commands.last!["taskId"]!, "success": false, "message": "denied"])
        do { _ = try await rejected.value; preconditionFailure("rejection ignored") } catch {}
        print("PASS preview IPC isolation, progress, cancellation, one-transfer bound, rejection, late events")
        let fm = FileManager.default; try? fm.removeItem(at: root); try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for id in ["1", "2"] { let dir = root.appendingPathComponent(id); try fm.createDirectory(at: dir, withIntermediateDirectories: true); try Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent("file")) }
        try HarborRemotePreviewCache.prune(root: root, protected: ["2"], target: 100)
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("1").path) && fm.fileExists(atPath: root.appendingPathComponent("2").path))
        print("PASS cache eviction preserves active project leases")
        if CommandLine.arguments.contains("--live-author") {
            let a = try await SteamWorkshopAPI.shared.queryAuthor("00000000000000001", page: 1)
            let b = try await SteamWorkshopAPI.shared.queryAuthor("00000000000000001", page: 2)
            precondition(a.items.count == 24 && b.items.count == 24 && Set(a.items.map(\.id)).isDisjoint(with: b.items.map(\.id)))
            print("PASS live Steam author listing: two native pages, 24 works each, total \(a.total), no overlap")
        }
    }
}
