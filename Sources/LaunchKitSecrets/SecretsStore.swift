import Foundation
import LaunchKitCore
import Security

public enum SecretKind: String, Codable, CaseIterable, Sendable {
    case appStoreConnectPrivateKey
    case aiProviderToken
    case signingIdentityReference
    case paymentProviderToken
    case repositoryBookmark
}

public enum SecretUsePurpose: String, Codable, CaseIterable, Sendable {
    case signAppStoreConnectJWT
    case callAIProvider
    case runApprovedSigningWorkflow
    case callPaymentProvider
    case accessRepository
    case exportSecret
    case deleteSecret
}

public enum SecretAccessPolicy: String, Codable, CaseIterable, Sendable {
    case backgroundAfterFirstUnlockThisDeviceOnly
    case interactiveUserPresence
    case destructiveOrExportRequiresReauth
}

public enum SecretDeleteMode: String, Codable, CaseIterable, Sendable {
    case launchKitOwnedOnly
    case explicitUserSelectedIdentity
}

public struct SecretReference: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SecretKind
    public var keychainService: String
    public var account: String
    public var fingerprint: String?

    public init(
        id: String = UUID().uuidString,
        kind: SecretKind,
        keychainService: String,
        account: String,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.keychainService = keychainService
        self.account = account
        self.fingerprint = fingerprint
    }
}

public struct SecretMaterial: Sendable {
    public var kind: SecretKind
    public var data: Data
    public var label: String

    public init(kind: SecretKind, data: Data, label: String) {
        self.kind = kind
        self.data = data
        self.label = label
    }
}

public struct SecretHandle: Sendable {
    public var reference: SecretReference
    public var data: Data

    public init(reference: SecretReference, data: Data) {
        self.reference = reference
        self.data = data
    }
}

public protocol SecretsStore: Sendable {
    func save(_ secret: SecretMaterial, policy: SecretAccessPolicy) async throws -> SecretReference
    func resolve(_ reference: SecretReference, purpose: SecretUsePurpose) async throws -> SecretHandle
    func rotate(_ reference: SecretReference, replacement: SecretMaterial) async throws -> SecretReference
    func delete(_ reference: SecretReference, mode: SecretDeleteMode) async throws
}

public enum SecretsStoreError: Error, LocalizedError, Sendable {
    case keychainStatus(OSStatus)
    case unsupportedDeleteMode

    public var errorDescription: String? {
        switch self {
        case let .keychainStatus(status):
            return "Keychain operation failed with status \(status)."
        case .unsupportedDeleteMode:
            return "This secret cannot be deleted without explicit user selection."
        }
    }
}

public actor KeychainSecretsStore: SecretsStore {
    private let servicePrefix: String

    public init(servicePrefix: String = "com.launchkit.secrets") {
        self.servicePrefix = servicePrefix
    }

    public func save(_ secret: SecretMaterial, policy: SecretAccessPolicy) async throws -> SecretReference {
        let reference = SecretReference(
            kind: secret.kind,
            keychainService: servicePrefix,
            account: "\(secret.kind.rawValue).\(UUID().uuidString)",
            fingerprint: SHA256Digest.hexString(for: secret.data)
        )

        var query: [String: Any] = baseQuery(reference)
        query[kSecValueData as String] = secret.data
        query[kSecAttrLabel as String] = secret.label
        query[kSecAttrAccessible as String] = accessibility(for: policy)
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretsStoreError.keychainStatus(status) }
        return reference
    }

    public func resolve(_ reference: SecretReference, purpose: SecretUsePurpose) async throws -> SecretHandle {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw SecretsStoreError.keychainStatus(status) }
        guard let data = result as? Data else { throw SecretsStoreError.keychainStatus(errSecDecode) }
        return SecretHandle(reference: reference, data: data)
    }

    public func rotate(_ reference: SecretReference, replacement: SecretMaterial) async throws -> SecretReference {
        let newReference = try await save(replacement, policy: .interactiveUserPresence)
        try await delete(reference, mode: .launchKitOwnedOnly)
        return newReference
    }

    public func delete(_ reference: SecretReference, mode: SecretDeleteMode) async throws {
        guard mode == .launchKitOwnedOnly else { throw SecretsStoreError.unsupportedDeleteMode }
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(_ reference: SecretReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.keychainService,
            kSecAttrAccount as String: reference.account
        ]
    }

    private func accessibility(for policy: SecretAccessPolicy) -> CFString {
        switch policy {
        case .backgroundAfterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .interactiveUserPresence, .destructiveOrExportRequiresReauth:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

public struct SecretRedactor: Sendable {
    public init() {}

    public func redact(_ value: String) -> String {
        var redacted = value
        for pattern in sensitivePatterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "$1<redacted>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return redacted
    }

    private var sensitivePatterns: [String] {
        [
            "(authorization:\\s*bearer\\s+)[A-Za-z0-9._\\-]+",
            "(api[_-]?key\\s*[=:]\\s*)[^\\s]+",
            "(token\\s*[=:]\\s*)[^\\s]+",
            "(password\\s*[=:]\\s*)[^\\s]+",
            "(-----BEGIN [A-Z ]*PRIVATE KEY-----)[\\s\\S]*(-----END [A-Z ]*PRIVATE KEY-----)"
        ]
    }
}

