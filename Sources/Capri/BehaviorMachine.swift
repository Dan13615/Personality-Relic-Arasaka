import Foundation

/// Ce que Capri est en train de faire. Un seul état à la fois.
///
/// Les positions sont des fractions (0 = bord gauche de l'écran, 1 = bord droit) :
/// la machine à états ne connaît rien aux écrans ni aux pixels, c'est le contrôleur qui traduit.
enum PetState: Equatable {
    case appearing                      // apparition au lancement (effet glitch)
    case floating(toFraction: Double)   // lévite vers une autre position
    case sitting(Pose)                  // assise (sitSwing ou sitCurious)
    case lounging                       // accoudée à son bloc de pixels
    case playing                        // jongle avec sa balle
    case hacking                        // tape sur son ordi
    case peeking(atFraction: Double)    // dépasse du bas de l'écran
    case teleporting(toFraction: Double)// disparaît en glitch et réapparaît ailleurs
    case handstand                      // équilibre sur les mains (rare)
    case sleeping                       // l'utilisateur est absent depuis un moment
    case reacting(Pose)                 // courte réaction : clic, caresse, réveil…
    case dragged(shaking: Bool)         // tenue par la souris
    case falling                        // lâchée : elle tombe jusqu'au sol
    // Étape 2 : on ajoutera ici `.thinking` (pose hacking) et `.emoting(Emotion)`.

    /// La pose à afficher pour cet état.
    var pose: Pose {
        switch self {
        case .appearing: return .sitCurious
        case .floating: return .float
        case .sitting(let pose): return pose
        case .lounging: return .lounge
        case .playing: return .juggle
        case .hacking: return .hacking
        case .peeking: return .peek
        case .teleporting: return .float
        case .handstand: return .handstand
        case .sleeping: return .sleepy
        case .reacting(let pose): return pose
        case .dragged(let shaking): return shaking ? .struggle : .pull
        case .falling: return .pull
        }
    }
}

/// Le « cerveau » de Capri : il choisit quoi faire et quand changer d'activité.
///
/// Il ne dessine rien et ne déplace rien : il annonce juste chaque nouvel état
/// via `onStateChange`. Le `PetController` se charge de l'afficher.
/// Cette séparation rend la logique facile à lire (et à faire évoluer à l'étape 2).
final class BehaviorMachine {
    /// Les activités spontanées, avec leur poids dans le tirage au sort.
    private enum Activity: CaseIterable {
        case float, sit, lounge, play, hack, peek, teleport, handstand

        var weight: Int {
            switch self {
            case .float: return 30
            case .sit: return 22
            case .lounge: return 12
            case .play: return 10
            case .hack: return 12
            case .peek: return 6
            case .teleport: return 8
            case .handstand: return 3
            }
        }

        /// En mode « Rester tranquille », seules les activités sur place sont permises.
        var staysInPlace: Bool { self == .sit || self == .lounge || self == .hack }
    }

    private(set) var state: PetState = .appearing
    /// Quand l'état actuel se termine tout seul. `nil` = il attend un événement (arrivée, atterrissage…).
    private(set) var stateEndsAt: TimeInterval?

    /// « Rester tranquille » : elle ne se déplace plus.
    private(set) var isCalm = false
    /// « Dormir » choisi dans le menu : elle ne se réveille pas juste parce que la souris bouge.
    private(set) var isForcedSleep = false

    private var lastActivity: Activity?
    private var pokeTimes: [TimeInterval] = []

    /// Appelé à chaque changement d'état.
    var onStateChange: ((PetState) -> Void)?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Boucle

    func start() {
        transition(to: .appearing, duration: nil)
    }

    /// Appelé à chaque image : passe à l'activité suivante quand le temps est écoulé.
    func update() {
        if let end = stateEndsAt, now >= end {
            chooseNextActivity()
        }
    }

    /// Une activité sans durée fixe est terminée (arrivée à destination, apparition finie…).
    func activityFinished() {
        chooseNextActivity()
    }

