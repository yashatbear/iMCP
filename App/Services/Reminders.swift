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
            description: "Create a new reminder with specified properties",
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
                    "notes": .string(),
                    "priority": .string(
                        default: .string(EKReminderPriority.none.stringValue),
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Minutes before due date to set alarms",
                        items: .integer()
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

            // Set calendar (list)
            var calendar = self.eventStore.defaultCalendarForNewReminders()
            if case .string(let listName) = arguments["list"] {
                if let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            reminder.calendar = calendar

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

            // Set alarms
            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case .int(let minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

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
                local Reminders database and requires Full Disk Access.
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
                        description: "Include completed reminders",
                        default: false
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

            var includeCompleted = false
            if case .bool(let value) = arguments["includeCompleted"] { includeCompleted = value }

            let database = try RemindersDatabase.open()
            var listSections = try database.listSections()
            if let requestedNames {
                listSections = listSections.filter {
                    requestedNames.contains($0.listName.lowercased())
                }
            }

            return try listSections.map { list in
                var remindersByIdentifier: [String: RemindersDatabase.ReminderRow] = [:]
                var unsectionedCount = 0

                // Reminders are always loaded so section counts stay accurate,
                // even when the caller doesn't want them listed.
                let reminders = try database.reminders(inListWithIdentifier: list.listIdentifier)
                for reminder in reminders where includeCompleted || !reminder.isCompleted {
                    remindersByIdentifier[reminder.identifier] = reminder
                    if list.sectionIdentifiersByReminder[reminder.identifier] == nil {
                        unsectionedCount += 1
                    }
                }

                let sections: [Value] = list.sections.map { section in
                    let members = section.memberIdentifiers.compactMap {
                        remindersByIdentifier[$0]
                    }

                    var object: [String: Value] = [
                        "name": .string(section.name),
                        "identifier": .string(section.identifier),
                        "count": .int(members.count),
                    ]

                    if includeReminders {
                        object["reminders"] = .array(
                            members.map { reminder in
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
                ])
            }
        }

        Tool(
            name: "reminders_templates",
            description: """
                List saved Reminders templates, optionally with the items and sections \
                a template contains. Templates are not exposed by EventKit, so this reads \
                the local Reminders database and requires Full Disk Access. Reading is \
                supported; creating a list from a template must still be done in the \
                Reminders app.
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

                object["sections"] = .array(
                    template.sections.map { section in
                        .object([
                            "name": .string(section.name),
                            "identifier": .string(section.identifier),
                            "items": .array(
                                section.memberIdentifiers.compactMap { itemsByIdentifier[$0] }
                                    .map(item)
                            ),
                        ])
                    }
                )

                object["unsectionedItems"] = .array(
                    template.items
                        .filter { template.sectionIdentifiersByItem[$0.identifier] == nil }
                        .map(item)
                )

                return Value.object(object)
            }
        }
    }
}
