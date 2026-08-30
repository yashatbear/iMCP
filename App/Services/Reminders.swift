import AppKit
import EventKit
import Foundation
import OSLog
import Ontology

private let log = Logger.service("reminders")

/// Colors offered when creating a reminder list.
///
/// Names line up with the values `reminders_lists` reports for existing lists,
/// which come from `NSColor.accessibilityName`.
private let reminderListColors: [String: NSColor] = [
    "red": .systemRed,
    "orange": .systemOrange,
    "yellow": .systemYellow,
    "green": .systemGreen,
    "mint": .systemMint,
    "teal": .systemTeal,
    "cyan": .systemCyan,
    "blue": .systemBlue,
    "indigo": .systemIndigo,
    "purple": .systemPurple,
    "pink": .systemPink,
    "brown": .systemBrown,
    "gray": .systemGray,
]

/// Appended to every tool that writes through Apple's private `ReminderKit`.
private let privateAPIWarning = """
    Sections and templates have no public Apple API, so this writes through an \
    undocumented private framework. It could stop working, or behave unexpectedly, \
    after a macOS update.
    """

/// Failures raised by the section and template tools.
///
/// These conform to `CustomStringConvertible` on purpose: the MCP layer renders
/// thrown errors by interpolation, and a bare enum case name would tell the
/// caller nothing about what went wrong or how to fix it.
enum RemindersWriteError: LocalizedError, CustomStringConvertible {
    case emptyValue(String)
    case listNotFound(String, available: [String])
    case ambiguousList(String, count: Int)
    case listNotEditable(String)
    case listAlreadyExists(String)
    case sectionNotFound(section: String, list: String, available: [String])
    case ambiguousSection(section: String, list: String, count: Int)
    case sectionAlreadyExists(section: String, list: String)
    case templateNotFound(String, available: [String])
    case ambiguousTemplate(String, count: Int)
    case templateAlreadyExists(String)

    var description: String { errorDescription ?? "Reminders error" }

    private static func list(_ names: [String]) -> String {
        names.isEmpty ? "(none)" : names.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    var errorDescription: String? {
        switch self {
        case .emptyValue(let field):
            return "A non-empty \(field) is required"
        case .listNotFound(let name, let available):
            return
                "No reminder list named \"\(name)\". Available lists: \(Self.list(available))"
        case .ambiguousList(let name, let count):
            return
                "\"\(name)\" matches \(count) reminder lists. Rename one of them, or use the exact name, so there's only one match"
        case .listNotEditable(let name):
            return "The reminder list \"\(name)\" is read-only"
        case .listAlreadyExists(let name):
            return "A reminder list named \"\(name)\" already exists"
        case .sectionNotFound(let section, let list, let available):
            return
                "No section named \"\(section)\" on \"\(list)\". Sections on that list: \(Self.list(available))"
        case .ambiguousSection(let section, let list, let count):
            return
                "\"\(section)\" matches \(count) sections on \"\(list)\". Rename one of them so there's only one match"
        case .sectionAlreadyExists(let section, let list):
            return "\"\(list)\" already has a section named \"\(section)\""
        case .templateNotFound(let name, let available):
            return "No template named \"\(name)\". Available templates: \(Self.list(available))"
        case .ambiguousTemplate(let name, let count):
            return
                "\"\(name)\" matches \(count) templates. Rename one of them so there's only one match"
        case .templateAlreadyExists(let name):
            return "A template named \"\(name)\" already exists"
        }
    }
}

final class RemindersService: Service {
    private let eventStore = EKEventStore()

    static let shared = RemindersService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToReminders()
    }

    // MARK: - Strict target resolution
    //
    // Every write below turns a caller-supplied *name* into exactly one concrete
    // identifier before anything is modified. Nothing here ever fuzzy-matches or
    // picks a "best" candidate: zero matches and multiple matches are both hard
    // errors, so a write can never land somewhere the caller didn't name.