    private func chooseNextActivity() {
        let candidates = Activity.allCases.filter { activity in
            (!isCalm || activity.staysInPlace) && activity != lastActivity
        }
        let activity = weightedRandom(candidates)
        lastActivity = activity
        let duration = TimeInterval.random(in: 5...20)

        switch activity {
        case .float: transition(to: .floating(toFraction: .random(in: 0...1)), duration: nil)
        case .sit: transition(to: .sitting(Bool.random() ? .sitSwing : .sitCurious), duration: duration)
        case .lounge: transition(to: .lounging, duration: duration)
        case .play: transition(to: .playing, duration: min(duration, 10))
        case .hack: transition(to: .hacking, duration: duration)
        case .peek: transition(to: .peeking(atFraction: .random(in: 0.1...0.9)), duration: .random(in: 7...11))
        case .teleport: transition(to: .teleporting(toFraction: .random(in: 0...1)), duration: nil)
        case .handstand: transition(to: .handstand, duration: .random(in: 4...7))
        }
    }

    private func weightedRandom(_ activities: [Activity]) -> Activity {
        let total = activities.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<total)
        for activity in activities {
            roll -= activity.weight
            if roll < 0 { return activity }
        }
        return activities[0]
    }

    private func transition(to newState: PetState, duration: TimeInterval?) {
        state = newState
        stateEndsAt = duration.map { now + $0 }
        onStateChange?(newState)
    }

    /// Est-ce qu'elle est en main (ou en chute) ? Dans ce cas, on ne l'interrompt pas.
    private var isHeld: Bool {
        switch state {
        case .dragged, .falling: return true
        default: return false
        }
    }

    // MARK: - Interactions

    /// Clic simple. 3 clics ou plus en 2 secondes : elle se débat.
    func poke() {
        guard !isHeld else { return }
        isForcedSleep = false
        pokeTimes = pokeTimes.filter { now - $0 < 2 } + [now]
        let pose: Pose = pokeTimes.count >= 3 ? .struggle : .confused
        transition(to: .reacting(pose), duration: 1.5)
    }

    /// Caresse (va-et-vient de la souris sur elle).
    func pet() {
        guard !isHeld, state != .sleeping else { return }
        if state == .reacting(.love) {
            stateEndsAt = now + 2   // on prolonge, sans relancer l'animation
        } else {
            transition(to: .reacting(.love), duration: 2)
        }
    }

    func dragBegan() {
        isForcedSleep = false
        transition(to: .dragged(shaking: false), duration: nil)
    }

    func dragShaking(_ shaking: Bool) {
        guard case .dragged(let current) = state, current != shaking else { return }
        transition(to: .dragged(shaking: shaking), duration: nil)
    }

    func dragEnded() {
        transition(to: .falling, duration: nil)
    }

    func landed() {
        transition(to: .sitting(.sitCurious), duration: .random(in: 2...4))
    }

    // MARK: - Sommeil et menu

    /// L'utilisateur n'a rien touché depuis ~3 minutes.
    func userBecameIdle() {
        guard !isHeld, state != .sleeping else { return }
        transition(to: .sleeping, duration: nil)
    }

    /// L'utilisateur est revenu : elle se réveille en sursaut (sauf si on lui a demandé de dormir).
    func userBecameActive() {
        guard state == .sleeping, !isForcedSleep else { return }
        transition(to: .reacting(.confused), duration: 1.2)
    }

    func sleepNow() {
        guard !isHeld else { return }
        isForcedSleep = true
        transition(to: .sleeping, duration: nil)
    }

    func wakeUp() {
        isForcedSleep = false
        if state == .sleeping { transition(to: .reacting(.sitCurious), duration: 1.5) }
    }

    func setCalm(_ calm: Bool) {
        isCalm = calm
        // Si elle était en train de bouger, on passe tout de suite à une activité sur place.
        switch state {
        case .floating, .playing, .peeking, .teleporting, .handstand:
            if calm { chooseNextActivity() }
        default: break
        }
    }
}
