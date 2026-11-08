import AppKit
import SpriteKit

/// Charge les sprites une seule fois au démarrage.
/// Pour chaque pose, on garde la texture (pour l'affichage) et le masque alpha
/// (pour savoir si la souris est sur un pixel visible ou sur du vide).
final class SpriteLibrary {
    /// Masque alpha : un octet d'opacité par pixel, ligne 0 en haut.
    struct AlphaMask {
        let width: Int
        let height: Int
        let alpha: [UInt8]

        func isOpaque(x: Int, y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return alpha[y * width + x] > 40
        }

        /// Première ligne (depuis le haut) qui contient un pixel visible.
        var topOpaqueRow: Int {
            for y in 0..<height where (0..<width).contains(where: { alpha[y * width + $0] > 40 }) { return y }
            return height
        }
    }

    private(set) var textures: [Pose: SKTexture] = [:]
    private(set) var masks: [Pose: AlphaMask] = [:]
    private(set) var images: [Pose: CGImage] = [:]

    /// Toutes les poses partagent le même canevas : largeur / hauteur, en pixels.
    var canvasAspect: CGFloat {
        guard let mask = masks[.float] else { return 1 }
        return CGFloat(mask.width) / CGFloat(mask.height)
    }

    init() {
        let bundle = Self.resourceBundle()
        for pose in Pose.allCases {
            guard let url = bundle.url(forResource: pose.rawValue, withExtension: "png", subdirectory: "Sprites"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                NSLog("Capri : sprite introuvable : \(pose.rawValue).png")
                continue
            }
            images[pose] = image
            textures[pose] = SKTexture(cgImage: image)
            masks[pose] = Self.alphaMask(of: image)
        }
    }

    /// Où sont les ressources ?
    /// - dans Capri.app, Scripts/run.sh copie le bundle de ressources dans Contents/Resources ;
    /// - avec `swift run` ou Xcode, SwiftPM fournit `Bundle.module`.
    static func resourceBundle() -> Bundle {
        if let url = Bundle.main.url(forResource: "Capri_Capri", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }

    /// Dessine l'image dans un tampon pour lire l'opacité de chaque pixel.
    private static func alphaMask(of image: CGImage) -> AlphaMask {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        return AlphaMask(width: w, height: h, alpha: alpha)
    }

    /// Petite icône pour la barre des menus : la tête de `peek`, rognée au plus juste.
    func menuBarIcon() -> NSImage? {
        guard let image = images[.peek], let mask = masks[.peek] else { return nil }
        var minX = mask.width, maxX = 0
        for y in 0..<mask.height { for x in 0..<mask.width where mask.isOpaque(x: x, y: y) {
            minX = min(minX, x); maxX = max(maxX, x)
        } }
        let top = mask.topOpaqueRow
        let rect = CGRect(x: minX, y: top, width: maxX - minX + 1, height: mask.height - top)
        guard let cropped = image.cropping(to: rect) else { return nil }
        let height: CGFloat = 18
        let icon = NSImage(cgImage: cropped, size: NSSize(width: height * rect.width / rect.height, height: height))
        return icon
    }
}
