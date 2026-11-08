import SpriteKit

/// L'animation « d'ambiance » jouée en continu pendant une activité.
enum Ambient {
    case still      // juste la respiration
    case bob        // lévitation : monte et descend doucement
    case sway       // assise : balancement léger
    case hops       // jongle : petits sauts
    case typing     // tape au clavier : petits rebonds rapides
    case wobble     // équilibre sur les mains : vacille
    case shake      // se débat : tremblement
    case dangle     // tenue par la souris : se balance
    case sleep      // respiration lente
}

/// La scène SpriteKit : elle ne fait QUE l'affichage et les effets.
/// Elle ne décide de rien : c'est `PetController` qui lui dit quoi montrer.
///
/// Arbre des nœuds (chaque niveau a un rôle, ce qui évite que les animations se marchent dessus) :
///
///     scène
///     └─ rig           position des pieds : sauts, lévitation, sortie du bas de l'écran, rotation
///        └─ flip       miroir gauche/droite + écrasements (atterrissage, téléportation)
///           └─ breath  respiration (étirement vertical de 2 %)
///              ├─ sprite      Capri
///              ├─ ghostMagenta / ghostCyan   copies colorées pour l'effet glitch « RGB split »
///
/// Tous ces nœuds ont leur origine aux pieds de Capri : les étirements partent donc du sol.
@MainActor
final class PetScene: SKScene {
    private let library: SpriteLibrary
    private let rig = SKNode()
    private let flip = SKNode()
    private let breath = SKNode()
    private let sprite = SKSpriteNode()
    private let ghostMagenta = SKSpriteNode()
    private let ghostCyan = SKSpriteNode()

    private(set) var currentPose: Pose = .sitCurious
    private(set) var spriteSize = CGSize(width: 100, height: 100)
    private var facingSign: CGFloat = 1
    /// Faux pendant une téléportation : Capri est invisible, donc pas cliquable.
    private(set) var isVisible = true

    private lazy var heartTexture = Self.pixelTexture(pattern: [
        ".XX.XX.",
        "XXXXXXX",
        "XXXXXXX",
        ".XXXXX.",
        "..XXX..",
        "...X...",
    ], color: NSColor(red: 1.0, green: 0.35, blue: 0.7, alpha: 1))

    private lazy var sparkleTexture = Self.pixelTexture(pattern: [
        "..X..",
        "..X..",
        "XXXXX",
        "..X..",
        "..X..",
    ], color: NSColor(red: 1.0, green: 0.6, blue: 0.9, alpha: 1))

