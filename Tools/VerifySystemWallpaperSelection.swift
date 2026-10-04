import Foundation

@main enum VerifySystemWallpaperSelection {
    static func main() throws {
        typealias Adapter = HarborSystemWallpaperSelection

        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            print("PASS: \(message)")
        }

        func entry(provider: String, configuration: Data = Data([1])) -> [String: Any] {
            ["Content": ["Choices": [["Provider": provider, "Configuration": configuration, "Files": []]],
                          "Shuffle": "$null",
                          "EncodedOptionValues": try! Adapter.encode(["values": [:] as [String: Any]])],
             "LastSet": Date(timeIntervalSince1970: 100),
             "LastUse": Date(timeIntervalSince1970: 101)]
        }

        let desktop = entry(provider: "original")
        let idle = entry(provider: "screensaver", configuration: Data([2]))
        let individual: [String: Any] = ["Type": "individual", "Desktop": desktop, "Idle": idle, "UnknownFutureKey": "preserved"]
        let linked: [String: Any] = ["Type": "linked", "Linked": desktop, "UnknownLinkedKey": 7]
        let allSpacesNull: Any = "$null"
        let root: [String: Any] = [
            "Displays": [
                "A": individual,
                "B": linked,
                "UNRELATED": individual
            ],
            "Spaces": [
                "one": ["Displays": ["A": individual, "B": linked, "UNRELATED": individual]],
                "two": ["Displays": ["A": individual]]
            ],
            "SystemDefault": individual,
            "AllSpacesAndDisplays": allSpacesNull,
            "Future": ["value": 42]
        ]
        let original = try Adapter.encode(root)
        let (data, patches) = try Adapter.prepare(original, displays: ["A": 1, "B": 2])
        let result = try Adapter.decode(data)
        expect(Adapter.selected(result, displays: ["A": 1, "B": 2]), "linked choices selected for displays and materialized spaces")

        let displays = result["Displays"] as! [String: [String: Any]]
        let displayA = displays["A"]!
        let displayB = displays["B"]!
        expect(displayA["Type"] as? String == "linked", "individual display migrated to linked")
        expect(Adapter.isOwned(displayA["Linked"] as? [String: Any]), "linked display keeps SceneHarbor provider")
        expect((displayA["Linked"] as? [String: Any])?["Content"] as? [String: Any] != nil, "linked display stores wallpaper content")
        expect(displayA["Desktop"] == nil && displayA["Idle"] == nil, "linked display removes competing Desktop and Idle slots")
        expect(displayB["Type"] as? String == "linked", "existing linked display remains linked")
        expect(NSDictionary(dictionary: displays["UNRELATED"]!).isEqual(to: individual), "unrelated display preserved")
        expect(result["AllSpacesAndDisplays"] as? String == "$null", "AllSpacesAndDisplays null preserved")
        expect(NSDictionary(dictionary: result["SystemDefault"] as! [String: Any]).isEqual(to: individual), "unowned global default preserved")
        expect(NSDictionary(dictionary: result["Future"] as! [String: Any]).isEqual(to: ["value": 42]), "unknown root key preserved")

        let restored = try Adapter.decode(Adapter.restore(data, patches: patches))
        expect(NSDictionary(dictionary: restored).isEqual(to: root), "fresh linked migration rolls back the complete original shape")

        // A changed unknown key is retained while the still-owned linked slot
        // is restored. A changed provider is treated as the user's choice.
        var changed = result
        var changedDisplays = changed["Displays"] as! [String: [String: Any]]
        changedDisplays["A"]!["UnknownFutureKey"] = "user metadata"
        changedDisplays["B"] = ["Type": "individual", "Desktop": entry(provider: "user"), "Idle": entry(provider: "user-idle")]
        changed["Displays"] = changedDisplays
        let changedRestored = try Adapter.decode(Adapter.restore(try Adapter.encode(changed), patches: patches))
        let changedRestoredDisplays = changedRestored["Displays"] as! [String: [String: Any]]
        expect(changedRestoredDisplays["A"]!["Type"] as? String == "individual", "owned linked shape restored")
        expect(changedRestoredDisplays["A"]!["UnknownFutureKey"] as? String == "user metadata", "unknown metadata after activation preserved")
        expect(NSDictionary(dictionary: changedRestoredDisplays["B"]!).isEqual(to: changedDisplays["B"]!), "later user display choice is not overwritten")

