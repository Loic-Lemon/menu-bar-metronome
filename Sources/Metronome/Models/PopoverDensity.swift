import Foundation

enum PopoverDensity: String, CaseIterable, Codable, Sendable {
    case compact
    case spacious

    var label: String { rawValue.capitalized }

    var width: CGFloat {
        switch self {
        case .compact: 280
        case .spacious: 340
        }
    }
}
