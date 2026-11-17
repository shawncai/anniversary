import EventKit
import Flutter
import Foundation

/// Only a local EventKit source is eligible. No default (possibly cloud) calendar.
final class ShiriCalendar {
    private let store = EKEventStore()
    private let work = DispatchQueue(label: "com.shiri.anniversary.calendar")
    private let prefs = UserDefaults.standard

    func sync(_ args: [String: Any], result: @escaping FlutterResult) {
        let enabled = args["reminderEnabled"] as? Bool ?? false
        let id = args["id"] as? String ?? ""
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            result(FlutterError(code: "calendar", message: "无效纪念日", details: nil)); return
        }
        if !enabled && prefs.string(forKey: "shiri-calendar-event-" + id) == nil { result("当天提醒已关闭"); return }
        let run: (Bool) -> Void = { granted in
            guard granted else {
                DispatchQueue.main.async { result(enabled ? "未允许日历权限，仅在打开拾日时提醒" : "提醒已在应用内关闭；请在系统日历检查已有提醒") }; return
            }
            self.work.async {
                do {
                    let message = try self.write(args)
                    DispatchQueue.main.async { result(message) }
                } catch {
                    DispatchQueue.main.async { result(FlutterError(code: "calendar", message: error.localizedDescription, details: nil)) }
                }
            }
        }
        let status = EKEventStore.authorizationStatus(for: .event)
        let authorized: Bool
        if #available(iOS 17.0, *) { authorized = status == .fullAccess } else { authorized = status == .authorized }
        if authorized { run(true) }
        else if enabled && args["requestPermissions"] as? Bool == true && status == .notDetermined {
            if #available(iOS 17.0, *) { store.requestFullAccessToEvents { granted, _ in run(granted) } }
            else { store.requestAccess(to: .event) { granted, _ in run(granted) } }
        } else { run(false) }
    }

    private func write(_ args: [String: Any]) throws -> String {
        let id = args["id"] as! String
        let enabled = args["reminderEnabled"] as? Bool ?? false
        let yearly = args["repeatYearly"] as? Bool ?? true
        guard let title = args["title"] as? String, !title.isEmpty, title.count <= 200,
              let dateText = args["startDate"] as? String else { throw error("无效纪念日") }
        let parts = dateText.split(separator: "-").compactMap { Int($0) }
        let minute = args["reminderMinute"] as? Int ?? 540
        guard parts.count == 3, (0..<1440).contains(minute), (1...9999).contains(parts[0]) else { throw error("无效提醒时间") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        guard let first = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              cal.component(.year, from: first) == parts[0], cal.component(.month, from: first) == parts[1], cal.component(.day, from: first) == parts[2] else { throw error("无效日期") }
        let today = cal.startOfDay(for: Date())
        func occurrence(_ year: Int) -> Date {
            let month = cal.date(from: DateComponents(year: year, month: parts[1], day: 1))!
            let lastDay = cal.range(of: .day, in: .month, for: month)!.count
            return cal.date(from: DateComponents(year: year, month: parts[1], day: min(parts[2], lastDay)))!
        }
        var day = first
        if yearly && first <= today {
            let year = cal.component(.year, from: today)
            day = occurrence(year)
            if day < today { day = occurrence(year + 1) }
        }
        guard let start = cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) else { throw error("无法设置提醒时间") }
        let calendars = store.calendars(for: .event).filter { $0.source.sourceType == .local && $0.allowsContentModifications }
        let local: EKCalendar
        if let owned = calendars.first(where: { $0.calendarIdentifier == prefs.string(forKey: "shiri-local-calendar") }) ?? calendars.first(where: { $0.title == "拾日 · 本机" }) {
            local = owned
        } else {
            guard let source = store.sources.first(where: { $0.sourceType == .local }) else {
                return "没有可用的本机日历，仅在打开拾日时提醒；未写入云端日历"
            }
            local = EKCalendar(for: .event, eventStore: store)
            local.title = "拾日 · 本机"; local.source = source
            try store.saveCalendar(local, commit: true)
        }
        prefs.set(local.calendarIdentifier, forKey: "shiri-local-calendar")
        let link = URL(string: "shiri://anniversary/" + id)!
        var existing = prefs.string(forKey: "shiri-calendar-event-" + id).flatMap { store.event(withIdentifier: $0) }
        if existing?.calendar.calendarIdentifier != local.calendarIdentifier || existing?.url != link { existing = nil }
        if existing == nil {
            let predicate = store.predicateForEvents(withStart: day, end: cal.date(byAdding: .day, value: 1, to: day)!, calendars: [local])
            existing = store.events(matching: predicate).first { $0.url == link }
        }
        let event = existing ?? EKEvent(eventStore: store)
        event.calendar = local; event.title = title; event.url = link
        event.startDate = start; event.endDate = start.addingTimeInterval(900)
        event.isAllDay = false; event.timeZone = .current
        event.recurrenceRules = yearly ? [EKRecurrenceRule(recurrenceWith: .yearly, interval: 1,
            daysOfTheWeek: nil, daysOfTheMonth: parts[1] == 2 && parts[2] == 29 ? [NSNumber(value: -1)] : nil,
            monthsOfTheYear: parts[1] == 2 && parts[2] == 29 ? [NSNumber(value: 2)] : nil,
            weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)] : nil
        // Use the public alarm API; the system stores default-alert placeholders
        // separately from the explicit alarms exposed by EventKit.
        for alarm in event.alarms ?? [] { event.removeAlarm(alarm) }
        if enabled { event.addAlarm(EKAlarm(relativeOffset: 0)) }
        try store.save(event, span: .futureEvents, commit: true)
        prefs.set(event.eventIdentifier, forKey: "shiri-calendar-event-" + id)
        if !enabled { return "当天提醒已关闭" }
        if !yearly && start < Date() { return "已加入本机日历；提醒时间已过，不会补发" }
        return yearly ? "已设置每年当天的本机日历提醒" : "已设置一次本机日历提醒"
    }

    #if targetEnvironment(simulator)
    // QA-only inspection of synthetic fixtures, through the supported EventKit
    // API. Default-alert rows in the simulator database are not active alarms.
    func verifyFixture(_ id: String, result: @escaping FlutterResult) {
        guard id.hasPrefix("qa-management-"),
              let identifier = prefs.string(forKey: "shiri-calendar-event-" + id) else {
            result(FlutterError(code: "qa_fixture", message: "Unknown QA fixture", details: nil)); return
        }
        work.async {
            let reader = EKEventStore()
            guard let event = reader.event(withIdentifier: identifier), event.url?.absoluteString == "shiri://anniversary/" + id, event.calendar.source.sourceType == .local else {
                DispatchQueue.main.async { result(FlutterError(code: "qa_fixture", message: "Missing local fixture", details: nil)) }; return
            }
            let alarms = event.alarms ?? []
            let data: [String: Any] = ["alarms": alarms.count, "offsets": alarms.map { $0.relativeOffset }, "yearly": event.recurrenceRules?.first?.frequency == .yearly, "local": true]
            DispatchQueue.main.async { result(data) }
        }
    }
    #endif

    private func error(_ message: String) -> NSError {
        NSError(domain: "ShiriCalendar", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
