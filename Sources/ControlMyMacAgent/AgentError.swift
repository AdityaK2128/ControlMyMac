import Foundation
import VideoToolbox

enum AgentError: LocalizedError {
    case permissionDenied
    case noDisplay
    case encoderCreateFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission not granted."
        case .noDisplay:
            return "No display available to capture."
        case .encoderCreateFailed(let status):
            return "Could not create the VideoToolbox compression session (OSStatus \(status))."
        }
    }
}
