// Relecture d'accessibilité de Pulse RÉELLEMENT affiché, à l'API
// (`AXUIElementCopyAttributeValue`) : ce que VoiceOver et le clavier trouvent
// dans le panneau, la fenêtre Réglages ou le panneau détaché, dans l'ordre de
// lecture, avec les défauts relevés. Chantier 16.
//
//   swift outils/relecture-ax.swift                  ce qui est ouvert maintenant
//   swift outils/relecture-ax.swift --attendre 90    attend (90 s au plus) que le
//                                                    panneau s'ouvre, puis le lit
//   swift outils/relecture-ax.swift --fichier x.txt  écrit aussi le relevé dans x.txt
//
// Hors écran, l'arbre reste vide : SwiftUI ne le construit que pour une
// fenêtre affichée et un client qui le demande. D'où ce script, lancé pendant
// qu'Isma ouvre le panneau lui-même (⌃⌥M ou clic sur l'icône) : il n'ouvre
// RIEN — ni panneau, ni fenêtre — et ne clique sur rien.
//
// Pas par System Events : sur macOS 26, SwiftUI range le nom d'un élément dans
// `AXAttributedDescription`, qu'osascript ne sait pas lire (README, pièges).
//
// Il faut l'autorisation Accessibilité de l'app qui lance le script (Terminal,
// ou l'app de la session) : sans elle, le script le dit et s'arrête, sans
// rien demander à macOS (`AXIsProcessTrusted`, jamais l'option qui affiche la
// demande).
//
// Code de sortie : 0 sans défaut grave, 1 avec (élément AXUnknown, contrôle
// sans nom, contrôle hors d'atteinte du clavier), 2 si rien n'a pu être lu.
import AppKit
import ApplicationServices

// MARK: - Options

let arguments = CommandLine.arguments
func valeur(apres option: String) -> String? {
    guard let i = arguments.firstIndex(of: option), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
let attente = valeur(apres: "--attendre").flatMap(Double.init) ?? 0
let fichier = valeur(apres: "--fichier")

var sortie = ""
func ecris(_ ligne: String = "") {
    print(ligne)
    sortie += ligne + "\n"
}
func termine(_ code: Int32) -> Never {
    if let fichier { try? sortie.write(toFile: fichier, atomically: true, encoding: .utf8) }
    exit(code)
}

// MARK: - Lecture des attributs

func attribut(_ e: AXUIElement, _ nom: String) -> CFTypeRef? {
    var valeur: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, nom as CFString, &valeur) == .success else { return nil }
    return valeur
}

