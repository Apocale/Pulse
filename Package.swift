// swift-tools-version:6.0
import PackageDescription

// Concurrence stricte À LA COMPILATION (toutes les vérifications de Swift 6,
// zéro avertissement le 11/10), mais le mode de langage reste Swift 5 : en
// mode 6, le compilateur pose aussi des vérifications d'isolation À
// L'EXÉCUTION (SE-0423) — 784 fonctions de Pulse et 5 du helper, relevées
// au désassemblage — qui font PLANTER le processus quand une fermeture
// isolée au fil principal est rappelée ailleurs par une API C ou
// Objective-C. Essayé : un gestionnaire `notify_register_dispatch` formé au
// premier niveau, comme celui de la pression thermique du helper, s'arrête
// en SIGTRAP (code 133) en mode 6, tourne en mode 5. Le helper, root,
// aurait planté à son arrêt (SIGTERM) au lieu de rendre la main à macOS.
// Le passage au mode 6 attend que chacun de ces chemins soit vérifié
// (docs/chantiers/17-audit-code.md).
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pulse",
            dependencies: ["PulseFanKit"],
            path: "Sources/Pulse",
            swiftSettings: strict,
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        // Chantier 14, contrôle des ventilateurs. La courbe, les sécurités et
        // les messages vivent dans une bibliothèque testable sans root ; la
        // commande d'écriture du SMC n'existe que dans l'exécutable du helper,
        // jamais dans l'app.
        .target(
            name: "PulseFanKit",
            path: "Sources/PulseHelper/Kit",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "PulseHelper",
            dependencies: ["PulseFanKit"],
            path: "Sources/PulseHelper/Daemon",
            swiftSettings: strict,
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        // `swift test`. Des scénarios rejoués sur le code réel, pas sur un
        // modèle : un délai de tenue vérifié en Python ne prouve rien du Swift.
        .testTarget(
            name: "PulseTests",
            dependencies: ["Pulse", "PulseFanKit"],
            path: "Tests/PulseTests",
            swiftSettings: strict
        ),
    ]
)
