// swift-tools-version:5.10
// Le « manifeste » du projet : SwiftPM lit ce fichier pour savoir quoi compiler.
// Outils 5.10 = mode de langage Swift 5 : moins de contraintes de concurrence, plus simple pour apprendre.
import PackageDescription

let package = Package(
    name: "Capri",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Capri",
            path: "Sources/Capri",
            // On copie le dossier des sprites tel quel dans le bundle de ressources.
            resources: [.copy("Resources/Sprites")]
        )
    ]
)
