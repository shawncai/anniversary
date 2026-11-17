import SwiftUI
import WidgetKit
import AppIntents
import CoreText

private let shiriFontsRegistered: Void = {
    for weight in ["light", "regular", "medium"] {
        if let url = Bundle.main.url(forResource: "source_han_sans_cn_" + weight, withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}()

private func shiriFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    _ = shiriFontsRegistered
    let face = weight == .light ? "Light" : (weight == .medium || weight == .semibold ? "Medium" : "Regular")
    return .custom("SourceHanSansCN-" + face, size: size)
}

private let shiriWidgetKind = "ShiriAnniversary"
private let shiriGroup = "group.com.shiri.anniversary"

struct ShiriWidgetEvent: Codable, Identifiable {
    let id: String
    let title: String
    let startDate: String
    let repeatYearly: Bool?
    let coverPath: String?
    let lightText: Bool
}

private struct ShiriWidgetSnapshot: Decodable {
    let version: Int
    let selectedEventId: String?
    let events: [ShiriWidgetEvent]
}

private enum ShiriWidgetStore {
    static func snapshot() -> ShiriWidgetSnapshot? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: shiriGroup),
              let data = try? Data(contentsOf: container.appendingPathComponent("snapshot.json")), data.count <= 2_000_000,
              let value = try? JSONDecoder().decode(ShiriWidgetSnapshot.self, from: data), value.version == 1 else { return nil }
        return value
    }

    static func event(id: String? = nil) -> ShiriWidgetEvent? {
        guard let snapshot = snapshot() else { return nil }
        return snapshot.events.first { $0.id == (id ?? snapshot.selectedEventId) } ?? snapshot.events.first
    }

    static func image(for event: ShiriWidgetEvent?) -> UIImage? {
        guard let path = event?.coverPath,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: shiriGroup) else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(container.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

struct ShiriWidgetEntry: TimelineEntry {
    let date: Date
    let event: ShiriWidgetEvent?
    var days: ShiriAnniversaryDays? { event.flatMap { ShiriAnniversaryDays(start: $0.startDate, today: date, repeatYearly: $0.repeatYearly ?? true) } }
}

private func shiriTimeline(event: ShiriWidgetEvent?) -> Timeline<ShiriWidgetEntry> {
    let now = Date()
    let calendar = Calendar(identifier: .gregorian)
    let midnight = calendar.startOfDay(for: now)
    var entries = [ShiriWidgetEntry(date: now, event: event)]
    for offset in 1...16 {
        if let date = calendar.date(byAdding: .day, value: offset, to: midnight) {
            entries.append(ShiriWidgetEntry(date: date, event: event))
        }
    }
    return Timeline(entries: entries, policy: .atEnd)
}

private struct ShiriLegacyProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShiriWidgetEntry { ShiriWidgetEntry(date: Date(), event: nil) }
    func getSnapshot(in context: Context, completion: @escaping (ShiriWidgetEntry) -> Void) {
        completion(ShiriWidgetEntry(date: Date(), event: ShiriWidgetStore.event()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShiriWidgetEntry>) -> Void) {
        completion(shiriTimeline(event: ShiriWidgetStore.event()))
    }
}

@available(iOS 17.0, *)
struct ShiriEventEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "纪念日")
    static var defaultQuery = ShiriEventQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

@available(iOS 17.0, *)
struct ShiriEventQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ShiriEventEntity] {
        (ShiriWidgetStore.snapshot()?.events ?? []).filter { identifiers.contains($0.id) }.map { ShiriEventEntity(id: $0.id, title: $0.title) }
    }
    func suggestedEntities() async throws -> [ShiriEventEntity] {
        (ShiriWidgetStore.snapshot()?.events ?? []).map { ShiriEventEntity(id: $0.id, title: $0.title) }
    }
    func defaultResult() async -> ShiriEventEntity? {
        guard let event = ShiriWidgetStore.event() else { return nil }
        return ShiriEventEntity(id: event.id, title: event.title)
    }
}

@available(iOS 17.0, *)
struct ShiriWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择纪念日"
    static var description = IntentDescription("将一个纪念日添加到桌面或锁定屏幕。")
    @Parameter(title: "纪念日") var event: ShiriEventEntity?
}

@available(iOS 17.0, *)
private struct ShiriIntentProvider: AppIntentTimelineProvider {
    typealias Intent = ShiriWidgetIntent
    func placeholder(in context: Context) -> ShiriWidgetEntry { ShiriWidgetEntry(date: Date(), event: nil) }
    func snapshot(for configuration: ShiriWidgetIntent, in context: Context) async -> ShiriWidgetEntry {
        ShiriWidgetEntry(date: Date(), event: ShiriWidgetStore.event(id: configuration.event?.id))
    }
    func timeline(for configuration: ShiriWidgetIntent, in context: Context) async -> Timeline<ShiriWidgetEntry> {
        shiriTimeline(event: ShiriWidgetStore.event(id: configuration.event?.id))
    }
}

