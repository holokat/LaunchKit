import CryptoKit
import Foundation

public enum SHA256Digest {
    public static func hexString(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

