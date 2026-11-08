// Outil de découpe de la planche de sprites de Capri.
//
// Usage (depuis la racine du projet) :
//   swift Tools/slice-sprites.swift
//
// Il lit Assets/source/capri-sheet.webp, découpe chaque pose, retire le fond gris,
// et écrit un PNG transparent par pose dans Sources/Capri/Resources/Sprites/,
// plus deux planches d'aperçu (fond clair et fond sombre) dans Assets/preview/.
//
// Pourquoi un script séparé ? Le découpage se fait une seule fois, hors de l'app :
// l'app charge des PNG propres, elle n'a pas à refaire ce travail à chaque lancement.
// Si un jour tu remplaces la planche par une autre, tu relances juste ce script.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Réglages

/// Une pose sur la planche : son nom de fichier et sa boîte (x0, y0, x1, y1), en pixels, origine en haut à gauche.
struct PoseBox {
    let name: String
    let x0: Int, y0: Int, x1: Int, y1: Int
}

let poses: [PoseBox] = [
    PoseBox(name: "float",       x0: 34,  y0: 94,  x1: 205, y1: 334),
    PoseBox(name: "lounge",      x0: 214, y0: 106, x1: 428, y1: 313),
    PoseBox(name: "sleepy",      x0: 438, y0: 111, x1: 627, y1: 320),
    PoseBox(name: "sit_swing",   x0: 643, y0: 98,  x1: 815, y1: 344),
    PoseBox(name: "sit_curious", x0: 817, y0: 101, x1: 999, y1: 337),
    PoseBox(name: "confused",    x0: 50,  y0: 442, x1: 253, y1: 696),
    PoseBox(name: "love",        x0: 303, y0: 450, x1: 475, y1: 675),
    PoseBox(name: "struggle",    x0: 521, y0: 461, x1: 733, y1: 676),
    PoseBox(name: "pull",        x0: 778, y0: 467, x1: 973, y1: 665),
    PoseBox(name: "peek",        x0: 38,  y0: 866, x1: 259, y1: 1005),
    PoseBox(name: "juggle",      x0: 292, y0: 804, x1: 511, y1: 1012),
    PoseBox(name: "hacking",     x0: 527, y0: 814, x1: 742, y1: 1002),
    PoseBox(name: "handstand",   x0: 783, y0: 784, x1: 976, y1: 1020),
]

/// Couleur du fond de la planche, et tolérance pour la reconnaître malgré la compression.
let background = (r: 224, g: 224, b: 224)
let backgroundTolerance = 20
/// Les « poches » de fond enfermées (entre un bras et le corps…) plus grandes que ça sont vidées.
let minPocketSize = 30
/// Les pixels de bord encore proches du gris de fond (le « halo ») sont retirés.
let haloTolerance = 95
/// Marge transparente autour de chaque pose sur le canevas commun.
let canvasPadding = 2

// MARK: - Image en mémoire

/// Une image RGBA toute simple : 4 octets par pixel, ligne 0 en haut.
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = index(x, y)
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }
    func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[index(x, y) + 3] }
    mutating func clear(_ x: Int, _ y: Int) {
        let i = index(x, y)
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    }
}

func loadBitmap(_ url: URL) -> Bitmap {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Impossible de lire \(url.path)")
    }
    var bitmap = Bitmap(width: image.width, height: image.height)
    bitmap.pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bitmap
}

func makeCGImage(_ bitmap: Bitmap) -> CGImage {
    var copy = bitmap.pixels
    return copy.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: bitmap.width, height: bitmap.height,
                                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

func savePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// MARK: - Nettoyage d'une pose

func crop(_ sheet: Bitmap, _ box: PoseBox) -> Bitmap {
    var out = Bitmap(width: box.x1 - box.x0, height: box.y1 - box.y0)
    for y in 0..<out.height {
        for x in 0..<out.width {
            let s = sheet.index(box.x0 + x, box.y0 + y), d = out.index(x, y)
            for c in 0..<4 { out.pixels[d + c] = sheet.pixels[s + c] }
        }
    }
    return out
}

/// Distance « max par canal » entre un pixel et le gris du fond.
func distanceToBackground(_ c: (Int, Int, Int)) -> Int {
    max(abs(c.0 - background.r), abs(c.1 - background.g), abs(c.2 - background.b))
}

/// Parcourt une zone connexe (4 voisins) à partir d'un point, tant que `accept` est vrai.
func floodRegion(_ w: Int, _ h: Int, start: Int, visited: inout [Bool], accept: (Int) -> Bool) -> [Int] {
    var region: [Int] = []
    var stack = [start]
    visited[start] = true
    while let p = stack.popLast() {
        region.append(p)
        let x = p % w, y = p / w
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
            let n = ny * w + nx
            if !visited[n] && accept(n) { visited[n] = true; stack.append(n) }
        }
    }
    return region
}

