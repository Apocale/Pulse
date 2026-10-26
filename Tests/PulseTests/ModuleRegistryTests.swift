import Foundation
import SwiftUI
import Testing
@testable import Pulse

/// Le registre des modules et la disposition que les réglages en tirent
/// (`ModuleRegistry`, `Layout`).
@MainActor
@Suite struct ModuleRegistryTests {
    /// Les cinq cartes du socle, nommément : la disposition se vérifie sur
    /// elles, pas sur le registre réel, où chaque chantier ajoute la sienne
    /// (sans quoi l'inscription d'un module cassait cinq tests).
    static let socle: [any PulseModule] = [ProcessorModule(), ReseauModule(), MemoryModule(),
                                           DisksModule(), WorkModule()]

    /// La disposition d'origine, mesurée équilibrée le 11/10 (690 contre
    /// 495 pt dans l'ordre inverse) : sans réglage, rien ne doit bouger.
    @Test func sansReglageLaDispositionDOrigine() {
        #expect(Layout.columns(PulseSettings(), modules: Self.socle) == [["processeur", "reseau"], ["memoire", "disques", "montage"]])
    }

    /// L'identifiant est la clé des réglages persistés : unique, et sans
    /// rien qu'un fichier JSON ou une ligne de commande digèrent mal.
    @Test func identifiantsUniquesEtSimples() {
        let ids = ModuleRegistry.ids
        #expect(Set(ids).count == ids.count, "identifiant en double : \(ids)")
        for id in ids {
            #expect(!id.isEmpty)
            #expect(id.allSatisfy { ("a"..."z").contains($0) || $0 == "-" }, "« \(id) » : minuscules sans accent ni espace")
        }
        for module in ModuleRegistry.all {
            #expect(!module.name.isEmpty && !module.symbol.isEmpty, "\(module.id) sans nom ou sans symbole")
            #expect(ModuleRegistry.module(module.id)?.id == module.id)
        }
    }

    /// Un module ajouté après coup par un chantier — absent des réglages
    /// d'Isma — prend sa place derrière son prédécesseur du registre, sans
    /// déranger l'ordre qu'Isma a choisi.
    @Test func unModuleNouveauSeGlisseDerriereSonPredecesseur() {
        let modules: [any PulseModule] = [Fake(id: "a"), Fake(id: "b"), Fake(id: "nouveau"), Fake(id: "c")]
        var settings = PulseSettings()
        settings.layout.order = ["c", "b", "a"]
        #expect(Layout.order(settings, modules: modules) == ["c", "b", "nouveau", "a"])
        settings.layout.order = []
        #expect(Layout.order(settings, modules: modules) == ["a", "b", "nouveau", "c"])
    }

    /// Un identifiant inconnu (module retiré) ou en double, dans un fichier
    /// édité à la main, ne casse rien.
    @Test func inconnusEtDoublonsIgnores() {
        let modules: [any PulseModule] = [Fake(id: "a"), Fake(id: "b")]
        var settings = PulseSettings()
        settings.layout.order = ["b", "disparu", "b", "a", "a"]
        #expect(Layout.order(settings, modules: modules) == ["b", "a"])
    }

    @Test func uneCarteMasqueeQuitteSaColonne() {
        var settings = PulseSettings()
        settings.modules["reseau"] = ModuleSettings(enabled: false)
        #expect(Layout.columns(settings, modules: Self.socle) == [["processeur"], ["memoire", "disques", "montage"]])
    }

    /// Un module désactivé par défaut (extras, chantier 18) n'apparaît que
    /// si Isma l'active.
    @Test func desactiveParDefautJusquAuChoixDIsma() {
        let modules: [any PulseModule] = [Fake(id: "a"), Fake(id: "meteo", enabled: false)]
        var settings = PulseSettings()
        #expect(Layout.columns(settings, modules: modules) == [["a"], []])
        settings.modules["meteo"] = ModuleSettings(enabled: true)
        #expect(Layout.columns(settings, modules: modules) == [["a", "meteo"], []])
    }

    /// Une colonne au-delà du nombre affiché tombe dans la dernière.
    @Test func colonneHorsLimiteBornee() {
        var settings = PulseSettings()
        settings.modules["processeur"] = ModuleSettings(column: 7)
        #expect(Layout.columns(settings, modules: Self.socle) == [["reseau"], ["processeur", "memoire", "disques", "montage"]])
        settings.layout.columns = 1
        #expect(Layout.columns(settings, modules: Self.socle) == [["processeur", "reseau", "memoire", "disques", "montage"]])
        settings.layout.columns = 0
        #expect(Layout.columnCount(settings) == 1)
        settings.layout.columns = 9
        #expect(Layout.columnCount(settings) == 3)
    }

    /// Trois colonnes : l'ordre de lecture réparti en parts égales à une
    /// carte près ; retour à deux : la disposition d'origine.
    @Test func changerLeNombreDeColonnes() {
        var settings = PulseSettings()
        Layout.setColumns(3, in: &settings, modules: Self.socle)
        #expect(Layout.columns(settings, modules: Self.socle) == [["processeur", "reseau"], ["memoire", "disques"], ["montage"]])
        Layout.setColumns(1, in: &settings, modules: Self.socle)
        #expect(Layout.columns(settings, modules: Self.socle) == [["processeur", "reseau", "memoire", "disques", "montage"]])
        Layout.setColumns(2, in: &settings, modules: Self.socle)
        #expect(Layout.columns(settings, modules: Self.socle) == [["processeur", "reseau"], ["memoire", "disques", "montage"]])
    }

    /// Le glisser-déposer : avant une carte, ou en bas d'une colonne.
    @Test func deplacerUneCarte() {
        var settings = PulseSettings()
        Layout.move("disques", toColumn: 0, before: "reseau", in: &settings, modules: Self.socle)
        #expect(Layout.columns(settings, modules: Self.socle) == [["processeur", "disques", "reseau"], ["memoire", "montage"]])
        Layout.move("processeur", toColumn: 1, before: nil, in: &settings, modules: Self.socle)
        #expect(Layout.columns(settings, modules: Self.socle) == [["disques", "reseau"], ["memoire", "montage", "processeur"]])
        Layout.move("montage", toColumn: 1, before: "memoire", in: &settings, modules: Self.socle)
        #expect(Layout.columns(settings, modules: Self.socle) == [["disques", "reseau"], ["montage", "memoire", "processeur"]])
    }

    /// Chaque module reçoit l'état du panneau ET celui de sa carte : un
    /// module masqué doit pouvoir s'arrêter de mesurer.
    @Test func lEtatDuPanneauParvientAuxModules() {
        let probe = StateProbe()
        let module = Fake(id: "a", probe: probe)
        var settings = PulseSettings()
        settings.modules["a"] = ModuleSettings(enabled: false)
        module.stateDidChange(ModuleState(enabled: Layout.isEnabled(module, in: settings), panelOpen: true))
        #expect(probe.last == ModuleState(enabled: false, panelOpen: true))
    }
}

/// Un module de test, sans carte digne de ce nom.
@MainActor
private struct Fake: PulseModule {
    let id: String
    var name: String { id }
    var symbol: String { "square" }
    var enabled = true
    var probe: StateProbe? = nil
    var enabledByDefault: Bool { enabled }
    func card(_ context: CardContext) -> AnyView { AnyView(EmptyView()) }
    func stateDidChange(_ state: ModuleState) { probe?.last = state }
}

@MainActor
private final class StateProbe {
    var last: ModuleState?
}

