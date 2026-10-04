import Foundation

enum HarborShortcutExport {
    enum Failure: LocalizedError {
        case signing(String)
        var errorDescription: String? {
            switch self {
            case .signing(let message): return "捷徑檔案無法完成驗證：\(message)。仍可拷貝控制連結，在捷徑中加入「URL」與「打開 URL」。"
            }
        }
    }

    static func unsignedData(command: HarborAutomationCommand, name: String) throws -> Data {
        guard let url = command.url else { throw Failure.signing("指令不完整") }
        let document: [String: Any] = [
            "WFWorkflowName": name,
            "WFWorkflowClientVersion": "2600",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": [],
            "WFWorkflowOutputContentItemClasses": [], "WFWorkflowImportQuestions": [],
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowActions": [
                ["WFWorkflowActionIdentifier": "is.workflow.actions.url",
                 "WFWorkflowActionParameters": ["WFURLActionURL": url.absoluteString, "UUID": UUID().uuidString]],
                ["WFWorkflowActionIdentifier": "is.workflow.actions.openurl", "WFWorkflowActionParameters": [:]]
            ]
        ]
        return try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
    }

    static func write(command: HarborAutomationCommand, name: String, to destination: URL) async throws {
        let data = try unsignedData(command: command, name: name)
        try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneHarbor-Shortcut-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("input.shortcut")
            let signed = directory.appendingPathComponent("signed.shortcut")
            try data.write(to: source, options: .atomic)
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["sign", "--mode", "anyone", "--input", source.path, "--output", signed.path]
            process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + 30) == .timedOut {
                process.terminate()
                throw Failure.signing("系統回應逾時")
            }
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: signed.path) else {
                let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "系統尚未準備好"
                throw Failure.signing(String(detail.prefix(500)))
            }
            try Data(contentsOf: signed).write(to: destination, options: .atomic)
        }.value
    }
}
