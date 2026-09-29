import Foundation

@main
@MainActor
struct IPCRuntimeTests {
    static func main() async throws {
        let config = URL(fileURLWithPath: "/private/tmp/sceneharbor-ipc-tests-\(UUID())/iina.json")
        let ipc = IINAHDRIPC(configurationURL: config, port: 48744)
        var events: [IINAHDREvent] = []
        var status = ""
        ipc.onEvent = { events.append($0) }
        ipc.onStatus = { status = $0 }
        ipc.start()
        defer { ipc.stop(); try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        for _ in 0..<50 where status.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        precondition(status == "IINA 整合尚未連線", "listener must start")
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        let token = values["token"] as! String
        let permissions = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let json = #"{"version":1,"session":"real-loopback","sequence":1,"event":"file-loaded","active":true,"path":"/tmp/video.mov","transfer":"pq","timestamp":1}"#
        func send(_ authorization: String, body: String, type: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:48744/auto-hdr/iina")!)
            request.httpMethod = "POST"; request.timeoutInterval = 3
            request.setValue("Bearer " + authorization, forHTTPHeaderField: "Authorization")
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as! HTTPURLResponse).statusCode
        }
        let bad = try await send("invalid", body: json, type: "application/json")
        precondition(bad == 401 && events.isEmpty)
        let good = try await send(token, body: json, type: "application/json")
        precondition(good == 204 && events.count == 1)
        let form = "payload=" + json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let formStatus = try await send(token, body: form, type: "application/x-www-form-urlencoded")
        precondition(formStatus == 204 && events.count == 2)
        print("PASS real 127.0.0.1 HTTP: ready, config0600, bad token401, JSON204, IINA form204")
    }
}