func removeBackground(_ img: inout Bitmap) {
    let w = img.width, h = img.height
    var isBackground = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w { isBackground[y * w + x] = distanceToBackground(img.rgb(x, y)) <= backgroundTolerance } }

    // 1. Remplissage depuis le bord : tout le fond relié au cadre devient transparent.
    var visited = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w where x == 0 || y == 0 || x == w - 1 || y == h - 1 {
        let p = y * w + x
        if isBackground[p] && !visited[p] {
            for q in floodRegion(w, h, start: p, visited: &visited, accept: { isBackground[$0] }) { img.clear(q % w, q / w) }
        }
    } }

    // 2. Les poches de fond enfermées (trous entre les membres), si elles sont assez grandes.
    for p in 0..<(w * h) where isBackground[p] && !visited[p] {
        let region = floodRegion(w, h, start: p, visited: &visited, accept: { isBackground[$0] })
        if region.count >= minPocketSize { for q in region { img.clear(q % w, q / w) } }
    }

    // 3. Le halo : les pixels de bord gris clair, mélange du dessin et du fond dû à la compression.
    for _ in 0..<3 {
        var toClear: [(Int, Int)] = []
        for y in 0..<h { for x in 0..<w where img.alpha(x, y) > 0 {
            var touchesTransparent = false
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                if nx < 0 || ny < 0 || nx >= w || ny >= h || img.alpha(nx, ny) == 0 { touchesTransparent = true }
            } }
            guard touchesTransparent else { continue }
            let c = img.rgb(x, y)
            let saturation = max(c.0, c.1, c.2) - min(c.0, c.1, c.2)
            if distanceToBackground(c) <= haloTolerance && saturation < 70 { toClear.append((x, y)) }
        } }
        for (x, y) in toClear { img.clear(x, y) }
    }
}

/// Retire les bouts des poses voisines : les petits morceaux qui touchent le cadre de découpe.
/// Les petits éléments isolés au milieu (zzz, « ? », étincelles, balle…) sont gardés.
func removeSlivers(_ img: inout Bitmap) {
    let w = img.width, h = img.height
    var visited = [Bool](repeating: false, count: w * h)
    var components: [[Int]] = []
    for p in 0..<(w * h) where !visited[p] && img.pixels[p * 4 + 3] > 0 {
        // Ici 8 voisins : un trait fin en diagonale reste un seul morceau.
        var region: [Int] = []
        var stack = [p]
        visited[p] = true
        while let q = stack.popLast() {
            region.append(q)
            let x = q % w, y = q / w
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let n = ny * w + nx
                if !visited[n] && img.pixels[n * 4 + 3] > 0 { visited[n] = true; stack.append(n) }
            } }
        }
        components.append(region)
    }
    let largest = components.map(\.count).max() ?? 0
    for region in components {
        let touchesBorder = region.contains { q in let x = q % w, y = q / w; return x == 0 || y == 0 || x == w - 1 || y == h - 1 }
        let tiny = region.count < 4
        let neighbourSliver = touchesBorder && region.count < largest / 5
        if tiny || neighbourSliver { for q in region { img.clear(q % w, q / w) } }
    }
}

/// Pour `peek` : on coupe le rebord gris (et son trait noir du dessus).
/// Dans l'app, c'est le bas de l'écran qui jouera le rôle du rebord.
func removeLedge(_ img: inout Bitmap) {
    let w = img.width, h = img.height
    func isLedgeGray(_ c: (Int, Int, Int)) -> Bool { abs(c.0 - 161) < 18 && abs(c.1 - 162) < 18 && abs(c.2 - 182) < 18 }
    func isDark(_ c: (Int, Int, Int)) -> Bool { max(c.0, c.1, c.2) < 70 }
    var ledgeTop = h
    for y in 0..<h {
        let gray = (0..<w).filter { isLedgeGray(img.rgb($0, y)) }.count
        if gray > w / 2 { ledgeTop = y; break }
    }
    // Remonte sur le trait sombre qui dessine le haut du rebord.
    while ledgeTop > 0 && (0..<w).filter({ isDark(img.rgb($0, ledgeTop - 1)) }).count > w / 2 { ledgeTop -= 1 }
    for y in ledgeTop..<h { for x in 0..<w { img.clear(x, y) } }
    print("  peek : rebord coupé à y=\(ledgeTop)")
}