private struct ShiriWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ShiriWidgetEntry
    private let accent = Color(red: 0.29, green: 0.25, blue: 1)
    private var photo: UIImage? { ShiriWidgetStore.image(for: entry.event) }
    private var ink: Color { photo == nil ? .primary : (entry.event?.lightText == false ? .black : .white) }
    private var deepLink: URL? {
        guard let id = entry.event?.id else { return URL(string: "shiri://anniversary/new") }
        var components = URLComponents(); components.scheme = "shiri"; components.host = "anniversary"; components.path = "/" + id
        return components.url
    }

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessory
                    .shiriBackground { Color.clear }
            } else {
                content
                    .foregroundStyle(ink)
                    .padding(family == .systemSmall ? 14 : 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .shiriBackground { background }
            }
        }
        .widgetURL(deepLink)
    }

    @ViewBuilder private var content: some View {
        if let event = entry.event, let days = entry.days {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
                Text(event.title).font(shiriFont(family == .systemSmall ? 14 : 19, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text((event.repeatYearly == false && days.elapsed > 0 ? days.elapsed : days.remaining).formatted()).font(shiriFont(numberSize, weight: .light)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                    Text(event.repeatYearly == false && days.elapsed > 0 ? "天前" : (days.remaining == 0 ? "就是今天" : "天后")).font(shiriFont(family == .systemSmall ? 12 : 17, weight: .medium)).lineLimit(1)
                }
                if family == .systemLarge {
                    Rectangle().fill(accent).frame(width: 25, height: 3).padding(.vertical, 8)
                }
                Text(days.nextDate, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                    .font(shiriFont(family == .systemSmall ? 11 : 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: family == .systemLarge ? 20 : 0)
                Text("已经走过 \(days.elapsed.formatted()) 天")
                    .font(shiriFont(family == .systemSmall ? 11 : 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "calendar").font(.system(size: 24)).foregroundStyle(accent)
                Spacer(minLength: 0)
                Text("添加纪念日").font(shiriFont(17, weight: .medium))
                Text("轻点开始记录").font(shiriFont(12)).foregroundStyle(.secondary)
            }
        }
    }

    private var numberSize: CGFloat { family == .systemSmall ? 48 : (family == .systemLarge ? 94 : 60) }

    @ViewBuilder private var accessory: some View {
        if let event = entry.event, let days = entry.days {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(shiriFont(15, weight: .medium)).lineLimit(1)
                Text(event.repeatYearly == false && days.elapsed > 0 ? "\(days.elapsed) 天前" : (days.remaining == 0 ? "就是今天" : "\(days.remaining) 天后")).font(shiriFont(22, weight: .medium)).monospacedDigit()
                Text("已经走过 \(days.elapsed) 天").font(shiriFont(11)).lineLimit(1)
            }.minimumScaleFactor(0.6).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label("添加纪念日", systemImage: "calendar").font(shiriFont(15, weight: .medium))
        }
    }

    @ViewBuilder private var background: some View {
        if let image = photo {
            GeometryReader { geometry in
                Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay {
                        LinearGradient(colors: entry.event?.lightText == false ? [.white.opacity(0.2), .white.opacity(0.36)] : [.black.opacity(0.15), .black.opacity(0.46)], startPoint: .top, endPoint: .bottom)
                    }
            }
        } else { Color(uiColor: .systemBackground) }
    }
}

private extension View {
    @ViewBuilder func shiriBackground<Background: View>(@ViewBuilder background: () -> Background) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(for: .widget, content: background)
        } else { self.background(background()) }
    }
}

private struct ShiriLegacyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: shiriWidgetKind, provider: ShiriLegacyProvider()) { ShiriWidgetView(entry: $0) }
            .configurationDisplayName("纪念日")
            .description("下一次相逢，还有多少天。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

@available(iOS 17.0, *)
private struct ShiriConfigurableWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ShiriAnniversarySelected", intent: ShiriWidgetIntent.self, provider: ShiriIntentProvider()) { ShiriWidgetView(entry: $0) }
            .configurationDisplayName("自选纪念日")
            .description("下一次相逢，还有多少天。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
            .contentMarginsDisabled()
    }
}

@main
struct ShiriWidgets: WidgetBundle {
    var body: some Widget {
        ShiriLegacyWidget()
        if #available(iOS 17.0, *) {
            ShiriConfigurableWidget()
        }
    }
}
