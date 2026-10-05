import Foundation
import Security

/// A signed bundle's identity: its main executable's CDHash, as `codesign -dvvv` prints it (`CDHash=`).
public enum CodeIdentity {
    /// 40 lowercase hex digits (`kSecCodeInfoUnique`), or nil when `bundle` is missing or unsigned.
    /// Reads the code directory only; it doesn't validate the bundle's resources.
    public static func of(_ bundle: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
