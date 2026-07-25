import Foundation

enum TimeSignature: String, CaseIterable, Codable, Sendable {
    case twoFour
    case threeFour
    case fourFour
    case fiveFour
    case sixEight
    case sevenEight
    case twelveEight

    var beatsPerBar: Int {
        switch self {
        case .twoFour: 2
        case .threeFour: 3
        case .fourFour: 4
        case .fiveFour: 5
        case .sixEight: 6
        case .sevenEight: 7
        case .twelveEight: 12
        }
    }

    var beatUnit: Int {
        switch self {
        case .twoFour, .threeFour, .fourFour, .fiveFour: 4
        case .sixEight, .sevenEight, .twelveEight: 8
        }
    }

    var label: String {
        switch self {
        case .twoFour: "2/4"
        case .threeFour: "3/4"
        case .fourFour: "4/4"
        case .fiveFour: "5/4"
        case .sixEight: "6/8"
        case .sevenEight: "7/8"
        case .twelveEight: "12/8"
        }
    }
}
