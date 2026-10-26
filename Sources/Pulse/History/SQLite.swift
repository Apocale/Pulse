import Foundation
import SQLite3

/// Une enveloppe minimale autour de la libsqlite3 du système : aucune
/// dépendance, rien que ce dont la base des séries a besoin.
///
/// Une connexion n'est utilisée que depuis UNE file à la fois (celle de
/// `SeriesDatabase`) ; SQLite est compilé en mode sérialisé sur macOS, ce qui
/// couvre de toute façon un accès croisé accidentel.
struct SQLiteError: Error, CustomStringConvertible {
    var code: Int32
    var message: String

    /// La base elle-même est abîmée, ou n'est pas une base : c'est le cas où
    /// le fichier doit être MIS DE CÔTÉ, jamais effacé.
    var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    var description: String { "SQLite \(code) : \(message)" }
}

final class SQLiteConnection {
    let handle: OpaquePointer

    /// `readOnly` : aucune création, aucune écriture — pour `--probe` et
    /// `--snapshot`, qui lisent la base pendant que l'app l'écrit.
    /// `immutable` : ni verrou ni fichier annexe, pour lire une base en WAL
    /// sans toucher à son `-shm` (voir `SeriesDatabase.configure`).
    init(path: String, readOnly: Bool, immutable: Bool = false) throws {
        var db: OpaquePointer?
        var target = path
        var flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if immutable {
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            target = "file:\(escaped)?mode=ro&immutable=1"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        }
        let status = sqlite3_open_v2(target, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: status, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        // Un lecteur d'un autre processus (--probe) peut tenir un verrou un
        // instant : on attend plutôt que d'échouer.
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(handle) }

    var lastError: SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError
        }
        return SQLiteStatement(statement, connection: self)
    }

    /// Une valeur unique : `PRAGMA quick_check`, un `count(*)`.
    func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    func scalarInt(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        guard try statement.step() else { return nil }
        return statement.isNull(0) ? nil : statement.int64(0)
    }

    /// Tout ou rien : un lot de points s'écrit en une transaction, une seule
    /// synchronisation disque au lieu d'une par point.
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private let connection: SQLiteConnection

    init(_ statement: OpaquePointer, connection: SQLiteConnection) {
        self.statement = statement
        self.connection = connection
    }

    deinit { sqlite3_finalize(statement) }

    /// Indices à partir de 1, comme dans SQLite.
    func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(statement, index, value) }
    func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(statement, index, value) }
    func bind(_ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        // SQLITE_TRANSIENT : SQLite copie la chaîne, dont Swift ne garantit
        // pas la durée de vie au-delà de l'appel.
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    /// `true` tant qu'une ligne est disponible.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.lastError
        }
    }

    /// Prêt pour un nouveau jeu de valeurs, sans recompiler la requête.
    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}
