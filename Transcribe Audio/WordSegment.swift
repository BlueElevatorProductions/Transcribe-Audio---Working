import Foundation

/// A single recognized word and its timing information.
struct WordSegment: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var start: TimeInterval
    var duration: TimeInterval
}