    private func requireAuthorization() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            log.error("Reminders access not authorized")
            throw NSError(
                domain: "RemindersError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
            )
        }
    }

    private static func requireName(_ arguments: [String: Value], _ key: String) throws -> String {
        guard case .string(let value) = arguments[key] else {
            throw RemindersWriteError.emptyValue(key)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RemindersWriteError.emptyValue(key) }
        return trimmed
    }

    /// The one reminder list with this exact name, or an error.
    private func resolveList(named name: String) throws -> EKCalendar {
        let lists = eventStore.calendars(for: .reminder)

        // An exact match wins outright; only fall back to a case-insensitive
        // match when nothing matched exactly.
        var matches = lists.filter { $0.title == name }
        if matches.isEmpty {
            matches = lists.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        }

        guard let first = matches.first else {
            throw RemindersWriteError.listNotFound(name, available: lists.map(\.title).sorted())
        }
        guard matches.count == 1 else {
            throw RemindersWriteError.ambiguousList(name, count: matches.count)
        }
        guard first.allowsContentModifications else {
            throw RemindersWriteError.listNotEditable(first.title)
        }
        return first
    }

    /// A section or template as the Reminders daemon reports it.
    struct NamedObject {
        let name: String
        let identifier: String

        init?(_ described: [String: String]) {
            guard let name = described["name"], let identifier = described["identifier"] else {
                return nil
            }
            self.name = name
            self.identifier = identifier
        }
    }

    /// Sections currently on a list, in display order. Empty if it has none.
    ///
    /// This goes through the Reminders daemon rather than the local database, so
    /// writing to sections works with plain Reminders access — no Full Disk
    /// Access, unlike the `reminders_sections` read tool.
    private func sections(ofListWithIdentifier identifier: String) throws -> [NamedObject] {
        try IMCPReminderKit.sections(inList: identifier).compactMap(NamedObject.init)
    }

    /// The one section with this exact name on the given list, or an error.
    private func resolveSection(
        named name: String,
        on list: EKCalendar
    ) throws -> NamedObject {
        let all = try sections(ofListWithIdentifier: list.calendarIdentifier)

        var matches = all.filter { $0.name == name }
        if matches.isEmpty {
            matches = all.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        guard let first = matches.first else {
            throw RemindersWriteError.sectionNotFound(
                section: name,
                list: list.title,
                available: all.map(\.name)
            )
        }
        guard matches.count == 1 else {
            throw RemindersWriteError.ambiguousSection(
                section: name,
                list: list.title,
                count: matches.count
            )
        }
        return first
    }

    /// Every saved template, by name and identifier.
    private func templates() throws -> [NamedObject] {
        try IMCPReminderKit.templates().compactMap(NamedObject.init)
    }

    /// The one template with this exact name, or an error.
    private func resolveTemplate(named name: String) throws -> NamedObject {
        let all = try templates()

        var matches = all.filter { $0.name == name }
        if matches.isEmpty {
            matches = all.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        guard let first = matches.first else {
            throw RemindersWriteError.templateNotFound(
                name,
                available: all.map(\.name).sorted()
            )
        }
        guard matches.count == 1 else {
            throw RemindersWriteError.ambiguousTemplate(name, count: matches.count)
        }
        return first
    }

    /// Files an already-saved reminder under one section of its list.
    ///
    /// EventKit and ReminderKit talk to the same daemon but not on the same
    /// clock, so a reminder saved moments ago can briefly be invisible to
    /// ReminderKit. Only that specific "not found" case is retried.
    private static func assign(
        reminder: EKReminder,
        toSection section: NamedObject,
        on list: EKCalendar
    ) throws {
        let notFound = 4  // IMCPReminderKitErrorNotFound
        var lastError: Swift.Error?

        for attempt in 0 ..< 4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            do {
                try IMCPReminderKit.assignReminder(
                    identifier: reminder.calendarItemIdentifier,
                    sectionIdentifier: section.identifier,
                    listIdentifier: list.calendarIdentifier
                )
                return
            } catch let error as NSError
                where error.domain == "IMCPReminderKitError" && error.code == notFound
            {
                lastError = error
            }
        }

        log.error(
            "Could not file reminder into section: \(lastError?.localizedDescription ?? "unknown")"
        )
        throw lastError
            ?? RemindersWriteError.sectionNotFound(
                section: section.name,
                list: list.title,
                available: []
            )
    }

    private func templateExists(named name: String) throws -> Bool {
        try templates().contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var tools: [Tool] {
        Tool(
            name: "reminders_lists",
            description: "List available reminder lists",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Lists",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminderLists = self.eventStore.calendars(for: .reminder)

            return reminderLists.map { reminderList in
                Value.object([
                    "title": .string(reminderList.title),
                    "source": .string(reminderList.source.title),
                    "color": .string(reminderList.color.accessibilityName),
                    "isEditable": .bool(reminderList.allowsContentModifications),
                    "isSubscribed": .bool(reminderList.isSubscribed),
                ])
            }
        }

        Tool(
            name: "reminders_fetch",
            description: "Get reminders from the reminders app with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "completed": .boolean(
                        description:
                            "If true, fetch completed reminders; if false, fetch incomplete; if omitted, fetch all"
                    ),
                    "start": .string(
                        description:
                            "Start date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "lists": .array(
                        description:
                            "Names of reminder lists to fetch from; if empty, fetches from all lists",
                        items: .string()
                    ),
                    "query": .string(
                        description: "Text to search for in reminder titles"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            // Filter reminder lists based on provided names
            var reminderLists = self.eventStore.calendars(for: .reminder)
            if case .array(let listNames) = arguments["lists"],
                !listNames.isEmpty
            {
                let requestedNames = Set(
                    listNames.compactMap { $0.stringValue?.lowercased() }
                )
                reminderLists = reminderLists.filter {
                    requestedNames.contains($0.title.lowercased())
                }
            }

            // Parse dates if provided
            var startDate: Date? = nil
            var endDate: Date? = nil
            var startIsDateOnly = false
            var endIsDateOnly = false

            if case .string(let start) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: start
                )
            {
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }
            if case .string(let end) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: end
                )
            {
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
            }

            let calendar = Calendar.current
            if let startDateValue = startDate {
                startDate = calendar.normalizedStartDate(
                    from: startDateValue,
                    isDateOnly: startIsDateOnly
                )
            }
            if let endDateValue = endDate {
                endDate = calendar.normalizedEndDate(from: endDateValue, isDateOnly: endIsDateOnly)
            }

            // Create predicate based on completion status
            let predicate: NSPredicate
            if case .bool(let completed) = arguments["completed"] {
                if completed {
                    predicate = self.eventStore.predicateForCompletedReminders(
                        withCompletionDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                } else {
                    predicate = self.eventStore.predicateForIncompleteReminders(
                        withDueDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                }
            } else {
                // If completion status not specified, use incomplete predicate as default
                predicate = self.eventStore.predicateForReminders(in: reminderLists)
            }

            // Fetch reminders
            let reminders = try await withCheckedThrowingContinuation { continuation in
                self.eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                    continuation.resume(returning: fetchedReminders ?? [])
                }
            }

            // Apply additional filters
            var filteredReminders = reminders

            // Filter by search text if provided
            if case .string(let searchText) = arguments["query"],
                !searchText.isEmpty
            {
                filteredReminders = filteredReminders.filter {
                    $0.title?.localizedCaseInsensitiveContains(searchText) == true
                }
            }

            return filteredReminders.map { PlanAction($0) }
        }

        Tool(
            name: "reminders_create",
            description: """
                Create a new reminder with specified properties, optionally placing it \
                directly into one of the list's sections. Supports time-based alarms and \
                location-based ("remind me when I arrive at / leave") reminders via the \
                `alarms` property. \(privateAPIWarning)
                """,
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "due": .string(
                        description:
                            "Due date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "list": .string(
                        description: "Reminder list name (uses default if not specified)"
                    ),
                    "section": .string(
                        description: """
                            Name of an existing section (heading) on the list to file the \
                            reminder under. The section must already exist — use \
                            reminders_sections to see them and reminders_create_section to \
                            add one. When given, the list name must match exactly one list.
                            """
                    ),
                    "notes": .string(),
                    "priority": .string(
                        default: .string(EKReminderPriority.none.stringValue),
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: """
                            Alarms for the reminder. Each item is either an integer \
                            (minutes before the due date) or an alarm object.
                            """,
                        items: .anyOf(
                            [
                                // Shorthand: minutes before the due date
                                .integer(
                                    description: "Minutes before the due date to fire an alarm"
                                ),
                                // Relative alarm (minutes before/after the due date)
                                .object(
                                    properties: [
                                        "type": .string(const: "relative"),
                                        "minutes": .integer(
                                            description:
                                                "Minutes offset from the due date (positive fires before the due date, negative after)"
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when the alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send a notification to"
                                        ),
                                    ],
                                    required: ["minutes"],
                                    additionalProperties: false
                                ),
                                // Absolute alarm (specific date/time)
                                .object(
                                    properties: [
                                        "type": .string(const: "absolute"),
                                        "datetime": .string(
                                            description:
                                                "Alarm date/time. If timezone is omitted, local time is assumed. Must include a time component.",
                                            format: .dateTime
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when the alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send a notification to"
                                        ),
                                    ],
                                    required: ["datetime"],
                                    additionalProperties: false
                                ),
                                // Proximity alarm (location-based: fire on arriving/leaving)
                                .object(
                                    properties: [
                                        "type": .string(const: "proximity"),
                                        "proximity": .string(
                                            description:
                                                "Fire when arriving at ('enter') or leaving ('leave') the location",
                                            default: "enter",
                                            enum: ["enter", "leave"]
                                        ),
                                        "locationTitle": .string(
                                            description: "Human-readable name for the location"
                                        ),
                                        "latitude": .number(
                                            description: "Latitude in decimal degrees"
                                        ),
                                        "longitude": .number(
                                            description: "Longitude in decimal degrees"
                                        ),
                                        "radius": .number(
                                            description: "Trigger radius in meters",
                                            default: .int(200)
                                        ),
                                        "sound": .string(
                                            description: "Sound name to play when the alarm triggers",
                                            enum: Sound.allCases.map { .string($0.rawValue) }
                                        ),
                                        "emailAddress": .string(
                                            description: "Email address to send a notification to"
                                        ),
                                    ],
                                    required: ["locationTitle", "latitude", "longitude"],
                                    additionalProperties: false
                                ),
                            ]
                        )
                    ),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminder = EKReminder(eventStore: self.eventStore)

            // Set required properties
            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder title is required"]
                )
            }
            reminder.title = title

            // A section can only be requested for a list we're certain about, so
            // asking for one switches list lookup from "best effort" to strict.
            var requestedSection: String? = nil
            if case .string(let name) = arguments["section"],
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                requestedSection = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var calendar = self.eventStore.defaultCalendarForNewReminders()
            if case .string(let listName) = arguments["list"] {
                if requestedSection != nil {
                    calendar = try self.resolveList(named: listName)
                } else if let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            reminder.calendar = calendar

            // Resolve the section *before* creating anything, so a bad section
            // name fails without leaving a stray reminder behind.
            var section: NamedObject? = nil
            if let requestedSection {
                guard let calendar else {
                    throw RemindersWriteError.emptyValue("list")
                }
                section = try self.resolveSection(named: requestedSection, on: calendar)
            }

            // Set optional properties
            if case .string(let dueDateStr) = arguments["due"],
                let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: dueDateStr
                )
            {
                let calendar = Calendar.current
                let dueDate = calendar.normalizedStartDate(
                    from: parsedDueDate.date,
                    isDateOnly: parsedDueDate.isDateOnly
                )
                reminder.dueDateComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }

            if case .string(let notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            // Set alarms — time-based (integer minutes, or relative/absolute objects)
            // and location-based (proximity objects). See EKAlarm.alarms(from:),
            // shared with calendar_events_create.
            if case .array = arguments["alarms"] {
                reminder.alarms = EKAlarm.alarms(from: arguments["alarms"])
            }

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

            if let section, let calendar {
                try Self.assign(
                    reminder: reminder,
                    toSection: section,
                    on: calendar
                )
            }

            return PlanAction(reminder)
        }

        Tool(
            name: "reminders_create_list",
            description: "Create a new reminder list",
            inputSchema: .object(
                properties: [
                    "name": .string(description: "Name of the new reminder list"),
                    "color": .string(
                        description: "Color for the new list",
                        enum: reminderListColors.keys.sorted().map { .string($0) }
                    ),
                    "source": .string(
                        description:
                            "Account to create the list in, by name (uses the default account if not specified)"
                    ),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder List",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let name) = arguments["name"],
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder list name is required"]
                )
            }

            if self.eventStore.calendars(for: .reminder)
                .contains(where: { $0.title.lowercased() == name.lowercased() })
            {
                throw NSError(
                    domain: "RemindersError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "A reminder list named \"\(name)\" already exists"
                    ]
                )
            }

            // Resolve the account the list should live in.
            var source: EKSource? = nil
            if case .string(let sourceName) = arguments["source"] {
                source = self.eventStore.sources.first {
                    $0.title.lowercased() == sourceName.lowercased()
                }
                guard source != nil else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No account named \"\(sourceName)\". Available accounts: "
                                + self.eventStore.sources.map(\.title).joined(separator: ", ")
                        ]
                    )
                }
            }
            if source == nil {
                source =
                    self.eventStore.defaultCalendarForNewReminders()?.source
                    ?? self.eventStore.sources.first {
                        !$0.calendars(for: .reminder).isEmpty
                    }
                    ?? self.eventStore.sources.first {
                        $0.sourceType == .calDAV || $0.sourceType == .local
                    }
            }

            guard let source else {
                log.error("No source available for new reminder list")
                throw NSError(
                    domain: "RemindersError",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No account is available to create a reminder list in"
                    ]
                )
            }

            let calendar = EKCalendar(for: .reminder, eventStore: self.eventStore)
            calendar.title = name
            calendar.source = source

            if case .string(let colorName) = arguments["color"] {
                guard let color = reminderListColors[colorName.lowercased()] else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unsupported color \"\(colorName)\". Supported colors: "
                                + reminderListColors.keys.sorted().joined(separator: ", ")
                        ]
                    )
                }
                calendar.color = color
            }

            do {
                try self.eventStore.saveCalendar(calendar, commit: true)
            } catch {
                log.error("Failed to create reminder list: \(error.localizedDescription)")
                throw error
            }

            return Value.object([
                "title": .string(calendar.title),
                "source": .string(calendar.source.title),
                "color": .string(calendar.color?.accessibilityName ?? "default"),
                "identifier": .string(calendar.calendarIdentifier),
                "isEditable": .bool(calendar.allowsContentModifications),
            ])
        }

        Tool(
            name: "reminders_sections",
            description: """
                List the sections (headings) within reminder lists, and which reminders \
                belong to each. Sections are not exposed by EventKit, so this reads the \
                local Reminders database and requires Full Disk Access. Counts are always \
                totals: every section's "count" plus "unsectionedCount" equals the list's \
                "totalCount", regardless of includeCompleted.
                """,
            inputSchema: .object(
                properties: [
                    "lists": .array(
                        description:
                            "Names of reminder lists to inspect; if empty, inspects all lists that have sections",
                        items: .string()
                    ),
                    "includeReminders": .boolean(
                        description: "Include the reminders in each section",
                        default: true
                    ),
                    "includeCompleted": .boolean(
                        description:
                            "List completed reminders too. Counts always include them either way",
                        default: true
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Sections",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var requestedNames: Set<String>? = nil
            if case .array(let listNames) = arguments["lists"], !listNames.isEmpty {
                requestedNames = Set(listNames.compactMap { $0.stringValue?.lowercased() })
            }

            var includeReminders = true
            if case .bool(let value) = arguments["includeReminders"] { includeReminders = value }

            var includeCompleted = true
            if case .bool(let value) = arguments["includeCompleted"] { includeCompleted = value }

            let database = try RemindersDatabase.open()
            var listSections = try database.listSections()
            if let requestedNames {
                listSections = listSections.filter {
                    requestedNames.contains($0.listName.lowercased())
                }
            }

            return try listSections.map { list in
                // Membership is walked reminder-first rather than section-first so
                // that (a) every live reminder is accounted for exactly once —
                // either under a section or in `unsectionedCount` — and (b) members
                // come out in the list's stored order instead of the arbitrary
                // order of a Dictionary's keys. Section-first also silently skipped
                // membership entries left behind by deleted reminders.
                let reminders = try database.reminders(inListWithIdentifier: list.listIdentifier)

                var membersBySection: [String: [RemindersDatabase.ReminderRow]] = [:]
                var unsectionedCount = 0
                for reminder in reminders {
                    if let sectionIdentifier =
                        list.sectionIdentifiersByReminder[reminder.identifier]
                    {
                        membersBySection[sectionIdentifier, default: []].append(reminder)
                    } else {
                        unsectionedCount += 1
                    }
                }

                let sections: [Value] = list.sections.map { section in
                    let members = membersBySection[section.identifier] ?? []

                    // Counts stay unfiltered so the totals always reconcile with
                    // reminders_fetch; `includeCompleted` only decides what gets
                    // listed. Filtering the counts made a list mid-way through
                    // being checked off look like it had lost most of its items.
                    var object: [String: Value] = [
                        "name": .string(section.name),
                        "identifier": .string(section.identifier),
                        "count": .int(members.count),
                    ]

                    if includeReminders {
                        object["reminders"] = .array(
                            members.filter { includeCompleted || !$0.isCompleted }
                                .map { reminder in
                                    .object([
                                        "title": .string(reminder.title),
                                        "identifier": .string(reminder.identifier),
                                        "isCompleted": .bool(reminder.isCompleted),
                                    ])
                                }
                        )
                    }

                    return .object(object)
                }

                return Value.object([
                    "list": .string(list.listName),
                    "identifier": .string(list.listIdentifier),
                    "sections": .array(sections),
                    "unsectionedCount": .int(unsectionedCount),
                    "totalCount": .int(reminders.count),
                ])
            }
        }

        Tool(
            name: "reminders_templates",
            description: """
                List saved Reminders templates, optionally with the items and sections \
                a template contains. Templates are not exposed by EventKit, so this reads \
                the local Reminders database and requires Full Disk Access. Use \
                reminders_save_as_template and reminders_apply_template to create \
                templates and lists from them.
                """,
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description:
                            "Name of a single template to describe in full; if omitted, all templates are summarized"
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Templates",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var requestedName: String? = nil
            if case .string(let name) = arguments["name"], !name.isEmpty { requestedName = name }

            let database = try RemindersDatabase.open()
            let templates = try database.templates(
                matching: requestedName,
                includeItems: requestedName != nil
            )

            if requestedName != nil, templates.isEmpty {
                throw NSError(
                    domain: "RemindersError",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No template named \"\(requestedName ?? "")\" was found"
                    ]
                )
            }

            let itemCounts = try database.templateItemCounts()
            let formatter = ISO8601DateFormatter()

            return templates.map { template in
                var object: [String: Value] = [
                    "name": .string(template.name),
                    "identifier": .string(template.identifier),
                    "sectionCount": .int(template.sections.count),
                    "itemCount": .int(itemCounts[template.identifier] ?? template.items.count),
                ]

                if let created = template.created {
                    object["created"] = .string(formatter.string(from: created))
                }
                if let modified = template.modified {
                    object["modified"] = .string(formatter.string(from: modified))
                }

                guard requestedName != nil else { return Value.object(object) }

                let itemsByIdentifier = Dictionary(
                    template.items.map { ($0.identifier, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                func item(_ templateItem: RemindersDatabase.TemplateItem) -> Value {
                    var itemObject: [String: Value] = [
                        "title": .string(templateItem.title)
                    ]
                    if let parentIdentifier = templateItem.parentIdentifier,
                        let parent = itemsByIdentifier[parentIdentifier]
                    {
                        itemObject["parent"] = .string(parent.title)
                    }
                    return .object(itemObject)
                }

                // Item-first for the same reasons as reminders_sections above:
                // every item lands in exactly one bucket, in stored order.
                var itemsBySection: [String: [RemindersDatabase.TemplateItem]] = [:]
                var unsectionedItems: [RemindersDatabase.TemplateItem] = []
                for templateItem in template.items {
                    if let sectionIdentifier =
                        template.sectionIdentifiersByItem[templateItem.identifier]
                    {
                        itemsBySection[sectionIdentifier, default: []].append(templateItem)
                    } else {
                        unsectionedItems.append(templateItem)
                    }
                }

                object["sections"] = .array(
                    template.sections.map { section in
                        .object([
                            "name": .string(section.name),
                            "identifier": .string(section.identifier),
                            "items": .array((itemsBySection[section.identifier] ?? []).map(item)),
                        ])
                    }
                )

                object["unsectionedItems"] = .array(unsectionedItems.map(item))

                return Value.object(object)
            }
        }

        Tool(
            name: "reminders_create_section",
            description: """
                Add a section (heading) to an existing reminder list. \(privateAPIWarning)
                """,
            inputSchema: .object(
                properties: [
                    "list": .string(description: "Name of the list to add the section to"),
                    "name": .string(description: "Name of the new section"),
                ],
                required: ["list", "name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder Section",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            try self.requireAuthorization()

            let listName = try Self.requireName(arguments, "list")
            let sectionName = try Self.requireName(arguments, "name")

            let list = try self.resolveList(named: listName)
            let existing = try self.sections(ofListWithIdentifier: list.calendarIdentifier)

            guard
                !existing.contains(where: {
                    $0.name.caseInsensitiveCompare(sectionName) == .orderedSame
                })
            else {
                throw RemindersWriteError.sectionAlreadyExists(
                    section: sectionName,
                    list: list.title
                )
            }

            let identifier = try IMCPReminderKit.createSection(
                inList: list.calendarIdentifier,
                existingSectionIdentifiers: existing.map(\.identifier),
                displayName: sectionName
            )

            return Value.object([
                "list": .string(list.title),
                "name": .string(sectionName),
                "identifier": .string(identifier),
                "position": .int(existing.count + 1),
            ])
        }

        Tool(
            name: "reminders_rename_section",
            description: """
                Rename a section on a reminder list. The section is matched by its exact \
                current name. \(privateAPIWarning)
                """,
            inputSchema: .object(
                properties: [
                    "list": .string(description: "Name of the list the section is on"),
                    "section": .string(description: "Current name of the section"),
                    "newName": .string(description: "New name for the section"),
                ],
                required: ["list", "section", "newName"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Rename Reminder Section",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            try self.requireAuthorization()

            let listName = try Self.requireName(arguments, "list")
            let sectionName = try Self.requireName(arguments, "section")
            let newName = try Self.requireName(arguments, "newName")

            let list = try self.resolveList(named: listName)
            let section = try self.resolveSection(named: sectionName, on: list)

            if newName != section.name {
                let existing = try self.sections(ofListWithIdentifier: list.calendarIdentifier)
                guard
                    !existing.contains(where: {
                        $0.identifier != section.identifier
                            && $0.name.caseInsensitiveCompare(newName) == .orderedSame
                    })
                else {
                    throw RemindersWriteError.sectionAlreadyExists(
                        section: newName,
                        list: list.title
                    )
                }
            }

            try IMCPReminderKit.renameSection(identifier: section.identifier, name: newName)

            return Value.object([
                "list": .string(list.title),
                "previousName": .string(section.name),
                "name": .string(newName),
                "identifier": .string(section.identifier),
            ])
        }

        Tool(
            name: "reminders_delete_section",
            description: """
                Delete a section from a reminder list, matched by its exact name. The \
                section's reminders are kept — they stay on the list and become \
                unsectioned. \(privateAPIWarning)
                """,
            inputSchema: .object(
                properties: [
                    "list": .string(description: "Name of the list the section is on"),
                    "section": .string(description: "Name of the section to delete"),
                ],
                required: ["list", "section"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder Section",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            try self.requireAuthorization()

            let listName = try Self.requireName(arguments, "list")
            let sectionName = try Self.requireName(arguments, "section")

            let list = try self.resolveList(named: listName)
            let section = try self.resolveSection(named: sectionName, on: list)

            try IMCPReminderKit.deleteSection(identifier: section.identifier)

            return Value.object([
                "list": .string(list.title),
                "deletedSection": .string(section.name),
                "identifier": .string(section.identifier),
                "note": .string(
                    "Reminders that were in this section are still on the list; they are now "
                        + "unsectioned."
                ),
            ])
        }

        Tool(
            name: "reminders_save_as_template",
            description: """
                Save an existing reminder list as a new template, preserving its sections \
                and items. \(privateAPIWarning)
                """,
            inputSchema: .object(
                properties: [
                    "list": .string(description: "Name of the list to save"),
                    "templateName": .string(description: "Name for the new template"),
                    "includeCompleted": .boolean(
                        description: "Include completed reminders in the template",
                        default: false
                    ),
                ],
                required: ["list", "templateName"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Save Reminder List as Template",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            try self.requireAuthorization()

            let listName = try Self.requireName(arguments, "list")
            let templateName = try Self.requireName(arguments, "templateName")

            var includeCompleted = false
            if case .bool(let value) = arguments["includeCompleted"] { includeCompleted = value }

            let list = try self.resolveList(named: listName)

            guard try !self.templateExists(named: templateName) else {
                throw RemindersWriteError.templateAlreadyExists(templateName)
            }

            let identifier = try IMCPReminderKit.createTemplate(
                named: templateName,
                fromList: list.calendarIdentifier,
                includeCompleted: includeCompleted
            )

            return Value.object([
                "name": .string(templateName),
                "identifier": .string(identifier),
                "sourceList": .string(list.title),
                "includeCompleted": .bool(includeCompleted),
            ])
        }

        Tool(
            name: "reminders_apply_template",
            description: """
                Create a new reminder list from a saved template, matched by its exact \
                name, then rename the result. The list arrives with the template's \
                sections and items. \(privateAPIWarning)
                """,
            inputSchema: .object(
                properties: [
                    "templateName": .string(description: "Name of the template to apply"),
                    "newListName": .string(description: "Name for the list to create"),
                ],
                required: ["templateName", "newListName"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder List from Template",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            try self.requireAuthorization()

            let templateName = try Self.requireName(arguments, "templateName")
            let newListName = try Self.requireName(arguments, "newListName")

            let template = try self.resolveTemplate(named: templateName)

            guard
                !self.eventStore.calendars(for: .reminder)
                    .contains(where: { $0.title.caseInsensitiveCompare(newListName) == .orderedSame
                    })
            else {
                throw RemindersWriteError.listAlreadyExists(newListName)
            }

            // ReminderKit gives the new list the *template's* name and offers no
            // way to override it, so renaming is a second, separate step.
            let identifier = try IMCPReminderKit.createList(fromTemplate: template.identifier)

            var renamed = true
            do {
                try IMCPReminderKit.renameList(identifier: identifier, name: newListName)
            } catch {
                renamed = false
                log.error(
                    "Created list from template but could not rename it: \(error.localizedDescription)"
                )
            }

            // Reminders fills the new list in asynchronously, so its sections can
            // take a moment to appear. Give them a brief chance before reporting.
            var sectionCount = 0
            for attempt in 0 ..< 10 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
                sectionCount = (try? self.sections(ofListWithIdentifier: identifier).count) ?? 0
                if sectionCount > 0 { break }
            }

            var result: [String: Value] = [
                "list": .string(renamed ? newListName : template.name),
                "identifier": .string(identifier),
                "template": .string(template.name),
                "sectionCount": .int(sectionCount),
            ]
            if !renamed {
                result["warning"] = .string(
                    "The list was created but could not be renamed, so it still has the "
                        + "template's name \"\(template.name)\"."
                )
            }
            return Value.object(result)
        }

        Tool(
            name: "reminders_delete_template",
            description: """
                Delete a saved Reminders template, matched by its exact name. Lists that \
                were already created from it are not affected. \(privateAPIWarning)
                """,
            inputSchema: .object(
                properties: [
                    "templateName": .string(description: "Name of the template to delete")
                ],
                required: ["templateName"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder Template",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            try self.requireAuthorization()

            let templateName = try Self.requireName(arguments, "templateName")
            let template = try self.resolveTemplate(named: templateName)

            try IMCPReminderKit.deleteTemplate(identifier: template.identifier)

            return Value.object([
                "deletedTemplate": .string(template.name),
                "identifier": .string(template.identifier),
            ])
        }
    }
}
