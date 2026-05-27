import Foundation
import LaunchKitCore
import LaunchKitPolicy
import LaunchKitSecrets

public struct AppStoreConnectAPIKey: Codable, Hashable, Sendable {
    public var keyID: String
    public var issuerID: String
    public var privateKeyReference: SecretReference

    public init(keyID: String, issuerID: String, privateKeyReference: SecretReference) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyReference = privateKeyReference
    }
}

public enum AppStoreConnectEndpoint: Sendable {
    case apps
    case builds(appID: String)
    case betaGroups(appID: String)
    case inAppPurchases(appID: String)

    var path: String {
        switch self {
        case .apps:
            return "/v1/apps"
        case let .builds(appID):
            return "/v1/builds?filter[app]=\(appID)"
        case let .betaGroups(appID):
            return "/v1/betaGroups?filter[app]=\(appID)"
        case let .inAppPurchases(appID):
            return "/v2/inAppPurchases?filter[app]=\(appID)"
        }
    }
}

public struct AppStoreConnectRequestFactory: Sendable {
    public var baseURL: URL

    public init(baseURL: URL = URL(string: "https://api.appstoreconnect.apple.com")!) {
        self.baseURL = baseURL
    }

    public func request(endpoint: AppStoreConnectEndpoint, bearerToken: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint.path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

public struct AppStoreConnectActionCatalog: Sendable {
    public init() {}

    public func uploadBuildAction() -> LaunchKitAction {
        LaunchKitAction(
            title: "Upload build to TestFlight",
            explanation: "Send a locally archived build to App Store Connect for TestFlight processing. This does not submit the app for review.",
            category: .riskyWrite,
            risk: .high,
            isReversible: false,
            rollbackSummary: "Uploaded builds cannot be deleted through all App Store Connect flows; expire or ignore the build if needed."
        )
    }

    public func updateMetadataAction(paths: [String]) -> LaunchKitAction {
        LaunchKitAction(
            title: "Update public App Store metadata",
            explanation: "Change customer-visible App Store text or review information.",
            category: .publicFacing,
            risk: .high,
            affectedPaths: paths,
            isReversible: true,
            rollbackSummary: "Restore the previous metadata version and resync after review."
        )
    }
}
