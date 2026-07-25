import Foundation

enum SoundSet: String, CaseIterable, Codable, Sendable {
    case woodBlock
    case clave
    case digitalBeep
    case rimShot
    case cowbell

    var label: String {
        switch self {
        case .woodBlock: "Wood Block"
        case .clave: "Clave"
        case .digitalBeep: "Digital Beep"
        case .rimShot: "Rim Shot"
        case .cowbell: "Cowbell"
        }
    }
}
