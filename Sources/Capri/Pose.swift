import Foundation

/// Les 13 poses de la planche. La valeur brute est le nom du fichier PNG.
enum Pose: String, CaseIterable {
    case float
    case lounge
    case sleepy
    case sitSwing = "sit_swing"
    case sitCurious = "sit_curious"
    case confused
    case love
    case struggle
    case pull
    case peek
    case juggle
    case hacking
    case handstand
}

/// Les trois tailles proposées dans le menu. La valeur est la hauteur du sprite, en points.
enum PetSize: String, CaseIterable {
    case small, medium, large

    var height: CGFloat {
        switch self {
        case .small: return 110
        case .medium: return 150
        case .large: return 210
        }
    }

    var menuTitle: String {
        switch self {
        case .small: return "Petite"
        case .medium: return "Moyenne"
        case .large: return "Grande"
        }
    }

    /// La taille choisie est gardée entre deux lancements (UserDefaults = petit stockage clé/valeur de macOS).
    static var saved: PetSize {
        get { PetSize(rawValue: UserDefaults.standard.string(forKey: "petSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "petSize") }
    }
}
