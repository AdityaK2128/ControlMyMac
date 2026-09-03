import ControlMyMacKit
import Foundation

/// Reads the local Tailscale daemon's view of the world.
///
/// The setup screen needs to answer one question — "what do I type into
/// the iPhone?" — and the honest answer depends on whether Tailscale is
/// even up. Shelling out to the CLI is the cheapest way to know: it
/// talks to the same local daemon the menu bar app does, needs no
/// entitlement, and returns immediately.
struct TailscaleStatus {

    enum State: Equatable {
        case running
        case stopped
        case needsLogin
        case notInstalled
        case unknown(String)
    }

    var state: State = .unknown("not checked yet")
    /// MagicDNS name, trailing dot stripped. The nicest thing to type.
    var dnsName: String?
    var ipv4: String?
    var health: [String] = []

    var isUsable: Bool { state == .running && (dnsName != nil || ipv4 != nil) }

    /// What to type into the iPhone. Prefers the DNS name because it
    /// survives the tailnet handing out a different address.
    var preferredHost: String? { dnsName ?? ipv4 }

    var summary: String {
        switch state {
        case .running:      return "Connected"
        case .stopped:      return "Tailscale is switched off"
        case .needsLogin:   return "Tailscale needs you to log in"
        case .notInstalled: return "Tailscale is not installed"
        case .unknown(let why): return why
        }
    }

    // MARK: - Probing

    /// Homebrew, the App Store app, and a manual install all put the CLI
    /// somewhere different.
    private static let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    static func binaryPath() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func probe() -> TailscaleStatus {
        var result = TailscaleStatus()

        guard let path = binaryPath() else {
            result.state = .notInstalled
            return result
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            result.state = .unknown("could not run tailscale: \(error.localizedDescription)")
            return result
        }

        // readDataToEndOfFile before waitUntilExit: the other order
        // deadlocks if the child fills the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            result.state = .unknown("tailscale returned nothing readable")
            return result
        }

        result.health = (root["Health"] as? [String]) ?? []

        if let selfNode = root["Self"] as? [String: Any] {
            if let dns = selfNode["DNSName"] as? String, !dns.isEmpty {
                result.dnsName = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
            }
        }
        if let ips = root["TailscaleIPs"] as? [String] {
            result.ipv4 = ips.first { !$0.contains(":") }
        }

        switch root["BackendState"] as? String {
        case "Running":       result.state = .running
        case "Stopped":       result.state = .stopped
        case "NeedsLogin",
             "NoState":       result.state = .needsLogin
        case "NeedsMachineAuth":
            result.state = .unknown("this machine is waiting for tailnet approval")
        case "Starting":      result.state = .unknown("Tailscale is starting")
        case let other?:      result.state = .unknown("Tailscale state: \(other)")
        case nil:             result.state = .unknown("Tailscale did not report a state")
        }

        return result
    }
}
