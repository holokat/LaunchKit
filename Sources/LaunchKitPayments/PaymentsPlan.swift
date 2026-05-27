import Foundation
import LaunchKitCore

public enum InAppPurchaseKind: String, Codable, CaseIterable, Sendable {
    case consumable
    case nonConsumable
    case autoRenewableSubscription
    case nonRenewingSubscription
}

public struct InAppPurchaseDraft: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var referenceName: String
    public var productID: String
    public var kind: InAppPurchaseKind
    public var displayName: String
    public var reviewNotes: String

    public init(
        id: String,
        referenceName: String,
        productID: String,
        kind: InAppPurchaseKind,
        displayName: String,
        reviewNotes: String = ""
    ) {
        self.id = id
        self.referenceName = referenceName
        self.productID = productID
        self.kind = kind
        self.displayName = displayName
        self.reviewNotes = reviewNotes
    }
}

public struct PaymentsActionCatalog: Sendable {
    public init() {}

    public func createProductAction(_ draft: InAppPurchaseDraft) -> LaunchKitAction {
        LaunchKitAction(
            title: "Create in-app purchase \(draft.productID)",
            explanation: "Create or sync an App Store Connect in-app purchase. Product names, pricing, and subscription terms must be reviewed before any live change.",
            category: .revenueLegal,
            risk: .critical,
            isReversible: false,
            rollbackSummary: "App Store Connect product state is limited; avoid creating live products until the draft is approved."
        )
    }
}

