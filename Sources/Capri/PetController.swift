import AppKit
import SpriteKit
import os

let log = Logger(subsystem: "com.dan13615.capri", category: "pet")

/// Le chef d'orchestre : il relie la machine à états (le « cerveau »), la scène (l'affichage)
/// et la fenêtre (la position à l'écran). Il gère aussi les déplacements et la souris.
@MainActor
final class PetController: NSObject, @preconcurrency SKSceneDelegate {
    // (@preconcurrency : SpriteKit appelle `update` sur le fil principal, mais son protocole ne le déclare pas.)
    let machine = BehaviorMachine()
    private let library: SpriteLibrary
    private let panel = PetPanel()
    private let view: PetView
    private let scene: PetScene
    private let mouseWatcher: MouseWatcher
    private let idleWatcher = IdleWatcher()

    /// Fournit le menu (clic droit). C'est `CapriMenu` qui le construit.
    var menuProvider: (() -> NSMenu)?

    private(set) var size: PetSize = .saved

    // MARK: Position
    /// Les pieds de Capri, en coordonnées écran (origine en bas à gauche de l'écran principal).
    /// Tout le reste (la fenêtre, le sol…) est calculé à partir de ce point.
    private var feet = CGPoint.zero
    private var screen: NSScreen
    private var facingRight = true
    private var velocity = CGVector.zero
    private var floatTargetX: CGFloat?
    private var lastFrameTime: TimeInterval?

    // MARK: Souris
    private var isMouseDown = false
    private var isDragging = false
    private var pressPoint = CGPoint.zero
    private var grabOffset = CGVector.zero
    private var dragSamples: [(time: TimeInterval, point: CGPoint)] = []

    // MARK: Rendu
    private var sleepRenderingPaused = false
    private var isOccluded = false

    init(library: SpriteLibrary) {
        self.library = library
        self.scene = PetScene(library: library)
        self.view = PetView(frame: .zero)
        self.mouseWatcher = MouseWatcher(window: panel)
        self.screen = NSScreen.main ?? NSScreen.screens[0]
        super.init()
    }

    // MARK: - Géométrie

    /// Taille du sprite en points : la hauteur vient du menu « Taille », la largeur du format du canevas.
    private var spriteSize: CGSize {
        CGSize(width: size.height * library.canvasAspect, height: size.height)
    }

    /// La fenêtre est un peu plus grande que le sprite, pour que les effets (sauts, cœurs, glitch) y tiennent.
    /// Son bord bas est pile au niveau des pieds : ce qui descend plus bas (peek) n'est pas dessiné.
    private var windowSize: CGSize {
        CGSize(width: (spriteSize.width * 1.5).rounded(), height: (spriteSize.height * 1.35).rounded())
    }

    /// Le sol : le bas de la zone utile de l'écran, juste au-dessus du Dock.
    private var ground: CGFloat { screen.visibleFrame.minY }

    /// Les positions x possibles sur l'écran actuel, sans dépasser des bords.
    private var xRange: ClosedRange<CGFloat> {
        let half = spriteSize.width * 0.4
        let area = screen.visibleFrame
        return (area.minX + half)...(area.maxX - half)
    }

    private func x(forFraction fraction: Double) -> CGFloat {
        xRange.lowerBound + CGFloat(fraction) * (xRange.upperBound - xRange.lowerBound)
    }

    private func moveWindow() {
        panel.setFrameOrigin(CGPoint(x: (feet.x - windowSize.width / 2).rounded(), y: feet.y.rounded()))
    }

    private func applySize() {
        panel.setContentSize(windowSize)
        scene.layout(spriteSize: spriteSize, feet: CGPoint(x: windowSize.width / 2, y: 0))
        moveWindow()
    }

    /// L'écran sous un point, ou le plus proche si le point tombe entre deux écrans.
    private func screenFor(_ point: CGPoint) -> NSScreen {
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return hit }
        return NSScreen.screens.min { distance(point, $0.frame) < distance(point, $1.frame) } ?? screen
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    // MARK: - Démarrage

    func start() {
        view.allowsTransparency = true
        view.controller = self
        view.ignoresSiblingOrder = true
        scene.delegate = self
        feet = CGPoint(x: CGFloat.random(in: xRange), y: ground)
        applySize()                  // la fenêtre a sa taille avant de recevoir la vue
        panel.contentView = view
        view.presentScene(scene)
        panel.orderFrontRegardless()

        machine.onStateChange = { [weak self] state in self?.enter(state) }

        mouseWatcher.isOverCapri = { [weak self] point in self?.isOverCapri(point) ?? false }
        mouseWatcher.isMouseHeld = { [weak self] in self?.isMouseDown ?? false }
        mouseWatcher.onPet = { [weak self] in self?.machine.pet() }
        mouseWatcher.start()

        idleWatcher.onIdle = { [weak self] in self?.machine.userBecameIdle() }
        idleWatcher.onActive = { [weak self] in self?.machine.userBecameActive() }
        idleWatcher.start()

        observeSystem()
        machine.start()
        log.notice("Capri démarrée (taille \(self.size.rawValue, privacy: .public))")
    }

