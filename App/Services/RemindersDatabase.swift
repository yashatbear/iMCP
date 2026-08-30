import Foundation
import OSLog
import SQLite3

private let log = Logger.service("reminders")

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to the local Reminders CoreData store.
///
/// EventKit exposes no API for Reminders *sections* (the visual dividers added in
/// macOS Sonoma / iOS 17) or for *templates*. Both are stored in the Reminders
/// group container's SQLite database, so this type reads them directly.
///
/// This type is **strictly read-only**: the database is opened with
/// `SQLITE_OPEN_READONLY` and only `SELECT` / `PRAGMA` statements are issued.
/// Writing to this store directly would corrupt CoreData bookkeeping and break
/// iCloud sync — all mutations must continue to go through EventKit.
final class RemindersDatabase {
    /// Errors are surfaced to MCP clients by string interpolation, so this
    /// deliberately conforms to `CustomStringConvertible` as well — a bare enum
    /// case name would tell the caller nothing about how to fix the problem.
    enum Error: LocalizedError, CustomStringConvertible {
        case accessDenied
        case storeNotFound
        case sqlite(String)

        var description: String { errorDescription ?? "Reminders database error" }

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return """
                    Can't read the Reminders database. Sections and templates are not \
                    available through EventKit, so iMCP reads them from the local \
                    Reminders store, which requires Full Disk Access. Grant it in \
                    System Settings → Privacy & Security → Full Disk Access → enable \
                    iMCP (click + and choose /Applications/iMCP.app if it isn't listed), \
                    then quit and reopen iMCP.
                    """
            case .storeNotFound:
                return
                    "No Reminders database was found. Is the Reminders app set up on this Mac?"
            case .sqlite(let message):
                return "Reminders database error: \(message)"
            }
        }
    }

    /// A single row of a query result.
    struct Row {
        enum Column {
            case null
            case integer(Int64)
            case real(Double)
            case text(String)
            case blob(Data)
        }

        private let columns: [String: Column]

        init(columns: [String: Column]) {
            self.columns = columns
        }

        func string(_ name: String) -> String? {
            guard case .text(let value)? = columns[name] else { return nil }
            return value
        }

        func int(_ name: String) -> Int64? {
            switch columns[name] {
            case .integer(let value): return value
            case .real(let value): return Int64(value)
            default: return nil
            }
        }

        func bool(_ name: String) -> Bool {
            return (int(name) ?? 0) != 0
        }

        func double(_ name: String) -> Double? {
            switch columns[name] {
            case .real(let value): return value
            case .integer(let value): return Double(value)
            default: return nil
            }
        }

        /// Returns the column as `Data`, whether it's stored as a blob or as text.
        func data(_ name: String) -> Data? {
            switch columns[name] {
            case .blob(let value): return value
            case .text(let value): return value.data(using: .utf8)
            default: return nil
            }
        }
    }

    private let handle: OpaquePointer
    private var tableColumnCache: [String: Set<String>] = [:]

    static var storeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores",
                isDirectory: true
            )
    }

    /// Opens the most complete Reminders store available.
    ///
    /// Several `Data-*.sqlite` files can exist (one per account); the one holding
    /// the most live reminders is the active iCloud store.
    static func open() throws -> RemindersDatabase {
        let directory = storeDirectory

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            log.error("Unable to list Reminders store directory: \(error.localizedDescription)")
            throw Error.accessDenied
        }

        let candidates = contents.filter {
            $0.lastPathComponent.hasPrefix("Data-") && $0.pathExtension == "sqlite"
        }
        guard !candidates.isEmpty else { throw Error.storeNotFound }

        var best: (score: Int64, database: RemindersDatabase)? = nil
        var sawAnyOpenFailure = false

        for candidate in candidates {
            guard let database = try? RemindersDatabase(path: candidate.path) else {
                sawAnyOpenFailure = true
                continue
            }

            guard database.tableExists("ZREMCDREMINDER") else { continue }

            var score: Int64 = 0
            if let row = try? database.query(
                """
                SELECT COUNT(*) AS count FROM ZREMCDREMINDER
                WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0
                """
            ).first, let count = row.int("count") {
                score = count
            }

            if best == nil || score > best!.score {
                best = (score, database)
            }
        }

        guard let best else {
            throw sawAnyOpenFailure ? Error.accessDenied : Error.storeNotFound
        }
        return best.database
    }

    private init(path: String) throws {
        // Try a plain read-only connection first so WAL contents are visible, then
        // fall back to `immutable` (which skips the WAL) if the shared-memory file
        // can't be used. Both are read-only; neither can modify the store.
        for parameters in ["mode=ro", "immutable=1"] {
            var handle: OpaquePointer?
            let uri = "file:\(path)?\(parameters)"
            let result = sqlite3_open_v2(
                uri,
                &handle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                nil
            )
            if result == SQLITE_OK, let handle {
                // Confirm the connection is actually usable.
                if sqlite3_exec(handle, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil)
                    == SQLITE_OK
                {
                    self.handle = handle
                    return
                }
                sqlite3_close(handle)
            } else if let handle {
                sqlite3_close(handle)
            }
        }

        throw Error.accessDenied
    }

    deinit {
        sqlite3_close(handle)
    }

    // MARK: - Query plumbing

    func query(_ sql: String, _ parameters: [String] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw Error.sqlite(message)
        }
        defer { sqlite3_finalize(statement) }

        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, sqliteTransient)
        }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var columns: [String: Row.Column] = [:]
            for index in 0 ..< sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    columns[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    columns[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let pointer = sqlite3_column_text(statement, index) {
                        columns[name] = .text(String(cString: pointer))
                    } else {
                        columns[name] = .null
                    }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, index))
                    if let pointer = sqlite3_column_blob(statement, index), length > 0 {
                        columns[name] = .blob(Data(bytes: pointer, count: length))
                    } else {
                        columns[name] = .null
                    }
                default:
                    columns[name] = .null
                }
            }
            rows.append(Row(columns: columns))
        }

        return rows
    }

    func tableExists(_ name: String) -> Bool {
        let rows =
            (try? query(
                "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
                [name]
            )) ?? []
        return !rows.isEmpty
    }

    /// Schema varies between macOS releases, so optional columns are probed before use.
    func columns(of table: String) -> Set<String> {
        if let cached = tableColumnCache[table] { return cached }
        let rows = (try? query("PRAGMA table_info(\(table))")) ?? []
        let names = Set(rows.compactMap { $0.string("name") })
        tableColumnCache[table] = names
        return names
    }

    // MARK: - Domain reads

    /// Decodes the `memberships` JSON that maps reminders to sections.
    ///
    /// Reminders stores section membership on the *owning* row (a list or a
    /// template), not on the reminder itself.
    private func memberships(from data: Data?) -> [String: String] {
        guard let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["memberships"] as? [[String: Any]]
        else { return [:] }

        var result: [String: String] = [:]
        for entry in entries {
            guard let member = entry["memberID"] as? String,
                let group = entry["groupID"] as? String,
                (entry["isObsolete"] as? Bool) != true
            else { continue }
            result[member] = group
        }
        return result
    }

    /// Drops membership entries that point at a section which no longer exists.
    ///
    /// Deleting a section in Reminders.app tombstones the section row
    /// (`ZMARKEDFORDELETION = 1`, and its `ZLIST` link is cleared) but leaves the
    /// *memberships* blob on the owning list untouched — every reminder that was
    /// in that section keeps a stale `groupID` pointing at it, sometimes for
    /// years. Reminders.app resolves those to nothing and draws the reminder at
    /// the top of the list, i.e. unsectioned.
    ///
    /// Callers ask two questions of this map: "which section is this reminder
    /// in?" and "is it in no section at all?". If stale entries survive, a
    /// reminder answers *yes* to the first (so it is never counted as
    /// unsectioned) while matching no live section (so it is never listed under
    /// one) — it silently vanishes from the accounting. On one real list that
    /// dropped 285 of 548 reminders. Resolving membership against the live
    /// sections up front keeps the two questions consistent.
    private func membershipsResolved(
        from data: Data?,
        liveSectionIdentifiers: Set<String>
    ) -> [String: String] {
        memberships(from: data).filter { liveSectionIdentifiers.contains($0.value) }
    }

    struct Section {
        let identifier: String
        let name: String
    }

    struct ListSections {
        let listName: String
        /// Matches `EKCalendar.calendarIdentifier`.
        let listIdentifier: String
        let sections: [Section]
        /// Section identifier keyed by reminder identifier (`EKReminder.calendarItemIdentifier`).
        let sectionIdentifiersByReminder: [String: String]
    }

    /// Returns sections for every reminder list that has any, keyed in list order.
    func listSections() throws -> [ListSections] {
        guard tableExists("ZREMCDBASESECTION"), tableExists("ZREMCDBASELIST") else { return [] }

        let listColumns = columns(of: "ZREMCDBASELIST")
        guard listColumns.contains("ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA") else { return [] }

        let lists = try query(
            """
            SELECT Z_PK, ZNAME, ZCKIDENTIFIER, ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA AS memberships
            FROM ZREMCDBASELIST
            WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0
              AND ZNAME IS NOT NULL AND ZNAME != ''
            """
        )

        var results: [ListSections] = []
        for list in lists {
            guard let primaryKey = list.int("Z_PK"),
                let name = list.string("ZNAME"),
                let identifier = list.string("ZCKIDENTIFIER")
            else { continue }

            let sectionRows = try query(
                """
                SELECT ZDISPLAYNAME, ZCKIDENTIFIER FROM ZREMCDBASESECTION
                WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0 AND ZLIST = ?
                ORDER BY Z_PK
                """,
                [String(primaryKey)]
            )
            guard !sectionRows.isEmpty else { continue }

            var sections: [Section] = []
            for row in sectionRows {
                guard let sectionIdentifier = row.string("ZCKIDENTIFIER") else { continue }
                sections.append(
                    Section(
                        identifier: sectionIdentifier,
                        name: row.string("ZDISPLAYNAME") ?? ""
                    )
                )
            }

            let membership = membershipsResolved(
                from: list.data("memberships"),
                liveSectionIdentifiers: Set(sections.map(\.identifier))
            )

            results.append(
                ListSections(
                    listName: name,
                    listIdentifier: identifier,
                    sections: sections,
                    sectionIdentifiersByReminder: membership
                )
            )
        }

        return results
    }

    struct ReminderRow {
        /// Matches `EKReminder.calendarItemIdentifier`.
        let identifier: String
        let title: String
        let isCompleted: Bool
    }

    /// Reminders belonging to the list with the given identifier
    /// (`EKCalendar.calendarIdentifier`), in stored order.
    func reminders(inListWithIdentifier listIdentifier: String) throws -> [ReminderRow] {
        guard tableExists("ZREMCDREMINDER") else { return [] }
        let rows = try query(
            """
            SELECT r.ZCKIDENTIFIER AS identifier, r.ZTITLE AS title,
                   COALESCE(r.ZCOMPLETED, 0) AS completed
            FROM ZREMCDREMINDER r
            JOIN ZREMCDBASELIST l ON r.ZLIST = l.Z_PK
            WHERE COALESCE(r.ZMARKEDFORDELETION, 0) = 0 AND l.ZCKIDENTIFIER = ?
            ORDER BY r.Z_PK
            """,
            [listIdentifier]
        )
        return rows.compactMap { row in
            guard let identifier = row.string("identifier") else { return nil }
            return ReminderRow(
                identifier: identifier,
                title: row.string("title") ?? "",
                isCompleted: row.bool("completed")
            )
        }
    }

    struct TemplateItem {
        let identifier: String
        let title: String
        let parentIdentifier: String?
    }

    struct Template {
        let identifier: String
        let name: String
        let created: Date?
        let modified: Date?
        let sections: [Section]
        let items: [TemplateItem]
        /// Section identifier keyed by template item identifier.
        let sectionIdentifiersByItem: [String: String]
    }

    /// Core Data stores dates as seconds since 2001-01-01.
    private static func date(fromAppleTimestamp timestamp: Double?) -> Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: timestamp)
    }

    /// Returns saved Reminders templates. `items` is empty unless `includeItems` is true.
    func templates(matching name: String? = nil, includeItems: Bool) throws -> [Template] {
        guard tableExists("ZREMCDTEMPLATE") else { return [] }

        let templateColumns = columns(of: "ZREMCDTEMPLATE")
        let hasMemberships = templateColumns.contains("ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA")
        let membershipsSelect =
            hasMemberships ? "ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA AS memberships" : "NULL AS memberships"

        let rows = try query(
            """
            SELECT Z_PK, ZNAME, ZCKIDENTIFIER, ZCREATIONDATE, ZLASTMODIFIEDDATE, \(membershipsSelect)
            FROM ZREMCDTEMPLATE
            WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0
              AND ZNAME IS NOT NULL AND ZNAME != ''
            ORDER BY ZNAME
            """
        )

        let sectionSupportsTemplates = columns(of: "ZREMCDBASESECTION").contains("ZTEMPLATE")
        let hasSavedReminders = tableExists("ZREMCDSAVEDREMINDER")

        var templates: [Template] = []
        for row in rows {
            guard let primaryKey = row.int("Z_PK"),
                let templateName = row.string("ZNAME"),
                let identifier = row.string("ZCKIDENTIFIER")
            else { continue }

            if let name, templateName.caseInsensitiveCompare(name) != .orderedSame {
                continue
            }

            var sections: [Section] = []
            if sectionSupportsTemplates {
                let sectionRows = try query(
                    """
                    SELECT ZDISPLAYNAME, ZCKIDENTIFIER FROM ZREMCDBASESECTION
                    WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0 AND ZTEMPLATE = ?
                    ORDER BY Z_PK
                    """,
                    [String(primaryKey)]
                )
                for sectionRow in sectionRows {
                    guard let sectionIdentifier = sectionRow.string("ZCKIDENTIFIER") else {
                        continue
                    }
                    sections.append(
                        Section(
                            identifier: sectionIdentifier,
                            name: sectionRow.string("ZDISPLAYNAME") ?? ""
                        )
                    )
                }
            }

            // Same stale-membership hazard as lists — see `membershipsResolved`.
            // Only resolve when the sections were actually enumerated; on an OS
            // whose schema can't link sections to templates the set would be
            // empty and would wrongly discard every membership.
            let membership =
                sectionSupportsTemplates
                ? membershipsResolved(
                    from: row.data("memberships"),
                    liveSectionIdentifiers: Set(sections.map(\.identifier))
                )
                : memberships(from: row.data("memberships"))

            var items: [TemplateItem] = []
            if includeItems, hasSavedReminders {
                let savedColumns = columns(of: "ZREMCDSAVEDREMINDER")
                let parentSelect =
                    savedColumns.contains("ZPARENTSAVEDREMINDERIDENTIFIER")
                    ? "ZPARENTSAVEDREMINDERIDENTIFIER AS parent" : "NULL AS parent"
                let itemRows = try query(
                    """
                    SELECT ZTITLE, ZCKIDENTIFIER, \(parentSelect) FROM ZREMCDSAVEDREMINDER
                    WHERE COALESCE(ZMARKEDFORDELETION, 0) = 0 AND ZTEMPLATE = ?
                    ORDER BY Z_PK
                    """,
                    [String(primaryKey)]
                )
                for itemRow in itemRows {
                    guard let itemIdentifier = itemRow.string("ZCKIDENTIFIER") else { continue }
                    items.append(
                        TemplateItem(
                            identifier: itemIdentifier,
                            title: itemRow.string("ZTITLE") ?? "",
                            parentIdentifier: itemRow.string("parent")
                        )
                    )
                }
            }

            templates.append(
                Template(
                    identifier: identifier,
                    name: templateName,
                    created: Self.date(fromAppleTimestamp: row.double("ZCREATIONDATE")),
                    modified: Self.date(fromAppleTimestamp: row.double("ZLASTMODIFIEDDATE")),
                    sections: sections,
                    items: items,
                    sectionIdentifiersByItem: membership
                )
            )
        }

        return templates
    }

    /// Number of live (non-deleted) template items, without loading them.
    func templateItemCounts() throws -> [String: Int] {
        guard tableExists("ZREMCDTEMPLATE"), tableExists("ZREMCDSAVEDREMINDER") else { return [:] }
        let rows = try query(
            """
            SELECT t.ZCKIDENTIFIER AS identifier, COUNT(sr.Z_PK) AS count
            FROM ZREMCDTEMPLATE t
            LEFT JOIN ZREMCDSAVEDREMINDER sr
              ON sr.ZTEMPLATE = t.Z_PK AND COALESCE(sr.ZMARKEDFORDELETION, 0) = 0
            WHERE COALESCE(t.ZMARKEDFORDELETION, 0) = 0
            GROUP BY t.ZCKIDENTIFIER
            """
        )
        var counts: [String: Int] = [:]
        for row in rows {
            guard let identifier = row.string("identifier") else { continue }
            counts[identifier] = Int(row.int("count") ?? 0)
        }
        return counts
    }
}
