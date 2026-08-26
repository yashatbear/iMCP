import AppKit
import Foundation
import OSLog
import MCP

private let log = Logger.service("notes")

final class NotesService: Service {
    static let shared = NotesService()

    // ── activation ────────────────────────────────────────────────────────────

    var isActivated: Bool {
        get async {
            let script = "tell application \"Notes\" to return name of first account"
            return (try? await runAppleScript(script)) != nil
        }
    }

    func activate() async throws {
        let script = "tell application \"Notes\" to return name of first account"
        _ = try await runAppleScript(script)
    }

    // ── tools ─────────────────────────────────────────────────────────────────

    var tools: [Tool] {
        Tool(
            name: "notes_list_folders",
            description: "List all folders in Apple Notes",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(title: "List Note Folders", readOnlyHint: true, openWorldHint: false)
        ) { [weak self] _ in
            guard let self else { throw NotesError.appleScriptError("service deallocated") }
            let script = """
            tell application "Notes"
                set output to ""
                repeat with f in folders
                    set output to output & name of f & "\n"
                end repeat
                return output
            end tell
            """
            let raw = try await self.runAppleScript(script)
            let names = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return Value.array(names.map { Value.string($0) })
        }

        Tool(
            name: "notes_list",
            description: "List notes, optionally filtered by folder",
            inputSchema: .object(
                properties: [
                    "folder": .string(description: "Folder name; omit for all notes"),
                    "limit": .integer(description: "Max notes to return", default: .int(50)),
                ],
                additionalProperties: false
            ),
            annotations: .init(title: "List Notes", readOnlyHint: true, openWorldHint: false)
        ) { [weak self] args in
            guard let self else { throw NotesError.appleScriptError("service deallocated") }
            let folder = args["folder"]?.stringValue
            let limit  = args["limit"]?.intValue ?? 50
            let folderClause = folder.map { "of folder \"\($0)\"" } ?? ""
            let script = """
            tell application "Notes"
                set noteList to notes \(folderClause)
                set output to ""
                set counter to 0
                repeat with n in noteList
                    if counter >= \(limit) then exit repeat
                    set output to output & name of n & "\t" & (id of n as text) & "\t" & (modification date of n as text) & "\n"
                    set counter to counter + 1
                end repeat
                return output
            end tell
            """
            let raw = try await self.runAppleScript(script)
            let rows: [Value] = raw.split(separator: "\n").compactMap { row in
                let parts = String(row).split(separator: "\t").map(String.init)
                guard parts.count >= 2 else { return nil }
                var obj: [String: Value] = ["name": .string(parts[0]), "id": .string(parts[1])]
                if parts.count >= 3 { obj["modified"] = .string(parts[2]) }
                return Value.object(obj)
            }
            return Value.array(rows)
        }

        Tool(
            name: "notes_search",
            description: "Search Apple Notes by keyword (title and body)",
            inputSchema: .object(
                properties: [
                    "query": .string(description: "Text to search for"),
                    "limit": .integer(description: "Max results", default: .int(20)),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(title: "Search Notes", readOnlyHint: true, openWorldHint: false)
        ) { [weak self] args in
            guard let self else { throw NotesError.appleScriptError("service deallocated") }
            guard let query = args["query"]?.stringValue else {
                throw NotesError.missingArgument("query")
            }
            let limit = args["limit"]?.intValue ?? 20
            let script = """
            tell application "Notes"
                set output to ""
                set counter to 0
                repeat with n in notes
                    if counter >= \(limit) then exit repeat
                    set noteBody to plaintext of n
                    set noteName to name of n
                    if noteName contains "\(query)" or noteBody contains "\(query)" then
                        set output to output & noteName & "\t" & (id of n as text) & "\n"
                        set counter to counter + 1
                    end if
                end repeat
                return output
            end tell
            """
            let raw = try await self.runAppleScript(script)
            let rows: [Value] = raw.split(separator: "\n").compactMap { row in
                let parts = String(row).split(separator: "\t").map(String.init)
                guard parts.count >= 2 else { return nil }
                return Value.object(["name": .string(parts[0]), "id": .string(parts[1])])
            }
            return Value.array(rows)
        }

        Tool(
            name: "notes_get",
            description: "Get the full content of a note by name or ID",
            inputSchema: .object(
                properties: [
                    "name": .string(description: "Note title (exact match)"),
                    "id":   .string(description: "Note ID from notes_list"),
                ],
                additionalProperties: false
            ),
            annotations: .init(title: "Get Note", readOnlyHint: true, openWorldHint: false)
        ) { [weak self] args in
            guard let self else { throw NotesError.appleScriptError("service deallocated") }
            let selector: String
            if let id = args["id"]?.stringValue {
                selector = "note id \"\(id)\""
            } else if let name = args["name"]?.stringValue {
                selector = "note named \"\(name)\""
            } else {
                throw NotesError.missingArgument("name or id")
            }
            let script = """
            tell application "Notes"
                set n to \(selector)
                return name of n & "\t" & name of container of n & "\t" & (modification date of n as text) & "\n" & plaintext of n
            end tell
            """
            let raw = try await self.runAppleScript(script)
            let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let meta  = lines.first?.split(separator: "\t").map(String.init) ?? []
            let body  = lines.count > 1 ? lines[1] : ""
            return Value.object([
                "name":     Value.string(meta.count > 0 ? meta[0] : ""),
                "folder":   Value.string(meta.count > 1 ? meta[1] : ""),
                "modified": Value.string(meta.count > 2 ? meta[2] : ""),
                "body":     Value.string(body),
            ])
        }

        Tool(
            name: "notes_create",
            description: "Create a new note in Apple Notes",
            inputSchema: .object(
                properties: [
                    "name":   .string(description: "Note title"),
                    "body":   .string(description: "Note content"),
                    "folder": .string(description: "Folder name; defaults to 'Notes'"),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(title: "Create Note", readOnlyHint: false, openWorldHint: false)
        ) { [weak self] args in
            guard let self else { throw NotesError.appleScriptError("service deallocated") }
            guard let name = args["name"]?.stringValue else {
                throw NotesError.missingArgument("name")
            }
            let body   = args["body"]?.stringValue ?? ""
            let folder = args["folder"]?.stringValue ?? "Notes"
            let script = """
            tell application "Notes"
                tell folder "\(folder)"
                    set n to make new note with properties {name:"\(name)", body:"\(body)"}
                    return id of n as text
                end tell
            end tell
            """
            let noteId = try await self.runAppleScript(script)
            return Value.object(["id": Value.string(noteId.trimmingCharacters(in: .whitespacesAndNewlines)),
                                 "name": Value.string(name)])
        }

        Tool(
            name: "notes_update",
            description: "Update an existing note's title or body",
            inputSchema: .object(
                properties: [
                    "id":       .string(description: "Note ID"),
                    "name":     .string(description: "Current note title (if no id)"),
                    "new_name": .string(description: "New title (optional)"),
                    "body":     .string(description: "New content (optional)"),
                ],
                additionalProperties: false
            ),
            annotations: .init(title: "Update Note", readOnlyHint: false, openWorldHint: false)
        ) { [weak self] args in
            guard let self else { throw NotesError.appleScriptError("service deallocated") }
            let selector: String
            if let id = args["id"]?.stringValue {
                selector = "note id \"\(id)\""
            } else if let name = args["name"]?.stringValue {
                selector = "note named \"\(name)\""
            } else {
                throw NotesError.missingArgument("id or name")
            }
            var sets: [String] = []
            if let newName = args["new_name"]?.stringValue { sets.append("set name of n to \"\(newName)\"") }
            if let body    = args["body"]?.stringValue     { sets.append("set body of n to \"\(body)\"") }
            guard !sets.isEmpty else { return Value.bool(false) }
            let script = """
            tell application "Notes"
                set n to \(selector)
                \(sets.joined(separator: "\n    "))
                return true
            end tell
            """
            _ = try await self.runAppleScript(script)
            return Value.bool(true)
        }
    }

    // ── AppleScript helper ────────────────────────────────────────────────────

    private func runAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                if let error {
                    let msg = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
                    continuation.resume(throwing: NotesError.appleScriptError(msg))
                } else {
                    continuation.resume(returning: result?.stringValue ?? "")
                }
            }
        }
    }
}

// ── errors ────────────────────────────────────────────────────────────────────

enum NotesError: Error, LocalizedError {
    case missingArgument(String)
    case appleScriptError(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let a): return "Missing required argument: \(a)"
        case .appleScriptError(let m): return "Notes error: \(m)"
        }
    }
}