    // MARK: - Entrée dans un état

    /// Traduit chaque état de la machine en pose + animation.
    private func enter(_ state: PetState) {
        log.info("État : \(String(describing: state), privacy: .public)")
        if state != .sleeping { sleepRenderingPaused = false }
        scene.resetEffects()
        floatTargetX = nil

        switch state {
        case .appearing:
            scene.show(.sitCurious, facingRight: facingRight, glitch: false)
            scene.play(.still)
            scene.glitchIn { [weak self] in self?.machine.activityFinished() }

        case .floating(let fraction):
            // On limite la distance pour que la balade reste courte.
            let target = min(max(x(forFraction: fraction), feet.x - 600), feet.x + 600)
            floatTargetX = target
            facingRight = target >= feet.x
            scene.show(.float, facingRight: facingRight)
            scene.play(.bob)

        case .sitting(let pose):
            scene.show(pose, facingRight: facingRight)
            scene.play(.sway)

        case .lounging:
            scene.show(.lounge, facingRight: facingRight)
            scene.play(.still)

        case .playing:
            scene.show(.juggle, facingRight: facingRight)
            scene.play(.hops)

        case .hacking:
            scene.show(.hacking, facingRight: facingRight)
            scene.play(.typing)

        case .handstand:
            scene.show(.handstand, facingRight: facingRight)
            scene.play(.wobble)

        case .peeking(let fraction):
            // Elle disparaît en glitch, puis ressort du bas de l'écran un peu plus loin.
            let duration = (machine.stateEndsAt ?? 0) - ProcessInfo.processInfo.systemUptime
            scene.glitchOut { [weak self] in
                guard let self else { return }
                self.feet.x = self.x(forFraction: fraction)
                self.moveWindow()
                self.scene.resetEffects()
                self.scene.show(.peek, facingRight: self.facingRight, glitch: false)
                self.scene.play(.still)
                self.scene.peek(totalDuration: duration)
            }

        case .teleporting(let fraction):
            scene.glitchOut { [weak self] in
                guard let self else { return }
                self.feet.x = self.x(forFraction: fraction)
                self.facingRight = .random()
                self.moveWindow()
                self.scene.resetEffects()
                self.scene.setFacing(right: self.facingRight)
                self.scene.glitchIn { [weak self] in self?.machine.activityFinished() }
            }

        case .sleeping:
            scene.show(.sleepy, facingRight: facingRight)
            scene.play(.sleep)
            // Une fois endormie, on met l'affichage en pause : zéro image calculée, zéro CPU.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.machine.state == .sleeping else { return }
                self.sleepRenderingPaused = true
                self.updateRendering()
            }

        case .reacting(let pose):
            scene.show(pose, facingRight: facingRight)
            switch pose {
            case .confused:
                scene.play(.still)
                scene.hop()
            case .struggle:
                scene.play(.shake)
            case .love:
                scene.play(.still)
                scene.bounceWithHearts()
            default:
                scene.play(.sway)
            }

        case .dragged(let shaking):
            scene.show(shaking ? .struggle : .pull, facingRight: facingRight)
            scene.play(shaking ? .shake : .dangle)

        case .falling:
            scene.play(.dangle)
        }
        updateRendering()
    }

    // MARK: - Boucle d'animation

    /// Appelé par SpriteKit avant chaque image.
    func update(_ currentTime: TimeInterval, for scene: SKScene) {
        // Temps écoulé depuis l'image précédente (plafonné, au cas où l'affichage était en pause).
        let dt = min(currentTime - (lastFrameTime ?? currentTime), 1.0 / 15.0)
        lastFrameTime = currentTime
        machine.update()

        switch machine.state {
        case .floating: stepFloat(dt)
        case .falling: stepFall(dt)
        default: break
        }
    }

    /// Lévitation : avance doucement vers la cible, ralentit à l'arrivée.
    private func stepFloat(_ dt: TimeInterval) {
        guard let target = floatTargetX else { return }
        let dx = target - feet.x
        let speed = min(60, abs(dx) * 1.5 + 12)
        let step = speed * CGFloat(dt)
        if abs(dx) <= step {
            feet.x = target
            moveWindow()
            floatTargetX = nil
            machine.activityFinished()
        } else {
            feet.x += dx > 0 ? step : -step
            moveWindow()
        }
    }

    /// Chute : gravité simple, puis écrasement à l'atterrissage.
    private func stepFall(_ dt: TimeInterval) {
        let t = CGFloat(dt)
        velocity.dy -= 2600 * t
        velocity.dx *= pow(0.2, t)    // frottement de l'air
        feet.x += velocity.dx * t
        feet.y += velocity.dy * t
        screen = screenFor(feet)      // si on l'a lâchée sur un autre écran, c'est son sol qui compte
        feet.x = min(max(feet.x, xRange.lowerBound), xRange.upperBound)

        if feet.y <= ground {
            feet.y = ground
            velocity = .zero
            moveWindow()
            machine.landed()          // nouvel état d'abord (il remet les effets à zéro)…
            scene.landingSquash()     // …puis l'écrasement par-dessus
        } else {
            moveWindow()
        }
    }

    // MARK: - Rendu

    /// Images par seconde selon l'activité : beaucoup quand ça bouge vite, peu quand elle est calme.
    private func updateRendering() {
        let fps: Int
        switch machine.state {
        case .dragged, .falling, .teleporting, .appearing, .reacting, .peeking: fps = 60
        case .floating, .playing: fps = 30
        default: fps = 20
        }
        view.preferredFramesPerSecond = fps
        let paused = sleepRenderingPaused || isOccluded
        if view.isPaused != paused {
            view.isPaused = paused
            lastFrameTime = nil
        }
    }

    // MARK: - Souris

    private func isOverCapri(_ screenPoint: NSPoint) -> Bool {
        let point = CGPoint(x: screenPoint.x - panel.frame.minX, y: screenPoint.y - panel.frame.minY)
        return scene.isOpaque(at: point)
    }

    func mouseDown() {
        isMouseDown = true
        isDragging = false
        pressPoint = NSEvent.mouseLocation
        grabOffset = CGVector(dx: pressPoint.x - feet.x, dy: pressPoint.y - feet.y)
        dragSamples = []
    }

    func mouseDragged() {
        let mouse = NSEvent.mouseLocation
        if !isDragging {
            // Quelques points de marge : un clic un peu tremblant reste un clic.
            guard hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) > 4 else { return }
            isDragging = true
            machine.dragBegan()
        }
        feet = CGPoint(x: mouse.x - grabOffset.dx, y: mouse.y - grabOffset.dy)
        moveWindow()

        let now = ProcessInfo.processInfo.systemUptime
        dragSamples.append((now, mouse))
        dragSamples.removeAll { now - $0.time > 0.5 }
        machine.dragShaking(isShaking())
    }

    func mouseUp() {
        isMouseDown = false
        if isDragging {
            isDragging = false
            velocity = releaseVelocity()
            screen = screenFor(feet)
            machine.dragEnded()
        } else {
            handleClick()
        }
    }

    /// LE point d'entrée d'un clic simple sur Capri.
    /// À l'étape 2, c'est ici qu'on ouvrira la bulle de discussion.
    private func handleClick() {
        machine.poke()
    }

    /// Secouée = au moins 2 changements de direction rapides dans la dernière demi-seconde.
    private func isShaking() -> Bool {
        var reversals = 0
        var lastDirection: CGFloat = 0
        for (a, b) in zip(dragSamples, dragSamples.dropFirst()) {
            let dt = b.time - a.time
            guard dt > 0 else { continue }
            let vx = (b.point.x - a.point.x) / CGFloat(dt)
            guard abs(vx) > 900 else { continue }
            let direction: CGFloat = vx > 0 ? 1 : -1
            if lastDirection != 0 && direction != lastDirection { reversals += 1 }
            lastDirection = direction
        }
        return reversals >= 2
    }

    /// Vitesse de la souris au moment du lâcher (adoucie), pour un petit élan.
    private func releaseVelocity() -> CGVector {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = dragSamples.filter { now - $0.time < 0.1 }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return .zero }
        let dt = CGFloat(last.time - first.time)
        let vx = (last.point.x - first.point.x) / dt * 0.4
        let vy = (last.point.y - first.point.y) / dt * 0.4
        return CGVector(dx: vx, dy: min(max(vy, -400), 600))
    }

    func showContextMenu(with event: NSEvent, in view: NSView) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: - Actions du menu

    func toggleCalm() {
        machine.setCalm(!machine.isCalm)
    }

    func toggleSleep() {
        if machine.state == .sleeping { machine.wakeUp() } else { machine.sleepNow() }
    }

    func setSize(_ newSize: PetSize) {
        size = newSize
        PetSize.saved = newSize
        applySize()
    }

    // MARK: - Événements système

    private func observeSystem() {
        let center = NotificationCenter.default
        // Écran branché/débranché, résolution ou Dock modifiés : on recale Capri sur son sol.
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // Fenêtre invisible (écran verrouillé…) : on arrête de dessiner.
        center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isOccluded = !self.panel.occlusionState.contains(.visible)
                self.updateRendering()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isOccluded = true; self?.updateRendering() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isOccluded = false; self?.updateRendering() }
        }
    }

    private func screensChanged() {
        screen = NSScreen.screens.contains(screen) ? screen : (NSScreen.main ?? NSScreen.screens[0])
        guard !isDragging else { return }
        feet.x = min(max(feet.x, xRange.lowerBound), xRange.upperBound)
        if machine.state != .falling { feet.y = ground }
        moveWindow()
    }
}
