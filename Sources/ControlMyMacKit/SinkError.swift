import Foundation

public enum SinkError: LocalizedError {
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writerFailed(let detail): return "Sink failed: \(detail)"
        }
    }
}
