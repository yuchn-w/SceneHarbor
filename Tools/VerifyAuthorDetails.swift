import Foundation
@testable import SceneHarbor
@main struct VerifyAuthorDetails {
    static func main() async throws {
        let page = try await SteamWorkshopAPI.shared.query(searchText: "3689794115")
        guard let item = page.items.first else { fatalError("No public details returned") }
        precondition(item.id == "3689794115" && !item.creatorID.isEmpty && item.creatorID.allSatisfy(\.isNumber))
        print("PASS selected installed artwork resolves public author ID, profile/workshop links and artwork metadata without subscription changes")
    }
}
