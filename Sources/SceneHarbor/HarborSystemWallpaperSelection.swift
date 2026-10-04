import Foundation

/// A narrow, reversible adapter for the per-display macOS wallpaper store.
/// The store is private and can change: unfamiliar layouts fail without writing.
/// Active displays are published with macOS's linked Desktop/Idle representation.
/// Non-target nodes and keys are kept verbatim.
enum HarborSystemWallpaperSelection {
    static let provider = "org.sceneharbor.SceneHarbor.WallpaperExtension"
    private static let managedReceiptVersion = 2
    private static let managedKeys = ["Type", "Linked", "Desktop", "Idle"]

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    static var receiptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/SceneHarbor/LockScreen/system-selection.plist")
    }

    struct SelectionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func content(displayID: UInt32) -> [String: Any] {
        ["Choices": [["Provider": provider, "Configuration": Data("display-\(displayID)".utf8), "Files": []]],
         "Shuffle": "$null", "EncodedOptionValues": try! encode(["values": [:] as [String: Any]])]
    }

    /// Checks only the provider. Callers that are acting on a display should
    /// use the displayID overload so a different SceneHarbor choice is not
    /// mistaken for the choice owned by this activation.
    static func isOwned(_ entry: [String: Any]?) -> Bool {
        guard let content = entry?["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1 else { return false }
        return choices[0]["Provider"] as? String == provider
    }

    private static func isOwned(_ entry: [String: Any]?, displayID: UInt32) -> Bool {
        guard isOwned(entry),
              let content = entry?["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["Configuration"] as? Data == Data("display-\(displayID)".utf8) else { return false }
        return true
    }

    private static func choice(_ node: [String: Any], key: String) -> [String: Any]? {
        node[key] as? [String: Any]
    }

    private static func linkedNodeIsOwned(_ node: [String: Any], displayID: UInt32) -> Bool {
        guard node["Type"] as? String == "linked",
              let linked = choice(node, key: "Linked") else { return false }
        return isOwned(linked, displayID: displayID)
    }

    private static func individualNodeIsOwned(_ node: [String: Any], displayID: UInt32) -> Bool {
        guard let desktop = choice(node, key: "Desktop") else { return false }
        return isOwned(desktop, displayID: displayID)
    }

    private static func managedEntry(_ node: [String: Any]) -> [String: Any]? {
        if let linked = choice(node, key: "Linked") { return linked }
        return choice(node, key: "Desktop")
    }

    private static func linkedEntry(displayID: UInt32) -> [String: Any] {
        ["Content": content(displayID: displayID), "LastSet": Date(), "LastUse": Date()]
    }

    private static func setOrRemove(_ node: inout [String: Any], key: String, value: Any?) {
        if let value { node[key] = value }
        else { node.removeValue(forKey: key) }
    }

    private static func patch(path: [String], before: [String: Any], after: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "Path": path,
            "Before": before,
            "Managed": ["Type": "linked", "Linked": after["Linked"] as Any]
        ]
        // This is normally the same value as Before["Idle"]. It is kept as a
        // separate receipt field so a legacy receipt can retain its original
        // Before while also recording the user's later Idle choice at upgrade.
        if let idle = before["Idle"] { result["IdleBeforeTakeover"] = idle }
        return result
    }

    private static func validateNode(_ node: [String: Any], path: [String]) throws {
        let type = node["Type"] as? String
        if let type, type != "individual", type != "linked" {
            throw SelectionError(message: "macOS 桌布設定格式不支援自動連接（\(path.joined(separator: "."))）。")
        }
        if let value = node["Desktop"], !(value is [String: Any]) {
            throw SelectionError(message: "macOS 桌布設定格式不支援自動連接（Desktop）。")
        }
        if let value = node["Idle"], !(value is [String: Any]) {
            throw SelectionError(message: "macOS 桌布設定格式不支援自動連接（Idle）。")
        }
        if let value = node["Linked"], !(value is [String: Any]) {
            throw SelectionError(message: "macOS 桌布設定格式不支援自動連接（Linked）。")
        }
    }

    /// Converts one recognized node into macOS's linked form. The returned
    /// patch describes only a local reversible change; unknown keys stay in the
    /// node and therefore remain available for a later restore.
    private static func linkNode(_ original: [String: Any], path: [String], displayID: UInt32) throws -> ([String: Any], [String: Any]?) {
        try validateNode(original, path: path)
        var node = original
        if let type = node["Type"] as? String, type == "linked" {
            guard choice(node, key: "Linked") != nil else {
                throw SelectionError(message: "找不到可回復的系統桌布設定。")
            }
            if node["Desktop"] != nil || node["Idle"] != nil {
                throw SelectionError(message: "macOS 桌布設定格式不支援自動連接。")
            }
            if linkedNodeIsOwned(node, displayID: displayID) { return (node, nil) }
        } else if node["Type"] as? String == "individual" || node["Type"] == nil {
            guard choice(node, key: "Desktop") != nil else {
                throw SelectionError(message: "找不到可回復的系統桌布設定。")
            }
            // An individual node carrying both forms is ambiguous. Do not
            // guess which one macOS would use.
            if node["Type"] as? String == "individual", node["Linked"] != nil {
                throw SelectionError(message: "macOS 桌布設定格式不支援自動連接。")
            }
        } else {
            throw SelectionError(message: "macOS 桌布設定格式不支援自動連接。")
        }

        let before = node
        node["Type"] = "linked"
        node["Linked"] = linkedEntry(displayID: displayID)
        node.removeValue(forKey: "Desktop")
        node.removeValue(forKey: "Idle")
        return (node, patch(path: path, before: before, after: node))
    }

    private static func linkOwnedSystemDefault(_ original: [String: Any], path: [String]) throws -> ([String: Any], [String: Any]?) {
        // SystemDefault is a global fallback. An unowned value is left alone;
        // only a value that already belongs to SceneHarbor is normalized.
        guard let type = original["Type"] as? String else { return (original, nil) }
        var node = original
        switch type {
        case "individual":
            guard let desktop = choice(node, key: "Desktop"), isOwned(desktop) else { return (original, nil) }
            guard node["Linked"] == nil else { return (original, nil) }
            try validateNode(node, path: path)
            let before = node
            node["Type"] = "linked"
            node["Linked"] = desktop
            node.removeValue(forKey: "Desktop")
            node.removeValue(forKey: "Idle")
            return (node, patch(path: path, before: before, after: node))
        case "linked":
            // A linked SceneHarbor global value is already in the native shape.
            // Do not replace its configuration with an arbitrary display ID.
            guard let linked = choice(node, key: "Linked") else { return (original, nil) }
            return isOwned(linked) ? (original, nil) : (original, nil)
        default:
            return (original, nil)
        }
    }

    static func selected(_ root: [String: Any], displays: [String: UInt32]) -> Bool {
        guard !displays.isEmpty, let rawContainers = root["Displays"] as? [String: Any] else { return false }
        for (uuid, number) in displays {
            guard let node = rawContainers[uuid] as? [String: Any], linkedNodeIsOwned(node, displayID: number) else { return false }
        }

        // Spaces may omit a display when macOS has not materialized that space.
        // Every materialized target node must nevertheless use the same linked
        // provider/configuration.
        if let rawSpaces = root["Spaces"] {
            guard let spaces = rawSpaces as? [String: Any] else { return false }
            for (spaceID, rawSpace) in spaces {
                guard let space = rawSpace as? [String: Any] else { return false }
                guard let rawSpaceDisplays = space["Displays"] else { continue }
                guard let spaceDisplays = rawSpaceDisplays as? [String: Any] else { return false }
                for (uuid, number) in displays {
                    guard let rawNode = spaceDisplays[uuid] else { continue }
                    guard let node = rawNode as? [String: Any], linkedNodeIsOwned(node, displayID: number) else {
                        _ = spaceID
                        return false
                    }
                }
            }
        }
        return true
    }

    /// Returns updated data plus exact per-node prior values for conditional undo.
    static func prepare(_ data: Data, displays: [String: UInt32]) throws -> (Data, [[String: Any]]) {
        var root = try decode(data)
        guard !displays.isEmpty, var rawDisplays = root["Displays"] as? [String: Any],
              displays.keys.allSatisfy({ rawDisplays[$0] is [String: Any] }) else {
            throw SelectionError(message: "macOS 桌布設定格式不支援自動連接，請使用一次性的系統設定。")
        }
        var patches: [[String: Any]] = []
        for (uuid, number) in displays.sorted(by: { $0.key < $1.key }) {
            guard let original = rawDisplays[uuid] as? [String: Any] else {
                throw SelectionError(message: "找不到可回復的系統桌布設定。")
            }
            let (updated, nodePatch) = try linkNode(original, path: ["Displays", uuid], displayID: number)
            rawDisplays[uuid] = updated
            if let nodePatch { patches.append(nodePatch) }
        }
        root["Displays"] = rawDisplays

        if let rawSpaces = root["Spaces"] {
            guard var spaces = rawSpaces as? [String: Any] else {
                throw SelectionError(message: "macOS 桌布設定格式不支援自動連接（Spaces）。")
            }
            for spaceID in spaces.keys.sorted() {
                guard var space = spaces[spaceID] as? [String: Any] else {
                    throw SelectionError(message: "macOS 桌布設定格式不支援自動連接（Space）。")
                }
                guard let rawSpaceDisplays = space["Displays"] else {
                    spaces[spaceID] = space
                    continue
                }
                guard var spaceDisplays = rawSpaceDisplays as? [String: Any] else {
                    throw SelectionError(message: "macOS 桌布設定格式不支援自動連接（Space Displays）。")
                }
                for (uuid, number) in displays.sorted(by: { $0.key < $1.key }) {
                    guard let original = spaceDisplays[uuid] as? [String: Any] else { continue }
                    let path = ["Spaces", spaceID, "Displays", uuid]
                    let (updated, nodePatch) = try linkNode(original, path: path, displayID: number)
                    spaceDisplays[uuid] = updated
                    if let nodePatch { patches.append(nodePatch) }
                }
                space["Displays"] = spaceDisplays
                spaces[spaceID] = space
            }
            root["Spaces"] = spaces
        }

        if let rawDefault = root["SystemDefault"] as? [String: Any] {
            let (updated, nodePatch) = try linkOwnedSystemDefault(rawDefault, path: ["SystemDefault"])
            root["SystemDefault"] = updated
            if let nodePatch { patches.append(nodePatch) }
        }
        // AllSpacesAndDisplays is intentionally untouched. On the observed
        // macOS 27 store it is $null and is not a per-display selection.
        return (try encode(root), patches)
    }

    private static func node(at root: [String: Any], path: [String]) -> [String: Any]? {
        guard let key = path.first else { return root }
        guard let child = root[key] as? [String: Any] else { return nil }
        return node(at: child, path: Array(path.dropFirst()))
    }

    private static func targetDisplayID(for path: [String], displays: [String: UInt32]) -> UInt32? {
        guard path.count >= 2,
              path[0] == "Displays" || (path.count >= 4 && path[0] == "Spaces" && path[2] == "Displays") else { return nil }
        return displays[path.last!]
    }

    private static func receiptCanMigrate(_ root: [String: Any], patches: [[String: Any]], displays: [String: UInt32]) -> Bool {
        guard !patches.isEmpty else { return false }
        for patch in patches {
            guard let path = patch["Path"] as? [String], let current = node(at: root, path: path) else { return false }
            if path == ["SystemDefault"] {
                guard let entry = managedEntry(current), isOwned(entry) else { return false }
            } else if let displayID = targetDisplayID(for: path, displays: displays) {
                guard linkedNodeIsOwned(current, displayID: displayID) || individualNodeIsOwned(current, displayID: displayID) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    private static func samePath(_ lhs: [String], _ rhs: [String]) -> Bool { lhs == rhs }

    /// Merges a new native-linked patch into an existing receipt. The first
    /// patch for a path owns the original Before value; later activations only
    /// add the current takeover metadata and never append a duplicate.
    static func mergePatches(_ existing: [[String: Any]], additions: [[String: Any]]) -> [[String: Any]] {
        var merged: [[String: Any]] = []
        for original in existing {
            guard let path = original["Path"] as? [String] else { continue }
            guard !merged.contains(where: { ($0["Path"] as? [String]).map { samePath($0, path) } ?? false }) else { continue }
            merged.append(original)
        }
        for addition in additions {
            guard let path = addition["Path"] as? [String] else { continue }
            if let index = merged.firstIndex(where: { ($0["Path"] as? [String]).map { samePath($0, path) } ?? false }) {
                var retained = merged[index]
                if let managed = addition["Managed"] { retained["Managed"] = managed }
                if let idle = addition["IdleBeforeTakeover"] { retained["IdleBeforeTakeover"] = idle }
                merged[index] = retained
            } else {
                merged.append(addition)
            }
        }
        return merged
    }

    private static func restoreManaged(_ node: inout [String: Any], before: [String: Any], patch: [String: Any]) {
        guard let managed = patch["Managed"] as? [String: Any],
              let expected = managed["Linked"] as? [String: Any] else { return }
        let currentLinked = choice(node, key: "Linked")
        let linkedOwned = node["Type"] as? String == "linked" && sameOwnedIdentity(currentLinked, expected)
        let desktopOwned = sameOwnedIdentity(choice(node, key: "Desktop"), expected)
        let idleOwned = sameOwnedIdentity(choice(node, key: "Idle"), expected)

        if linkedOwned {
            for key in managedKeys {
                // A malformed-looking linked node can still be produced while
                // the user is changing Desktop or Idle in System Settings. If
                // such a slot is present but no longer carries our choice,
                // leave that slot exactly as the user set it.
                if (key == "Desktop" || key == "Idle"), node[key] != nil {
                    let stillOwned = key == "Desktop" ? desktopOwned : idleOwned
                    if !stillOwned { continue }
                }
                if key == "Idle", let laterIdle = patch["IdleBeforeTakeover"] {
                    setOrRemove(&node, key: key, value: laterIdle)
                } else {
                    setOrRemove(&node, key: key, value: before[key])
                }
            }
            return
        }

        // A user may have changed the linked shape into an individual node.
        // Restore only fields that still carry the exact SceneHarbor choice.
        if desktopOwned {
            setOrRemove(&node, key: "Desktop", value: before["Desktop"] ?? before["Linked"])
            if before["Type"] as? String == "individual" { node["Type"] = "individual" }
        }
        if idleOwned {
            setOrRemove(&node, key: "Idle", value: patch["IdleBeforeTakeover"] ?? before["Idle"])
        }
    }

    private static func sameOwnedIdentity(_ current: [String: Any]?, _ expected: [String: Any]) -> Bool {
        guard isOwned(current),
              let currentContent = current?["Content"] as? [String: Any],
              let currentChoices = currentContent["Choices"] as? [[String: Any]], currentChoices.count == 1,
              let expectedContent = expected["Content"] as? [String: Any],
              let expectedChoices = expectedContent["Choices"] as? [[String: Any]], expectedChoices.count == 1 else { return false }
        return currentChoices[0]["Provider"] as? String == expectedChoices[0]["Provider"] as? String &&
            currentChoices[0]["Configuration"] as? Data == expectedChoices[0]["Configuration"] as? Data
    }

    private static func restoreLegacy(_ node: inout [String: Any], before: [String: Any]) {
        let currentLinked = choice(node, key: "Linked")
        let currentDesktop = choice(node, key: "Desktop")
        let linkedOwned = isOwned(currentLinked)
        let desktopOwned = isOwned(currentDesktop)
        let idleOwned = isOwned(choice(node, key: "Idle"))

        if linkedOwned {
            for key in managedKeys {
                setOrRemove(&node, key: key, value: before[key])
            }
            return
        }
        if desktopOwned {
            if let beforeLinked = before["Linked"] as? [String: Any],
               let currentIdle = choice(node, key: "Idle"),
               NSDictionary(dictionary: currentIdle).isEqual(to: beforeLinked) {
                node["Type"] = before["Type"] ?? "linked"
                node["Linked"] = beforeLinked
                node.removeValue(forKey: "Desktop")
                node.removeValue(forKey: "Idle")
            } else {
                setOrRemove(&node, key: "Desktop", value: before["Desktop"] ?? before["Linked"])
                node.removeValue(forKey: "Linked")
                node["Type"] = "individual"
            }
        }
        if idleOwned, !desktopOwned {
            setOrRemove(&node, key: "Idle", value: before["Idle"])
        }
    }

    static func restore(_ data: Data, patches: [[String: Any]]) throws -> Data {
        var root = try decode(data)
        func undo(_ node: inout [String: Any], path: ArraySlice<String>, before: [String: Any], patch: [String: Any]) {
            guard let key = path.first else {
                if patch["Managed"] != nil { restoreManaged(&node, before: before, patch: patch) }
                else { restoreLegacy(&node, before: before) }
                return
            }
            guard var child = node[key] as? [String: Any] else { return }
            undo(&child, path: path.dropFirst(), before: before, patch: patch)
            node[key] = child
        }
        for patch in patches {
            guard let path = patch["Path"] as? [String], let before = patch["Before"] as? [String: Any] else { continue }
            undo(&root, path: path[...], before: before, patch: patch)
        }
        return try encode(root)
    }

    static func activate(displays: [String: UInt32], reloadSelected: Bool = false) throws -> Bool {
        let original = try Data(contentsOf: storeURL)
        let root = try decode(original)
        if selected(root, displays: displays) {
            // Launch Services can invalidate an extension when reopening its
            // containing app. A saved selection is not proof of a live renderer.
            if reloadSelected { try reloadAgent() }
            return false
        }

        let hasReceipt = FileManager.default.fileExists(atPath: receiptURL.path)
        var receiptBeforeData: Data?
        var receiptRoot: [String: Any] = [:]
        var existingPatches: [[String: Any]] = []
        if hasReceipt {
            receiptBeforeData = try Data(contentsOf: receiptURL)
            receiptRoot = try decode(receiptBeforeData!)
            guard let patches = receiptRoot["Patches"] as? [[String: Any]],
                  receiptCanMigrate(root, patches: patches, displays: displays) else {
                throw SelectionError(message: "系統桌布已被變更；關閉再開啟此開關可重新連接。")
            }
            existingPatches = patches
        }

        let (updated, additions) = try prepare(original, displays: displays)
        let patches: [[String: Any]]
        if hasReceipt {
            patches = mergePatches(existingPatches, additions: additions)
        } else {
            patches = additions
        }
        guard !patches.isEmpty else { return false }

        let directory = receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !hasReceipt {
            let backup = directory.appending(path: "system-wallpaper-before-\(UUID().uuidString).plist")
            try original.write(to: backup, options: .atomic)
            receiptRoot = ["Patches": patches, "Backup": backup.path, "Version": managedReceiptVersion]
        } else {
            // Retain the original Backup, unknown receipt keys, and every
            // initial Before value while adding the native-linked ownership.
            receiptRoot["Patches"] = patches
            receiptRoot["Version"] = managedReceiptVersion
        }
        try encode(receiptRoot).write(to: receiptURL, options: .atomic)
        guard try Data(contentsOf: storeURL) == original else {
            if let receiptBeforeData { try? receiptBeforeData.write(to: receiptURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: receiptURL) }
            throw SelectionError(message: "系統桌布設定剛剛有變動，請再試一次。")
        }
        var wroteUpdated = false
        do {
            try updated.write(to: storeURL, options: .atomic)
            wroteUpdated = true
            try reloadAgent()
            return true
        } catch {
            // If the write succeeded but WallpaperAgent could not be reloaded,
            // put the exact pre-activation store back while it is still the
            // data we wrote. This also covers newly-added paths during receipt
            // migration; restoring only the old receipt would leave those
            // paths owned by SceneHarbor without an undo record.
            if wroteUpdated, (try? Data(contentsOf: storeURL)) == updated {
                try? original.write(to: storeURL, options: .atomic)
                try? reloadAgent()
            }
            if let receiptBeforeData { try? receiptBeforeData.write(to: receiptURL, options: .atomic) }
            else { try? deactivate() }
            throw error
        }
    }

    static func deactivate() throws {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return }
        let receipt = try decode(Data(contentsOf: receiptURL))
        guard let patches = receipt["Patches"] as? [[String: Any]] else {
            throw SelectionError(message: "先前的系統設定回復紀錄無法讀取。")
        }
        let current = try Data(contentsOf: storeURL)
        let restored = try restore(current, patches: patches)
        guard try Data(contentsOf: storeURL) == current else {
            throw SelectionError(message: "系統桌布設定正在變動，請稍後重試回復。")
        }
        if !NSDictionary(dictionary: try decode(current)).isEqual(to: try decode(restored)) {
            try restored.write(to: storeURL, options: .atomic)
            try reloadAgent()
        }
        try FileManager.default.removeItem(at: receiptURL)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SelectionError(message: "無法讀取 macOS 桌布設定。")
        }
        return root
    }

    static func encode(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func reloadAgent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", NSUserName(), "WallpaperAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw SelectionError(message: "macOS 尚未重新載入桌布服務。")
        }
    }
}
