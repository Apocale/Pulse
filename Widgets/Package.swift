// swift-tools-version:5.9
// L'extension de widgets de Pulse (chantier 13), dans un paquet À PART :
// `swift build` du paquet principal ne la construit pas — rien de plus pour
// les chantiers, rien de plus dans Pulse.app tant qu'Isma ne l'a pas décidé.
// `build.sh` la construit et l'embarque seulement avec `PULSE_IDENTITE`
// (certificat de développeur) : voir docs/chantiers/13-fenetre.md.
//
// Les vues et l'état partagé sont ceux de l'app : `EtatPartage.swift` et
// `WidgetViews.swift` sont des liens vers Sources/Pulse/Window/, compilés
// ici une seconde fois. Le widget dit donc au caractère près ce que dit
// `--snapshot x.png --widget`.
//
// Ce que Xcode fait pour une cible « App Extension », refait à la main
// (relevé sur les widgets d'Apple, Calculette, Météo) : API d'extension
// seulement, point d'entrée `_NSExtensionMain` de Foundation.
import PackageDescription

let package = Package(
    name: "PulseWidgets",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PulseWidgets",
            path: "Extension",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                              "-Xlinker", "-application_extension"]),
                .linkedFramework("WidgetKit"),
            ]
        ),
    ]
)