    init(library: SpriteLibrary) {
        self.library = library
        super.init(size: CGSize(width: 200, height: 200))
        backgroundColor = .clear
        scaleMode = .resizeFill

        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        // Les copies « fantômes » : teintées et en mode additif, elles créent les franges magenta/cyan.
        for (ghost, color) in [(ghostMagenta, NSColor.magenta), (ghostCyan, NSColor.cyan)] {
            ghost.anchorPoint = CGPoint(x: 0.5, y: 0)
            ghost.color = color
            ghost.colorBlendFactor = 1
            ghost.blendMode = .add
            ghost.alpha = 0
        }
        addChild(rig)
        rig.addChild(flip)
        flip.addChild(breath)
        breath.addChild(ghostMagenta)
        breath.addChild(ghostCyan)
        breath.addChild(sprite)
        setTexture(for: currentPose)
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    // MARK: - Mise en page

    /// Place les pieds de Capri à `feet` (coordonnées de la scène) et règle la taille du sprite.
    func layout(spriteSize: CGSize, feet: CGPoint) {
        self.spriteSize = spriteSize
        for node in [sprite, ghostMagenta, ghostCyan] { node.size = spriteSize }
        rig.position = feet
        rigBase = feet
    }
    private var rigBase = CGPoint.zero

    // MARK: - Poses

    /// Change de pose. Le changement est masqué par un petit scintillement glitch (~120 ms),
    /// pour que la coupure paraisse voulue et pas comme un bug.
    func show(_ pose: Pose, facingRight: Bool, glitch: Bool = true) {
        setFacing(right: facingRight)
        guard pose != currentPose else { return }
        currentPose = pose
        guard glitch else { setTexture(for: pose); return }

        let swap = SKAction.run { [weak self] in self?.setTexture(for: pose) }
        sprite.run(.sequence([
            .run { [weak self] in self?.setGhosts(offset: 3, alpha: 0.7); self?.sprite.position.x = 2 },
            .fadeAlpha(to: 0.5, duration: 0.03),
            swap,
            .run { [weak self] in self?.sprite.position.x = -2; self?.setGhosts(offset: -2, alpha: 0.5) },
            .fadeAlpha(to: 1, duration: 0.03),
            .wait(forDuration: 0.03),
            .run { [weak self] in self?.sprite.position.x = 0; self?.setGhosts(offset: 0, alpha: 0) },
        ]), withKey: "glitch")
    }

    func setFacing(right: Bool) {
        facingSign = right ? 1 : -1
        flip.xScale = facingSign * abs(flip.xScale)
    }

    private func setTexture(for pose: Pose) {
        guard let texture = library.textures[pose] else { return }
        for node in [sprite, ghostMagenta, ghostCyan] { node.texture = texture }
    }

    private func setGhosts(offset: CGFloat, alpha: CGFloat) {
        ghostMagenta.position = CGPoint(x: -offset, y: 0)
        ghostCyan.position = CGPoint(x: offset, y: offset * 0.3)
        ghostMagenta.alpha = alpha
        ghostCyan.alpha = alpha
    }

    // MARK: - Animations d'ambiance

    /// Remet tout à zéro : on l'appelle à chaque nouvel état pour partir d'une base propre.
    func resetEffects() {
        for node in [rig, flip, sprite] { node.removeAllActions() }
        rig.position = rigBase
        rig.zRotation = 0
        flip.xScale = facingSign
        flip.yScale = 1
        sprite.position = .zero
        sprite.alpha = 1
        setGhosts(offset: 0, alpha: 0)
        isVisible = true
    }

    func play(_ ambient: Ambient) {
        // Respiration : toujours là, plus lente quand elle dort.
        let breathTime: TimeInterval = ambient == .sleep ? 2.6 : 1.4
        breath.removeAllActions()
        breath.yScale = 1
        let inhale = SKAction.scaleY(to: 1.02, duration: breathTime)
        let exhale = SKAction.scaleY(to: 1.0, duration: breathTime)
        inhale.timingMode = .easeInEaseOut
        exhale.timingMode = .easeInEaseOut
        breath.run(.repeatForever(.sequence([inhale, exhale])))

        let action: SKAction
        switch ambient {
        case .still, .sleep:
            return
        case .bob:
            // Lévitation : une sinusoïde verticale de 5 points.
            let up = SKAction.moveBy(x: 0, y: 5, duration: 1.0)
            up.timingMode = .easeInEaseOut
            action = .sequence([up, up.reversed()])
        case .sway, .dangle:
            let angle: CGFloat = ambient == .sway ? 0.025 : 0.08
            let time: TimeInterval = ambient == .sway ? 1.6 : 0.7
            let left = SKAction.rotate(toAngle: angle, duration: time)
            let right = SKAction.rotate(toAngle: -angle, duration: time)
            left.timingMode = .easeInEaseOut
            right.timingMode = .easeInEaseOut
            action = .sequence([left, right])
        case .hops:
            action = .sequence([hopAction(height: 8, duration: 0.35), .wait(forDuration: 0.25)])
        case .typing:
            let tap = SKAction.moveBy(x: 0, y: 1.5, duration: 0.08)
            action = .sequence([tap, tap.reversed(), .wait(forDuration: .random(in: 0.05...0.2))])
        case .wobble:
            let left = SKAction.rotate(toAngle: 0.05, duration: 0.5)
            let right = SKAction.rotate(toAngle: -0.05, duration: 0.6)
            left.timingMode = .easeInEaseOut
            right.timingMode = .easeInEaseOut
            action = .sequence([left, right])
        case .shake:
            action = .sequence([
                .moveBy(x: 3, y: 0, duration: 0.03), .moveBy(x: -6, y: 0, duration: 0.06), .moveBy(x: 3, y: 0, duration: 0.03),
            ])
        }
        rig.run(.repeatForever(action), withKey: "ambient")
    }

    // MARK: - Réactions ponctuelles

    private func hopAction(height: CGFloat, duration: TimeInterval) -> SKAction {
        let up = SKAction.moveBy(x: 0, y: height, duration: duration / 2)
        up.timingMode = .easeOut
        let down = SKAction.moveBy(x: 0, y: -height, duration: duration / 2)
        down.timingMode = .easeIn
        return .sequence([up, down])
    }

    /// Petit saut de surprise (clic).
    func hop() {
        rig.run(hopAction(height: 14, duration: 0.3), withKey: "reaction")
    }

    /// Rebonds + petits cœurs (caresse).
    func bounceWithHearts() {
        rig.run(.sequence([hopAction(height: 8, duration: 0.25), hopAction(height: 5, duration: 0.2)]), withKey: "reaction")
        emitHearts(count: 5)
    }

    func emitHearts(count: Int) {
        for i in 0..<count {
            let isHeart = i % 3 != 2
            let particle = SKSpriteNode(texture: isHeart ? heartTexture : sparkleTexture)
            let pixel: CGFloat = spriteSize.height / 75   // un « pixel » de cœur ≈ un pixel du dessin
            particle.size = CGSize(width: particle.texture!.size().width * pixel, height: particle.texture!.size().height * pixel)
            particle.position = CGPoint(x: rig.position.x + .random(in: -0.3...0.3) * spriteSize.width,
                                        y: rig.position.y + .random(in: 0.65...0.95) * spriteSize.height)
            particle.alpha = 0
            addChild(particle)
            let rise = SKAction.moveBy(x: .random(in: -10...10), y: .random(in: 20...35), duration: 1.0)
            rise.timingMode = .easeOut
            particle.run(.sequence([
                .wait(forDuration: Double(i) * 0.12),
                .group([rise, .sequence([.fadeIn(withDuration: 0.1), .wait(forDuration: 0.5), .fadeOut(withDuration: 0.4)])]),
                .removeFromParent(),
            ]))
        }
    }

    /// Écrasement à l'atterrissage, puis retour en place.
    func landingSquash() {
        flip.xScale = facingSign * 1.15
        flip.yScale = 0.8
        let back = SKAction.customAction(withDuration: 0.22) { [weak self] node, elapsed in
            guard let self else { return }
            let t = elapsed / 0.22
            node.xScale = self.facingSign * (1.15 - 0.15 * t)
            node.yScale = 0.8 + 0.2 * t
        }
        back.timingMode = .easeOut
        flip.run(back, withKey: "squash")
    }

    // MARK: - Sortie du bas de l'écran (peek)

    /// Monte doucement depuis le bas de la fenêtre (= le bas de l'écran), reste, puis redescend.
    /// Ce qui dépasse sous la fenêtre n'est simplement pas dessiné : pas besoin de masque.
    func peek(totalDuration: TimeInterval) {
        guard let mask = library.masks[.peek] else { return }
        // Hauteur de la partie visible de la pose (la tête + les mains).
        let visible = spriteSize.height * CGFloat(mask.height - mask.topOpaqueRow) / CGFloat(mask.height)
        rig.position.y = rigBase.y - visible
        let half = SKAction.moveTo(y: rigBase.y - visible * 0.45, duration: 1.6)
        let full = SKAction.moveTo(y: rigBase.y, duration: 1.0)
        let down = SKAction.moveTo(y: rigBase.y - visible, duration: 1.2)
        for a in [half, full, down] { a.timingMode = .easeInEaseOut }
        let stay = max(0.5, totalDuration - 1.6 - 1.0 - 1.2 - 1.0)
        rig.run(.sequence([half, .wait(forDuration: 1.0), full, .wait(forDuration: stay), down]), withKey: "peek")
    }

    // MARK: - Téléportation glitch

    /// Disparition : tremblements, séparation RGB, scintillement, puis écrasement en une ligne horizontale.
    func glitchOut(completion: @escaping () -> Void) {
        let duration = TimeInterval.random(in: 0.3...0.5)
        let squash = SKAction.customAction(withDuration: duration) { [weak self] node, elapsed in
            guard let self else { return }
            let t = pow(elapsed / CGFloat(duration), 2)
            node.xScale = self.facingSign * (1 + 0.5 * t)
            node.yScale = max(0.04, 1 - t)
        }
        flip.run(squash)
        sprite.run(jitter(duration: duration)) { [weak self] in
            guard let self else { return }
            self.sprite.alpha = 0
            self.setGhosts(offset: 0, alpha: 0)
            self.isVisible = false
            completion()
        }
    }

    /// Réapparition : l'effet inverse.
    func glitchIn(completion: @escaping () -> Void) {
        let duration = TimeInterval.random(in: 0.3...0.5)
        isVisible = true
        sprite.alpha = 1
        flip.xScale = facingSign * 1.5
        flip.yScale = 0.04
        let unsquash = SKAction.customAction(withDuration: duration) { [weak self] node, elapsed in
            guard let self else { return }
            let t = 1 - pow(1 - elapsed / CGFloat(duration), 2)
            node.xScale = self.facingSign * (1.5 - 0.5 * t)
            node.yScale = 0.04 + 0.96 * t
        }
        flip.run(unsquash)
        sprite.run(jitter(duration: duration)) { [weak self] in
            self?.sprite.position = .zero
            self?.sprite.alpha = 1
            self?.setGhosts(offset: 0, alpha: 0)
            completion()
        }
    }

    /// Une suite d'images « cassées » : décalages aléatoires, copies colorées, opacité qui saute.
    private func jitter(duration: TimeInterval) -> SKAction {
        let step = 0.04
        let frame = SKAction.run { [weak self] in
            guard let self else { return }
            self.sprite.position.x = .random(in: -4...4)
            self.sprite.alpha = .random(in: 0.35...1)
            self.ghostMagenta.position = CGPoint(x: .random(in: -7 ... -2), y: .random(in: -1...1))
            self.ghostCyan.position = CGPoint(x: .random(in: 2...7), y: .random(in: -1...1))
            self.ghostMagenta.alpha = 0.8
            self.ghostCyan.alpha = 0.8
        }
        return .repeat(.sequence([frame, .wait(forDuration: step)]), count: max(1, Int(duration / step)))
    }

    // MARK: - Test de clic

    /// Le point (coordonnées de la scène) tombe-t-il sur un pixel visible de Capri ?
    /// Sert à laisser passer les clics à travers les zones transparentes de la fenêtre.
    func isOpaque(at point: CGPoint) -> Bool {
        guard isVisible, let mask = library.masks[currentPose] else { return false }
        // `convert` applique à l'envers toutes les transformations (saut, miroir, respiration…).
        let local = sprite.convert(point, from: self)
        let u = local.x / spriteSize.width + 0.5
        let v = local.y / spriteSize.height
        guard (0...1).contains(u), (0...1).contains(v) else { return false }
        let px = Int(u * CGFloat(mask.width)), py = Int((1 - v) * CGFloat(mask.height))
        // On regarde un petit voisinage : plus facile à attraper qu'un pixel isolé.
        for dy in stride(from: -3, through: 3, by: 3) {
            for dx in stride(from: -3, through: 3, by: 3) where mask.isOpaque(x: px + dx, y: py + dy) {
                return true
            }
        }
        return false
    }

    // MARK: - Petites textures pixel art

    private static func pixelTexture(pattern: [String], color: NSColor) -> SKTexture {
        let width = pattern[0].count, height = pattern.count
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            color.setFill()
            for (y, row) in pattern.enumerated() {
                for (x, char) in row.enumerated() where char == "X" {
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest   // garde les pixels nets quand on agrandit
        return texture
    }
}
