import Foundation

enum Subdivision: String, CaseIterable, Codable, Sendable {
    case quarter
    case eighth
    case triplet
    case sixteenth
    case sextuplet

    var count: Int {
        switch self {
        case .quarter: 1
        case .eighth: 2
        case .triplet: 3
        case .sixteenth: 4
        case .sextuplet: 6
        }
    }

    var label: String {
        switch self {
        case .quarter: "Quarter"
        case .eighth: "Eighth"
        case .triplet: "Triplet"
        case .sixteenth: "Sixteenth"
        case .sextuplet: "Sextuplet"
        }
    }
}