// MARK: - Canevas commun

struct Trimmed {
    let name: String
    let image: Bitmap
    let anchorX: Int   // centre horizontal du corps (centre de masse des pixels opaques)
}

/// Rogne au plus juste et calcule le point d'ancrage horizontal.
func trim(_ img: Bitmap, name: String) -> Trimmed {
    var minX = img.width, minY = img.height, maxX = -1, maxY = -1
    var sumX = 0, count = 0
    for y in 0..<img.height { for x in 0..<img.width where img.alpha(x, y) > 0 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        sumX += x; count += 1
    } }
    var out = Bitmap(width: maxX - minX + 1, height: maxY - minY + 1)
    for y in 0..<out.height { for x in 0..<out.width {
        let s = img.index(minX + x, minY + y), d = out.index(x, y)
        for c in 0..<4 { out.pixels[d + c] = img.pixels[s + c] }
    } }
    return Trimmed(name: name, image: out, anchorX: sumX / max(count, 1) - minX)
}

/// Pose chaque sprite sur un canevas de même taille, ancré en bas au centre :
/// ainsi, changer de pose ne fait pas « sauter » Capri.
func placeOnCanvas(_ all: [Trimmed]) -> [(String, Bitmap)] {
    let halfWidth = all.map { max($0.anchorX, $0.image.width - $0.anchorX) }.max()! + canvasPadding
    let height = all.map { $0.image.height }.max()! + canvasPadding
    let width = halfWidth * 2
    return all.map { t in
        var canvas = Bitmap(width: width, height: height)
        let ox = halfWidth - t.anchorX
        let oy = height - t.image.height   // collé en bas
        for y in 0..<t.image.height { for x in 0..<t.image.width {
            let s = t.image.index(x, y), d = canvas.index(ox + x, oy + y)
            for c in 0..<4 { canvas.pixels[d + c] = t.image.pixels[s + c] }
        } }
        return (t.name, canvas)
    }
}

// MARK: - Planche d'aperçu

func contactSheet(_ sprites: [(String, Bitmap)], background: CGColor) -> CGImage {
    let columns = 5, cell = (w: sprites[0].1.width + 16, h: sprites[0].1.height + 16)
    let rows = (sprites.count + columns - 1) / columns
    let width = columns * cell.w, height = rows * cell.h
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (i, (_, bitmap)) in sprites.enumerated() {
        let col = i % columns, row = i / columns
        let rect = CGRect(x: col * cell.w + 8, y: height - (row + 1) * cell.h + 8, width: bitmap.width, height: bitmap.height)
        // Cadre du canevas + repère d'ancrage, pour vérifier l'alignement.
        context.setStrokeColor(CGColor(red: 0.5, green: 0.5, blue: 0.9, alpha: 0.5))
        context.stroke(rect)
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: rect.midX - 1, y: rect.minY - 4, width: 2, height: 4))
        context.draw(makeCGImage(bitmap), in: rect)
    }
    return context.makeImage()!
}

// MARK: - Programme principal

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sheetURL = root.appendingPathComponent("Assets/source/capri-sheet.webp")
let spritesDir = root.appendingPathComponent("Sources/Capri/Resources/Sprites")
let previewDir = root.appendingPathComponent("Assets/preview")
try FileManager.default.createDirectory(at: spritesDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

print("Lecture de \(sheetURL.path)")
let sheet = loadBitmap(sheetURL)

var trimmed: [Trimmed] = []
for box in poses {
    var img = crop(sheet, box)
    if box.name == "peek" { removeLedge(&img) }
    removeBackground(&img)
    removeSlivers(&img)
    trimmed.append(trim(img, name: box.name))
}

let sprites = placeOnCanvas(trimmed)
for (name, bitmap) in sprites {
    savePNG(makeCGImage(bitmap), to: spritesDir.appendingPathComponent("\(name).png"))
}
print("\(sprites.count) sprites écrits (\(sprites[0].1.width)×\(sprites[0].1.height) px) dans \(spritesDir.path)")

savePNG(contactSheet(sprites, background: CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)),
        to: previewDir.appendingPathComponent("contact-sheet-light.png"))
savePNG(contactSheet(sprites, background: CGColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)),
        to: previewDir.appendingPathComponent("contact-sheet-dark.png"))
print("Aperçus écrits dans \(previewDir.path)")
