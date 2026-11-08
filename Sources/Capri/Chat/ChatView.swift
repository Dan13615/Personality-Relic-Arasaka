import SwiftUI

/// Les couleurs de Capri, prélevées sur ses sprites puis « néonisées ».
enum Theme {
    static let magenta = Color(red: 0.95, green: 0.12, blue: 0.52)   // ses cheveux
    static let green = Color(red: 0.10, green: 0.92, blue: 0.48)     // sa peau
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)      // erreurs
    static let background = Color(red: 0.04, green: 0.03, blue: 0.08)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.55)

    /// SF Mono, la police à chasse fixe du système.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// De quel côté de la bulle part la petite pointe, et à quelle position le long de ce bord.
struct BubbleTail: Equatable {
    enum Edge { case bottom, left, right }
    var edge: Edge = .bottom
    /// Position de la pointe le long du bord, en points depuis la gauche (bas) ou depuis le haut (côtés).
    /// Une valeur négative = au milieu du bord.
    var position: CGFloat = -1
    static let length: CGFloat = 12
}

/// Une forme de bulle de BD : rectangle arrondi + pointe vers Capri, en un seul contour.
struct BubbleShape: Shape {
    var tail: BubbleTail
    var radius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let t = BubbleTail.length, half: CGFloat = 9, r = radius
        // Le corps de la bulle laisse la place à la pointe sur son bord.
        var body = rect
        switch tail.edge {
        case .bottom: body.size.height -= t
        case .left: body.origin.x += t; body.size.width -= t
        case .right: body.size.width -= t
        }
        func clampX(_ x: CGFloat) -> CGFloat { x < 0 ? body.midX : min(max(x, body.minX + r + half), body.maxX - r - half) }
        func clampY(_ y: CGFloat) -> CGFloat { y < 0 ? body.midY : min(max(y, body.minY + r + half), body.maxY - r - half) }

        // On fait le tour dans le sens des aiguilles d'une montre, en ajoutant la pointe au bon endroit.
        var p = Path()
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        if tail.edge == .right {
            let y = clampY(tail.position)
            p.addLine(to: CGPoint(x: body.maxX, y: y - half))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
            p.addLine(to: CGPoint(x: body.maxX, y: y + half))
        }
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        if tail.edge == .bottom {
            let x = clampX(tail.position)
            p.addLine(to: CGPoint(x: x + half, y: body.maxY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x - half, y: body.maxY))
        }
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        if tail.edge == .left {
            let y = clampY(tail.position)
            p.addLine(to: CGPoint(x: body.minX, y: y + half))
            p.addLine(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: body.minX, y: y - half))
        }
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// Le fond commun aux bulles : sombre, translucide, bordure néon qui brille un peu.
struct NeonBubbleBackground: View {
    var tail: BubbleTail
    var body: some View {
        let shape = BubbleShape(tail: tail)
        shape.fill(.ultraThinMaterial)
            .overlay(shape.fill(Theme.background.opacity(0.82)))
            .overlay(shape.stroke(Theme.magenta.opacity(0.9), lineWidth: 1.2))
            .shadow(color: Theme.magenta.opacity(0.55), radius: 6)
    }
}

/// Marges intérieures, plus grandes du côté de la pointe.
extension BubbleTail {
    var insets: EdgeInsets {
        EdgeInsets(top: 0, leading: edge == .left ? Self.length : 0,
                   bottom: edge == .bottom ? Self.length : 0, trailing: edge == .right ? Self.length : 0)
    }
}

/// Mise en page de la bulle (position de la pointe), modifiée par le contrôleur quand Capri bouge.
final class BubbleLayout: ObservableObject {
    @Published var tail = BubbleTail()
}

// MARK: - La bulle de discussion

/// La fenêtre de discussion, façon terminal de netrunner.
struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var layout: BubbleLayout
    var brainName: String
    var onClose: () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.magenta.opacity(0.35)).frame(height: 1)
            history
            Rectangle().fill(Theme.magenta.opacity(0.35)).frame(height: 1)
            inputBar
        }
        .padding(layout.tail.insets)
        .background(NeonBubbleBackground(tail: layout.tail))
        .padding(8)                              // place pour le halo néon
        .onAppear { inputFocused = true }
        .onChange(of: model.focusRequest) { inputFocused = true }
        .onExitCommand(perform: onClose)         // Échap
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.green).frame(width: 6, height: 6).shadow(color: Theme.green, radius: 3)
            Text("CAPRI://netlink").font(Theme.mono(11, .bold)).foregroundStyle(Theme.green)
            Text("· \(brainName.lowercased())").font(Theme.mono(10)).foregroundStyle(Theme.dim)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.dim)
            .help("Fermer (Échap)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        Text("> connexion établie.\n> dis-moi tout, je suis toute à toi.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.dim)
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if model.isWaitingFirstWords {
                        TypingIndicator()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            // Défile tout en bas à chaque nouveau morceau de texte.
            .onChange(of: model.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text(">").font(Theme.mono(13, .bold)).foregroundStyle(Theme.magenta)
            TextField("Parle à Capri…", text: $model.input)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text)
                .focused($inputFocused)
                .onSubmit { model.send() }   // Entrée
            if model.isAnswering {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                        .padding(6)
                        .background(Circle().stroke(Theme.magenta, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.magenta)
                .help("Arrêter la réponse")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.input.isEmpty ? Theme.dim : Theme.green)
                .disabled(model.input.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Une ligne de l'historique : Capri à gauche en vert, Daniil à droite en magenta, erreurs en ambre.
struct MessageRow: View {
    let message: ChatModel.Message

    /// Interprète le Markdown simple (`code`, **gras**, *italique*) en gardant les retours à la ligne.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        switch message.role {
        case .capri:
            VStack(alignment: .leading, spacing: 3) {
                Text("capri").font(Theme.mono(9, .bold)).foregroundStyle(Theme.green.opacity(0.8))
                Text(Self.markdown(message.text))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.green).frame(width: 2).shadow(color: Theme.green, radius: 2)
            }
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.magenta.opacity(0.22)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.magenta.opacity(0.6), lineWidth: 1))
            }
        case .error:
            VStack(alignment: .leading, spacing: 3) {
                Text("⚠ " + message.text).font(Theme.mono(12)).foregroundStyle(Theme.amber)
                if let detail = message.detail {
                    Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.dim).textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// « capri tape… » avec un curseur qui clignote.
struct TypingIndicator: View {
    @State private var on = true
    var body: some View {
        HStack(spacing: 4) {
            Text("capri tape").font(Theme.mono(11)).foregroundStyle(Theme.dim)
            Rectangle().fill(Theme.green).frame(width: 7, height: 12).opacity(on ? 1 : 0.15)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on = false }
        }
    }
}

// MARK: - Petite bulle de réplique

/// La petite bulle des répliques « maison » (caresse, chute…). Pointe vers le bas.
struct SpeechBubbleView: View {
    let text: String
    var tail = BubbleTail(edge: .bottom)

    var body: some View {
        Text(text)
            .font(Theme.mono(11, .medium))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 200)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .padding(tail.insets)
            .background(NeonBubbleBackground(tail: tail))
            .padding(8)
    }
}
