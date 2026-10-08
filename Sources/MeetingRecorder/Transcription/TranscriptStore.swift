import Foundation

struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let speaker: String
    /// Seconds since the recording started.
    let start: TimeInterval
    var text: String
    var isFinal: Bool
}

/// Collects transcript segments from both speakers and merges them into one timeline.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment] = []

    func reset() {
        segments.removeAll()
    }

    /// Partial results arrive repeatedly for the same segment; replace in place and keep time order.
    func upsert(_ segment: TranscriptSegment) {
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        } else {
            segments.append(segment)
            segments.sort { $0.start < $1.start }
        }
    }

    func render(title: String) -> String {
        var lines = ["# \(title)", ""]
        for segment in segments where !segment.text.isEmpty {
            lines.append("[\(Self.timestamp(segment.start))] \(segment.speaker): \(segment.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func write(to url: URL, title: String) throws {
        try render(title: title).write(to: url, atomically: true, encoding: .utf8)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
