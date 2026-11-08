import AppKit
import SwiftUI

/// Le panneau de la discussion. Contrairement à celui de Capri, il PEUT recevoir le clavier :
/// sinon impossible de taper un message.
///
/// Astuce : c'est un panneau « non-activating » qui peut quand même devenir la fenêtre clé
/// (comme Spotlight). Il reçoit le clavier SANS que Capri devienne l'app active : l'app que tu
/// utilisais reste au premier plan, et retrouve naturellement le focus quand la bulle se ferme.
/// (Activer l'app avec `NSApp.activate()` ne marche pas toujours : depuis macOS 14, le système
/// peut refuser si la demande ne vient pas directement d'un clic dans une fenêtre normale.)
final class ChatPanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // le halo néon est dessiné par SwiftUI
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    // Échap, quand le champ de texte ne l'a pas déjà utilisée.
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// Ouvre, ferme et place la bulle de discussion au-dessus de Capri (ou à côté, si elle est trop haut).
@MainActor
final class ChatWindowController {
    let model: ChatModel
    private let layout = BubbleLayout()
    private let panel = ChatPanel()
    private var brainName: () -> String
    var onClose: () -> Void = {}

    static let contentSize = CGSize(width: 340, height: 400)
    static let margin: CGFloat = 8          // place pour le halo néon autour de la bulle

    var isOpen: Bool { panel.isVisible }

    init(model: ChatModel, brainName: @escaping () -> String) {
        self.model = model
        self.brainName = brainName
        panel.onCancel = { [weak self] in self?.close() }
        rebuildContent()
    }

    /// (Re)crée la vue SwiftUI, par exemple après un changement de cerveau.
    func rebuildContent() {
        let view = ChatView(model: model, layout: layout, brainName: brainName()) { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: view)
    }

    func toggle(near sprite: CGRect, on screen: NSScreen) {
        if isOpen { close() } else { open(near: sprite, on: screen) }
    }

    func open(near sprite: CGRect, on screen: NSScreen) {
        guard !isOpen else { return }
        place(near: sprite, on: screen)
        panel.makeKeyAndOrderFront(nil)   // fenêtre clé : le clavier arrive dans la bulle
        model.focusRequest += 1
        log.info("Bulle ouverte (fenêtre clé : \(self.panel.isKeyWindow, privacy: .public))")
    }

    func close() {
        guard isOpen else { return }
        panel.orderOut(nil)
        onClose()
    }

    /// Place la bulle par rapport au rectangle de Capri (coordonnées écran).
    func place(near sprite: CGRect, on screen: NSScreen) {
        let (frame, tail) = BubblePlacement.frame(content: Self.contentSize, near: sprite, on: screen)
        if layout.tail != tail { layout.tail = tail }
        panel.setFrame(frame, display: true)
    }
}

/// Calcule où mettre une bulle par rapport à Capri : au-dessus si possible, sinon à côté.
@MainActor
enum BubblePlacement {
    static func frame(content size: CGSize, near sprite: CGRect, on screen: NSScreen,
                      preferBeside: Bool = false) -> (CGRect, BubbleTail) {
        let area = screen.visibleFrame
        let m = ChatWindowController.margin, t = BubbleTail.length
        var frame = CGRect.zero
        var tail = BubbleTail()

        // La pointe vise le haut de sa tête.
        let tipAbove = CGPoint(x: sprite.midX, y: sprite.maxY - sprite.height * 0.06)
        if !preferBeside && tipAbove.y + t + size.height + m <= area.maxY {
            // Assez de place au-dessus : bulle au-dessus, pointe en bas.
            frame.size = CGSize(width: size.width + 2 * m, height: size.height + t + 2 * m)
            frame.origin.x = min(max(tipAbove.x - frame.width / 2, area.minX), area.maxX - frame.width)
            frame.origin.y = tipAbove.y - m
            tail = BubbleTail(edge: .bottom, position: tipAbove.x - (frame.minX + m))
        } else {
            // Trop haut : bulle à côté, du côté où il y a de la place.
            frame.size = CGSize(width: size.width + t + 2 * m, height: size.height + 2 * m)
            let tipY = sprite.minY + sprite.height * 0.7
            frame.origin.y = min(max(tipY - frame.height / 2, area.minY), area.maxY - frame.height)
            let rightTip = sprite.midX + sprite.width * 0.25
            if rightTip + frame.width - m <= area.maxX {
                frame.origin.x = rightTip - m
                tail.edge = .left
            } else {
                frame.origin.x = sprite.midX - sprite.width * 0.25 - frame.width + m
                tail.edge = .right
            }
            tail.position = (frame.maxY - m) - tipY   // depuis le haut de la bulle
        }
        return (frame, tail)
    }
}

/// La bulle de notification d'agenda, à côté de Capri quand elle s'est téléportée en haut à gauche.
@MainActor
final class NotificationWindowController {
    static let width: CGFloat = 300
    private let panel = ChatPanel()
    private let layout = BubbleLayout()
    var isVisible: Bool { panel.isVisible }

    init() {
        panel.onCancel = {}
    }

    func show(text: String, time: String, buttons: [ChatButton], near sprite: CGRect, on screen: NSScreen) {
        // On mesure d'abord la bulle (hauteur selon le texte), puis on la place à côté de Capri.
        let measure = NSHostingView(rootView: NotificationBubbleView(text: text, time: time, buttons: buttons, layout: BubbleLayout()))
        let fitting = measure.fittingSize
        // (mesurée avec la pointe en bas : on retire la marge et la pointe pour garder le contenu seul)
        let content = CGSize(width: Self.width,
                             height: fitting.height - 2 * ChatWindowController.margin - BubbleTail.length)
        let (frame, tail) = BubblePlacement.frame(content: content, near: sprite, on: screen, preferBeside: true)
        layout.tail = tail
        panel.contentView = NSHostingView(rootView: NotificationBubbleView(text: text, time: time, buttons: buttons, layout: layout))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func follow(sprite: CGRect, on screen: NSScreen) {
        guard panel.isVisible else { return }
        let content = CGSize(width: Self.width, height: panel.frame.height - 2 * ChatWindowController.margin)
        let (frame, tail) = BubblePlacement.frame(content: content, near: sprite, on: screen, preferBeside: true)
        if layout.tail != tail { layout.tail = tail }
        panel.setFrame(frame, display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// La petite bulle des répliques « maison » : elle apparaît 2 à 3 secondes au-dessus de Capri.
/// Elle ne capte jamais la souris.
@MainActor
final class SpeechBubbleController {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func say(_ text: String, above sprite: CGRect, on screen: NSScreen, duration: TimeInterval = 2.6) {
        let host = NSHostingView(rootView: SpeechBubbleView(text: text))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        follow(sprite: sprite, on: screen)
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Suit Capri si elle bouge pendant qu'elle parle.
    func follow(sprite: CGRect, on screen: NSScreen) {
        guard panel.contentView != nil else { return }
        let size = panel.frame.size
        let area = screen.visibleFrame
        let x = min(max(sprite.midX - size.width / 2, area.minX), area.maxX - size.width)
        let y = min(sprite.maxY - sprite.height * 0.06 - ChatWindowController.margin, area.maxY - size.height)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}