/// Une chaîne, qu'elle soit simple ou enrichie (`AXAttributedDescription`).
func texte(_ e: AXUIElement, _ nom: String) -> String {
    guard let v = attribut(e, nom) else { return "" }
    if let s = v as? String { return s }
    if let s = v as? NSAttributedString { return s.string }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func enfants(_ e: AXUIElement) -> [AXUIElement] {
    (attribut(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func cadre(_ e: AXUIElement) -> CGRect? {
    guard let p = attribut(e, kAXPositionAttribute), let t = attribut(e, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(t) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, taille = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(t as! AXValue, .cgSize, &taille)
    return CGRect(origin: point, size: taille)
}

/// Peut-on y amener le focus clavier (Accès complet au clavier) ?
func atteignableAuClavier(_ e: AXUIElement) -> Bool {
    var reglable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &reglable) == .success
        && reglable.boolValue
}

// MARK: - Ce que VoiceOver dit d'un élément

struct Element {
    var role: String
    var sousRole: String
    var nom: String        // description, description enrichie ou titre
    var valeur: String
    var aide: String
    var cadre: CGRect?
    var profondeur: Int
    var clavier: Bool
    var actions: [String]
}

let controles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
    "AXIncrementor", "AXTextField", "AXLink", "AXDisclosureTriangle", "AXComboBox", "AXSegmentedControl",
]

let nomsDeRole: [String: String] = [
    "AXButton": "bouton", "AXStaticText": "texte", "AXImage": "image", "AXGroup": "groupe",
    "AXCheckBox": "case", "AXRadioButton": "bouton radio", "AXPopUpButton": "menu local",
    "AXMenuButton": "bouton menu", "AXSlider": "curseur", "AXTextField": "champ", "AXLink": "lien",
    "AXDisclosureTriangle": "triangle", "AXScrollArea": "défilement", "AXHeading": "titre",
    "AXUnknown": "INCONNU", "AXWindow": "fenêtre", "AXList": "liste", "AXOutline": "liste",
    "AXRow": "rangée", "AXCell": "cellule", "AXTable": "tableau", "AXSplitGroup": "partage",
    "AXToolbar": "barre d'outils", "AXTabGroup": "onglets", "AXIncrementor": "flèches",
    "AXSegmentedControl": "segments", "AXComboBox": "liste modifiable", "AXMenuBarItem": "icône de barre",
    "AXLayoutArea": "zone", "AXValueIndicator": "indicateur", "AXProgressIndicator": "progression",
    "AXLevelIndicator": "jauge",
]

func lis(_ e: AXUIElement, profondeur: Int, dans liste: inout [Element], limite: Int = 4000) {
    guard liste.count < limite else { return }
    let role = texte(e, kAXRoleAttribute)
    var nom = texte(e, kAXDescriptionAttribute)
    if nom.isEmpty { nom = texte(e, "AXAttributedDescription") }
    if nom.isEmpty { nom = texte(e, kAXTitleAttribute) }
    var actions: CFArray?
    AXUIElementCopyActionNames(e, &actions)
    liste.append(Element(role: role, sousRole: texte(e, kAXSubroleAttribute), nom: nom,
                         valeur: texte(e, kAXValueAttribute), aide: texte(e, kAXHelpAttribute),
                         cadre: cadre(e), profondeur: profondeur,
                         clavier: controles.contains(role) ? atteignableAuClavier(e) : false,
                         actions: (actions as? [String]) ?? []))
    for enfant in enfants(e) { lis(enfant, profondeur: profondeur + 1, dans: &liste, limite: limite) }
}

/// Un nom de symbole SF (« chevron.right », « gearshape ») : une image
/// qu'on a oublié de nommer, que VoiceOver épelle.
func ressembleASymbole(_ s: String) -> Bool {
    s.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil
}

// MARK: - Pulse

guard AXIsProcessTrusted() else {
    ecris("""
    Lecture impossible : l'app qui lance ce script n'a pas l'autorisation Accessibilité.
    Réglages Système › Confidentialité et sécurité › Accessibilité : cocher l'app (Terminal…),
    puis relancer. Le script ne demande rien lui-même.
    """)
    termine(2)
}

guard let pulse = NSRunningApplication.runningApplications(withBundleIdentifier: "com.isma.pulse").first else {
    ecris("Pulse ne tourne pas (com.isma.pulse introuvable).")
    termine(2)
}
let app = AXUIElementCreateApplication(pulse.processIdentifier)
AXUIElementSetMessagingTimeout(app, 2)

/// Les fenêtres de Pulse : celles qu'annonce `AXWindows`, plus les enfants
/// de l'app qui sont des fenêtres — la fenêtre d'un popover n'est pas
/// toujours rangée dans la première liste.
func fenetres() -> [AXUIElement] {
    var toutes = (attribut(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    for enfant in enfants(app) where texte(enfant, kAXRoleAttribute) == "AXWindow" {
        if !toutes.contains(where: { CFEqual($0, enfant) }) { toutes.append(enfant) }
    }
    return toutes
}

/// Le panneau est ouvert quand une fenêtre de Pulse porte son bouton Quitter
/// (le pied du panneau, popover ou détaché).
func panneauOuvert() -> Bool {
    for fenetre in fenetres() {
        var liste: [Element] = []
        lis(fenetre, profondeur: 0, dans: &liste, limite: 1500)
        if liste.contains(where: { $0.role == "AXButton" && $0.nom == "Quitter" }) { return true }
    }
    return false
}

if attente > 0 {
    ecris("En attente du panneau (\(Int(attente)) s au plus) : ouvrez-le avec ⌃⌥M ou l'icône de Pulse.")
    let fin = Date().addingTimeInterval(attente)
    var ouvert = panneauOuvert()
    while !ouvert && Date() < fin {
        Thread.sleep(forTimeInterval: 0.5)
        ouvert = panneauOuvert()
    }
    guard ouvert else {
        ecris("Le panneau ne s'est pas ouvert dans le délai.")
        termine(2)
    }
    // La cascade d'ouverture dure 300 ms : on lit le panneau posé.
    Thread.sleep(forTimeInterval: 1.0)
}

// MARK: - Relevé

var graves = 0
var lues = 0

// L'icône de la barre de menus : se lit panneau fermé.
if let barre = attribut(app, "AXExtrasMenuBar") {
    let barre = barre as! AXUIElement
    let items = enfants(barre)
    ecris("BARRE DE MENUS : \(items.count) icône\(items.count > 1 ? "s" : "")")
    for item in items {
        var nom = texte(item, kAXDescriptionAttribute)
        if nom.isEmpty { nom = texte(item, "AXAttributedDescription") }
        if nom.isEmpty { nom = texte(item, kAXTitleAttribute) }
        let valeurItem = texte(item, kAXValueAttribute)
        let defaut = nom.isEmpty && valeurItem.isEmpty
        if defaut { graves += 1 }
        ecris("  \(defaut ? "✗" : "✓") « \(nom) »" + (valeurItem.isEmpty ? "" : " valeur « \(valeurItem) »")
              + (defaut ? "  ← sans nom : VoiceOver ne dit rien de l'icône" : ""))
    }
    ecris()
}

let toutes = fenetres()
if toutes.isEmpty {
    ecris("Aucune fenêtre de Pulse ouverte : rien d'autre à lire.")
    ecris("Pour le panneau : swift outils/relecture-ax.swift --attendre 90, puis l'ouvrir.")
    termine(graves > 0 ? 1 : 2)
}

for fenetre in toutes {
    var liste: [Element] = []
    lis(fenetre, profondeur: 0, dans: &liste)
    lues += liste.count
    let titre = texte(fenetre, kAXTitleAttribute)
    let cadreFenetre = cadre(fenetre)
    let estPanneau = liste.contains { $0.role == "AXButton" && $0.nom == "Quitter" }
    ecris("FENÊTRE « \(titre.isEmpty ? (estPanneau ? "panneau" : "sans titre") : titre) »"
          + (cadreFenetre.map { " \(Int($0.width)) × \(Int($0.height)) pt" } ?? ""))

    var defauts: [String] = []
    var parole: [String] = []
    var boutons = 0, sansNom = 0, horsClavier = 0, inconnus = 0, titres = 0, imagesSymbole = 0, horsCadre = 0

    for el in liste.dropFirst() {
        let r = nomsDeRole[el.role] ?? el.role
        let decale = String(repeating: "  ", count: min(el.profondeur, 12))
        var notes: [String] = []
        if el.role == "AXUnknown" {
            inconnus += 1
            notes.append("rôle inconnu : VoiceOver le lit mal")
        }
        if el.role == "AXHeading" || el.sousRole == "AXHeading" { titres += 1 }
        if controles.contains(el.role) {
            boutons += 1
            if el.nom.isEmpty && el.valeur.isEmpty {
                sansNom += 1
                notes.append("contrôle sans nom")
            }
            if !el.clavier {
                horsClavier += 1
                notes.append("hors d'atteinte du clavier")
            }
        }
        if el.role == "AXImage", ressembleASymbole(el.nom) {
            imagesSymbole += 1
            notes.append("image nommée par son symbole : VoiceOver dit « \(el.nom) »")
        }
        if let c = el.cadre, let f = cadreFenetre, c.width > 0, c.height > 0,
           !f.insetBy(dx: -2, dy: -2).contains(c) {
            horsCadre += 1
            notes.append("dépasse la fenêtre")
        }
        // Ce que VoiceOver énonce, dans l'ordre : groupes et zones muets.
        let dit = [el.nom, el.valeur].filter { !$0.isEmpty }.joined(separator: ", ")
        if !dit.isEmpty, !["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea"].contains(el.role) {
            parole.append(dit)
        }
        let affiche = dit.isEmpty ? "" : "« \(dit) »"
        let aide = el.aide.isEmpty ? "" : "  (aide : \(el.aide))"
        let clavier = controles.contains(el.role) ? (el.clavier ? "  ⌨" : "") : ""
        if !(el.role == "AXGroup" && dit.isEmpty && notes.isEmpty) {
            ecris("\(decale)\(r) \(affiche)\(clavier)\(aide)" + (notes.isEmpty ? "" : "   ✗ " + notes.joined(separator: " ; ")))
        }
        if !notes.isEmpty { defauts.append("\(r) \(affiche) : \(notes.joined(separator: " ; "))") }
    }
    graves += inconnus + sansNom + horsClavier

    ecris()
    ecris("BILAN de la fenêtre : \(liste.count) éléments, \(boutons) contrôles (\(sansNom) sans nom, "
          + "\(horsClavier) hors clavier), \(inconnus) AXUnknown, \(titres) titres, "
          + "\(imagesSymbole) images nommées par leur symbole, \(horsCadre) hors de la fenêtre.")
    if titres == 0 {
        ecris("  Aucun titre : VoiceOver ne peut pas sauter de carte en carte (rotor « Titres »).")
    }
    if !defauts.isEmpty {
        ecris("DÉFAUTS :")
        for d in defauts { ecris("  ✗ \(d)") }
    }
    ecris()
    ecris("ORDRE DE LECTURE (ce que VoiceOver énoncerait, élément après élément) :")
    for (i, p) in parole.enumerated() { ecris(String(format: "%4d  ", i + 1) + p) }
    ecris()
}

ecris("\(lues) éléments lus, \(graves) défaut\(graves > 1 ? "s" : "") grave\(graves > 1 ? "s" : "").")
termine(graves > 0 ? 1 : 0)
