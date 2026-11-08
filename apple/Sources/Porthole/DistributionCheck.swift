#if DEBUG
import Foundation
#if os(macOS)
import Security
#endif

/// Refuses to start the harness in a build signed for distribution, as a
/// second guard after `#if DEBUG`, which a custom build configuration can
/// define by mistake.
///
/// A distribution build (App Store, TestFlight, Developer ID) is signed by a
/// team and lacks `com.apple.security.get-task-allow`, the entitlement Xcode
/// adds to Debug builds so a debugger can attach. A Debug build signed by
/// Xcode has it; an ad hoc or unsigned build (`swift run`, Rune, a CI build)
/// has no team and can't be distributed, so it's allowed either way.
enum DistributionCheck {
    /// Why the harness won't start, or nil when it may.
    static func refusal() -> String? {
        #if os(macOS)
        guard let team = teamIdentifier(), !team.isEmpty else { return nil }
        if debuggable() { return nil }
        return "this build is signed for distribution (team \(team), no get-task-allow); Porthole only runs in Debug builds"
        #else
        // Simulator builds can't be distributed, and a device can't reach the
        // hub, so there's nothing to guard on iOS yet.
        return nil
        #endif
    }

    #if os(macOS)
    private static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func debuggable() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.get-task-allow" as CFString, nil)
        return (value as? Bool) == true
    }
    #endif
}
#endif
