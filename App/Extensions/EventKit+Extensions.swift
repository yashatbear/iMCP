import CoreLocation
import EventKit
import Foundation
import OSLog

private let log = Logger.service("eventkit")

extension EKAlarm {
    /// Builds `EKAlarm`s from the `alarms` argument shared by `calendar_events_create`
    /// and `reminders_create`, so the two tools stay in sync.
    ///
    /// Each array element is one of:
    ///   - an integer — shorthand for "N minutes before" (a negative relative offset);
    ///   - an object with `type` of `relative`, `absolute`, or `proximity`.
    ///
    /// A `proximity` alarm is a location-based trigger: it fires on arriving at
    /// (`proximity: "enter"`) or leaving (`proximity: "leave"`) a coordinate.
    /// The reminder/event data syncs via iCloud; the geofence itself fires on
    /// whichever signed-in device has Location Services enabled for the app.
    static func alarms(from value: Value?) -> [EKAlarm] {
        guard case .array(let configs) = value else { return [] }
        return configs.compactMap { alarm(from: $0) }
    }

    /// Builds a single `EKAlarm` from one element of the `alarms` argument.
    /// Returns `nil` when the element is malformed (and logs why).
    static func alarm(from value: Value) -> EKAlarm? {
        // Shorthand: a bare number is "that many minutes before".
        if let minutes = value.numericValue {
            return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
        }

        guard case .object(let config) = value else { return nil }

        var alarm: EKAlarm?

        let type = config["type"]?.stringValue ?? "relative"
        switch type {
        case "relative":
            if let minutes = config["minutes"]?.numericValue {
                // Positive `minutes` fires before the due date, so negate for `relativeOffset`.
                alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            } else {
                log.error("Relative alarm requires a numeric `minutes`")
            }

        case "absolute":
            if case .string(let datetimeStr) = config["datetime"] {
                if ISO8601DateFormatter.isDateOnlyISO8601String(datetimeStr) {
                    log.error(
                        "Absolute alarm datetime must include a time component: \(datetimeStr, privacy: .public)"
                    )
                } else if let absoluteDate = ISO8601DateFormatter.lenientDate(
                    fromISO8601String: datetimeStr
                ) {
                    alarm = EKAlarm(absoluteDate: absoluteDate)
                } else {
                    log.error(
                        "Absolute alarm datetime is not a valid ISO 8601 string: \(datetimeStr, privacy: .public)"
                    )
                }
            } else {
                log.error("Absolute alarm requires a `datetime` string")
            }

        case "proximity":
            if case .string(let locationTitle) = config["locationTitle"],
                let latitude = config["latitude"]?.numericValue,
                let longitude = config["longitude"]?.numericValue
            {
                let structuredLocation = EKStructuredLocation(title: locationTitle)
                structuredLocation.geoLocation = CLLocation(
                    latitude: latitude,
                    longitude: longitude
                )
                // Match the schema's documented default when `radius` is omitted;
                // an unset radius leaves the geofence at 0 m, which never fires.
                structuredLocation.radius = config["radius"]?.numericValue ?? 200

                let proximityAlarm = EKAlarm()
                proximityAlarm.structuredLocation = structuredLocation
                proximityAlarm.proximity =
                    (config["proximity"]?.stringValue ?? "enter") == "leave" ? .leave : .enter
                alarm = proximityAlarm
            } else {
                log.error("Proximity alarm requires locationTitle, latitude, and longitude")
            }

        default:
            log.error("Unexpected alarm type encountered: \(type, privacy: .public)")
            return nil
        }

        guard let alarm else { return nil }

        if case .string(let soundName) = config["sound"], Sound(rawValue: soundName) != nil {
            alarm.soundName = soundName
        }
        if case .string(let email) = config["emailAddress"], !email.isEmpty {
            alarm.emailAddress = email
        }

        return alarm
    }
}

extension Value {
    /// A `Double` for either a `.double` or an integer-valued `.int`.
    /// JSON numbers like `40` decode to `.int`, so coordinate/offset parsing
    /// must accept both.
    fileprivate var numericValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

extension EKEventAvailability {
    init(_ string: String) {
        switch string.lowercased() {
        case "busy": self = .busy
        case "free": self = .free
        case "tentative": self = .tentative
        case "unavailable": self = .unavailable
        default: self = .busy
        }
    }

    static var allCases: [EKEventAvailability] {
        return [.busy, .free, .tentative, .unavailable]
    }

    var stringValue: String {
        switch self {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        default: return "unknown"
        }
    }
}

extension EKEventStatus {
    init(_ string: String) {
        switch string.lowercased() {
        case "none": self = .none
        case "tentative": self = .tentative
        case "confirmed": self = .confirmed
        case "canceled": self = .canceled
        default: self = .none
        }
    }
}

extension EKRecurrenceFrequency {
    init(_ string: String) {
        switch string.lowercased() {
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default: self = .daily
        }
    }
}

extension EKReminderPriority {
    static func from(string: String) -> EKReminderPriority {
        switch string.lowercased() {
        case "high": return .high
        case "medium": return .medium
        case "low": return .low
        default: return .none
        }
    }

    static var allCases: [EKReminderPriority] {
        return [.none, .low, .medium, .high]
    }

    var stringValue: String {
        switch self {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        case .none: return "none"
        @unknown default: return "unknown"
        }
    }
}
