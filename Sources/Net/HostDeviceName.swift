import Darwin
import Foundation
#if !targetEnvironment(macCatalyst)
import UIKit
#endif

/// Resolves the human-readable host name for Bonjour advertising and pairing UI.
enum HostDeviceName {
    static var current: String {
        #if targetEnvironment(macCatalyst)
        catalystName()
        #else
        UIDevice.current.name
        #endif
    }

    /// Bonjour service names must be valid DNS host labels.
    static var bonjourServiceName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        var sanitized = current.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        while sanitized.first == "-" { sanitized.removeFirst() }
        while sanitized.last == "-" { sanitized.removeLast() }
        let name = String(sanitized)
        if name.isEmpty { return "FWPlayer" }
        return String(name.prefix(63))
    }

    #if targetEnvironment(macCatalyst)
    private static func catalystName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if gethostname(&buffer, buffer.count) == 0 {
            let raw = String(cString: buffer)
            let base = raw.split(separator: ".").first.map(String.init) ?? raw
            if !base.isEmpty, base != "localhost" {
                return base
            }
        }

        let host = ProcessInfo.processInfo.hostName
        let base = host.split(separator: ".").first.map(String.init) ?? host
        return base.isEmpty ? "Mac" : base
    }
    #endif
}
