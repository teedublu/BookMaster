import Foundation
import Combine

/// Stand-in for the Python UI's ScrolledText + setup_logging() feedback
/// panel. Phase 1 has no real Master/MasterDraft logic to log from yet,
/// so this only records the UI-level stub actions below — a real
/// os_log/Logger-backed version comes with Phase 2+ once there's actual
/// work happening to report on.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []

    func append(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        lines.append("[\(formatter.string(from: Date()))] \(message)")
    }
}
