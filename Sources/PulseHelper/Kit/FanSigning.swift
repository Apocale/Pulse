import Foundation
import Security

/// Les signatures : celle d'un fichier (l'installation ne copie en root
/// qu'un binaire signé `com.isma.pulse.helper` — jamais, par exemple,
/// l'exécutable principal du bundle où il est rangé), et l'exigence que le
/// helper pose à son client.
///
/// Deux cas, sans réglage : le helper lit SA propre signature.
/// - Ad hoc (aujourd'hui) : pas de Team ID. Seul l'identifiant
///   `com.isma.pulse` survit aux recompilations, et un processus de la même
///   session peut le copier (TN3127) — d'où la surface bornée du helper.
/// - Identité Apple (« Apple Development », équipe personnelle gratuite, si
///   Isma en crée une ; `PULSE_IDENTITE` dans `build.sh`) : l'exigence devient
///   « signé par Apple pour la MÊME équipe que le helper, identifiant
///   com.isma.pulse » — infalsifiable sans la clé privée d'Isma, et stable
///   d'une recompilation à l'autre.
public enum FanSigning {
    public static func identifier(ofFileAt path: String) -> String? {
        info(ofFileAt: path)?[kSecCodeInfoIdentifier as String] as? String
    }

    public static func teamIdentifier(ofFileAt path: String) -> String? {
        info(ofFileAt: path)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Le Team ID du processus qui tourne, nil en ad hoc.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// L'exigence de signature du client, selon l'équipe du helper.
    public static func clientRequirement(team: String?) -> String {
        let identifier = "identifier \"\(FanProtocol.clientIdentifier)\""
        guard let team, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return identifier }
        return "\(identifier) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func info(ofFileAt path: String) -> [String: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }
}
