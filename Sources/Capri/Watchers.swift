import AppKit

/// Surveille la souris sans aucune permission, en lisant sa position ~20 fois par seconde.
///
/// Deux rôles :
/// 1. Laisser passer les clics à travers le vide : si la souris est sur un pixel transparent,
///    la fenêtre ignore la souris (`ignoresMouseEvents`), sinon elle la capte.
/// 2. Détecter les caresses : plusieurs allers-retours sur Capri en ~1,5 s, sans bouton appuyé.
@MainActor
final class MouseWatcher {
    /// Doit dire si un point de l'écran tombe sur un pixel visible de Capri.
    var isOverCapri: (NSPoint) -> Bool = { _ in false }
    /// Vrai pendant un clic ou un glisser : la fenêtre doit continuer à recevoir la souris.
    var isMouseHeld: () -> Bool = { false }
    var onPet: () -> Void = {}

    private weak var window: NSWindow?
    private var timer: Timer?

    // Détection des caresses
    private var lastX: CGFloat?
    private var lastDirection: CGFloat = 0
    private var directionChanges: [TimeInterval] = []
    private var lastPetTime: TimeInterval = 0

    init(window: NSWindow) {
        self.window = window
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            // Le Timer tourne sur le fil principal : on le dit à Swift.
            MainActor.assumeIsolated { self?.tick() }
        }
        // Mode « common » : continue pendant qu'un menu est ouvert ou qu'on glisse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let window else { return }
        if isMouseHeld() {
            if window.ignoresMouseEvents { window.ignoresMouseEvents = false }
            return
        }
        let mouse = NSEvent.mouseLocation
        let over = window.frame.contains(mouse) && isOverCapri(mouse)
        // On ne touche à la propriété que si elle change.
        if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }

        if over && NSEvent.pressedMouseButtons == 0 {
            trackPetting(x: mouse.x)
        } else {
            lastX = nil
            directionChanges.removeAll()
        }
    }

    private func trackPetting(x: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastX = x }
        guard let lastX, abs(x - lastX) > 2 else { return }
        let direction: CGFloat = x > lastX ? 1 : -1
        if direction != lastDirection {
            lastDirection = direction
            directionChanges.append(now)
        }
        directionChanges = directionChanges.filter { now - $0 < 1.5 }
        if directionChanges.count >= 4 && now - lastPetTime > 1.0 {
            lastPetTime = now
            directionChanges.removeAll()
            onPet()
        }
    }
}

/// Mesure depuis combien de temps l'utilisateur n'a rien touché (clavier, souris, trackpad).
/// `CGEventSource` donne cette info sans demander de permission.
@MainActor
final class IdleWatcher {
    var sleepAfter: TimeInterval = 180
    var onIdle: () -> Void = {}
    var onActive: () -> Void = {}

    private var timer: Timer?
    private var wasIdle = false

    func start() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static var secondsSinceLastInput: TimeInterval {
        // ~0 = « n'importe quel type d'événement » (kCGAnyInputEventType).
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        let idle = Self.secondsSinceLastInput
        if !wasIdle && idle >= sleepAfter {
            wasIdle = true
            onIdle()
        } else if wasIdle && idle < 1.5 {
            wasIdle = false
            onActive()
        }
    }
}
