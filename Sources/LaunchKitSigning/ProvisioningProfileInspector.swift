import Foundation
import LaunchKitCore

public struct ProvisioningProfileSummary: Codable, Hashable, Sendable {
    public var name: String?
    public var uuid: String?
    public var teamIdentifier: [String]
    public var applicationIdentifierPrefix: [String]
    public var expirationDate: Date?
    public var entitlements: [String: String]

    public init(
        name: String?,
        uuid: String?,
        teamIdentifier: [String],
        applicationIdentifierPrefix: [String],
        expirationDate: Date?,
        entitlements: [String: String]
    ) {
        self.name = name
        self.uuid = uuid
        self.teamIdentifier = teamIdentifier
        self.applicationIdentifierPrefix = applicationIdentifierPrefix
        self.expirationDate = expirationDate
        self.entitlements = entitlements
    }

    public var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate <= Date()
    }
}

public struct ProvisioningProfileInspector: Sendable {
    public init() {}

    public func summarize(decodedPropertyList data: Data) throws -> ProvisioningProfileSummary {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let entitlements = dictionary["Entitlements"] as? [String: Any] ?? [:]
        let flattenedEntitlements = entitlements.reduce(into: [String: String]()) { partialResult, item in
            partialResult[item.key] = String(describing: item.value)
        }

        return ProvisioningProfileSummary(
            name: dictionary["Name"] as? String,
            uuid: dictionary["UUID"] as? String,
            teamIdentifier: dictionary["TeamIdentifier"] as? [String] ?? [],
            applicationIdentifierPrefix: dictionary["ApplicationIdentifierPrefix"] as? [String] ?? [],
            expirationDate: dictionary["ExpirationDate"] as? Date,
            entitlements: flattenedEntitlements
        )
    }

    public func findings(
        for profile: ProvisioningProfileSummary,
        requiredEntitlements: Set<String>
    ) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []

        if profile.isExpired {
            findings.append(DiagnosticFinding(
                title: "Provisioning profile is expired",
                explanation: "The selected provisioning profile can no longer sign archives accepted by Apple.",
                severity: .blocker,
                risk: .high,
                recommendedFix: "Regenerate the profile for the selected Apple Developer team."
            ))
        }

        let available = Set(profile.entitlements.keys)
        let missing = requiredEntitlements.subtracting(available)
        if !missing.isEmpty {
            findings.append(DiagnosticFinding(
                title: "Provisioning profile is missing required capabilities",
                explanation: "The app enables capabilities that are not present in the selected signing profile: \(missing.sorted().joined(separator: ", ")).",
                severity: .blocker,
                risk: .high,
                recommendedFix: "Enable the capabilities for the bundle ID and issue a new provisioning profile."
            ))
        }

        return findings
    }
}