        var linkedSlotChanged = result
        var linkedSlotDisplays = linkedSlotChanged["Displays"] as! [String: [String: Any]]
        linkedSlotDisplays["A"]!["Idle"] = entry(provider: "user-idle-after-linked")
        linkedSlotChanged["Displays"] = linkedSlotDisplays
        let linkedSlotRestored = try Adapter.decode(Adapter.restore(try Adapter.encode(linkedSlotChanged), patches: patches))
        let linkedSlotA = (linkedSlotRestored["Displays"] as! [String: [String: Any]])["A"]!
        expect(NSDictionary(dictionary: linkedSlotA["Idle"] as! [String: Any]).isEqual(to: linkedSlotDisplays["A"]!["Idle"] as! [String: Any]), "later linked Idle change is not overwritten")

        let (_, secondPatches) = try Adapter.prepare(data, displays: ["A": 1, "B": 2])
        expect(secondPatches.isEmpty, "linked activation is idempotent")
        do {
            _ = try Adapter.prepare(try Adapter.encode(["Displays": ["A": ["Type": "individual", "Desktop": "unknown"]]]), displays: ["A": 1])
            fatalError("unknown display node accepted")
        } catch {
            print("PASS: unknown target node fails without mutation")
        }
        do {
            _ = try Adapter.prepare(try Adapter.encode(["Displays": ["A": ["Type": "linked", "Linked": "unknown"]]]), displays: ["A": 1])
            fatalError("unknown linked node accepted")
        } catch {
            print("PASS: unknown linked format fails conservatively")
        }

        // Existing 0.13.3 receipt: Before remains the initial user node,
        // while the Idle value present at upgrade is recorded separately.
        let legacyBefore: [String: Any] = ["Type": "individual", "Desktop": desktop, "Idle": idle, "LegacyKey": "keep"]
        let laterIdle = entry(provider: "later-user-idle", configuration: Data([9]))
        let legacyCurrent: [String: Any] = ["Type": "individual", "Desktop": entry(provider: Adapter.provider, configuration: Data("display-1".utf8)), "Idle": laterIdle, "LegacyKey": "keep"]
        let legacyRoot: [String: Any] = ["Displays": ["A": legacyCurrent], "AllSpacesAndDisplays": "$null"]
        let (migratedData, additions) = try Adapter.prepare(try Adapter.encode(legacyRoot), displays: ["A": 1])
        let legacyPatch: [String: Any] = ["Path": ["Displays", "A"], "Before": legacyBefore]
        let merged = Adapter.mergePatches([legacyPatch], additions: additions)
        expect(merged.count == 1, "legacy receipt patch is merged without duplication")
        expect(NSDictionary(dictionary: merged[0]["Before"] as! [String: Any]).isEqual(to: legacyBefore), "legacy receipt keeps original Before")
        expect(NSDictionary(dictionary: merged[0]["IdleBeforeTakeover"] as! [String: Any]).isEqual(to: laterIdle), "legacy upgrade records the later user Idle choice")
        let migratedRestored = try Adapter.decode(Adapter.restore(migratedData, patches: merged))
        let migratedDisplay = (migratedRestored["Displays"] as! [String: [String: Any]])["A"]!
        expect(NSDictionary(dictionary: migratedDisplay["Desktop"] as! [String: Any]).isEqual(to: desktop), "legacy receipt restores original Desktop")
        expect(NSDictionary(dictionary: migratedDisplay["Idle"] as! [String: Any]).isEqual(to: laterIdle), "legacy receipt restores later Idle rather than stale original")
        expect(migratedDisplay["LegacyKey"] as? String == "keep", "legacy metadata survives migration rollback")

        let ownedGlobal = ["Type": "individual", "Desktop": entry(provider: Adapter.provider, configuration: Data([8])), "Idle": idle, "GlobalKey": "keep"] as [String: Any]
        let globalRoot: [String: Any] = ["Displays": ["A": individual], "SystemDefault": ownedGlobal]
        let (globalData, globalPatches) = try Adapter.prepare(try Adapter.encode(globalRoot), displays: ["A": 1])
        let globalResult = try Adapter.decode(globalData)
        expect((globalResult["SystemDefault"] as! [String: Any])["Type"] as? String == "linked", "owned SystemDefault normalized to linked")
        expect(globalPatches.contains { ($0["Path"] as? [String]) == ["SystemDefault"] }, "owned SystemDefault has an undo patch")
        expect(NSDictionary(dictionary: try Adapter.decode(Adapter.restore(globalData, patches: globalPatches))).isEqual(to: globalRoot), "owned SystemDefault rolls back exactly")
    }
}
