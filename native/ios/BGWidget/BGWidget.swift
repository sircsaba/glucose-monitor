// Home-screen and lock-screen widget with the latest glucose.
// It fetches the reading from your server by itself (about every 5 to 15
// minutes, as iOS allows), even when the app is closed.
// Set it up: long-press the widget › Edit Widget › site address and token.
import AppIntents
import SwiftUI
import WidgetKit

struct BGConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Glucose"
    static var description = IntentDescription("The latest glucose reading from your server.")

    @Parameter(title: "Site address", default: "")
    var site: String

    @Parameter(title: "Token", default: "")
    var token: String

    @Parameter(title: "Show mmol/L", default: true)
    var mmol: Bool
}

struct BGEntry: TimelineEntry {
    var date: Date
    var mg: Int?
    var direction: String = ""
    var delta: Int?
    var when: Date?
    var mmol: Bool = true
    var message: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BGEntry {
        BGEntry(date: .now, mg: 110, direction: "Flat", delta: 2, when: .now)
    }

    func snapshot(for configuration: BGConfig, in context: Context) async -> BGEntry {
        if context.isPreview && configuration.site.isEmpty { return placeholder(in: context) }
        return await load(configuration)
    }

    func timeline(for configuration: BGConfig, in context: Context) async -> Timeline<BGEntry> {
        let e = await load(configuration)
        var entries = [e]
        // Grey it out by itself when the reading gets old.
        if let w = e.when {
            let staleAt = w.addingTimeInterval(BGView.staleAfter)
            if staleAt > .now {
                var s = e
                s.date = staleAt
                entries.append(s)
            }
        }
        return Timeline(entries: entries, policy: .after(.now.addingTimeInterval(5 * 60)))
    }

    private func load(_ c: BGConfig) async -> BGEntry {
        var site = c.site.trimmingCharacters(in: .whitespacesAndNewlines)
        if site.isEmpty {
            return BGEntry(date: .now, mmol: c.mmol, message: "Hold › Edit Widget")
        }
        if !site.lowercased().hasPrefix("http") { site = "https://" + site }
        while site.hasSuffix("/") { site.removeLast() }
        guard var comps = URLComponents(string: site + "/api/v1/entries/sgv.json") else {
            return BGEntry(date: .now, mmol: c.mmol, message: "Check the address")
        }
        var q = [URLQueryItem(name: "count", value: "12")]
        let token = c.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { q.append(URLQueryItem(name: "token", value: token)) }
        comps.queryItems = q
        guard let url = comps.url else {
            return BGEntry(date: .now, mmol: c.mmol, message: "Check the address")
        }
        let cacheKey = "last-" + site
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode == 401 || h.statusCode == 403 {
                return BGEntry(date: .now, mmol: c.mmol, message: "Check the token")
            }
            let list = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            guard let first = list.first,
                  let mg = (first["sgv"] as? NSNumber)?.intValue,
                  let ms = (first["date"] as? NSNumber)?.doubleValue else {
                return BGEntry(date: .now, mmol: c.mmol, message: "No readings yet")
            }
            // Change over 5 minutes: the reading closest to 5 minutes before.
            var delta: Int?
            var best = Double.greatestFiniteMagnitude
            for o in list.dropFirst() {
                guard let s = (o["sgv"] as? NSNumber)?.intValue, let d = (o["date"] as? NSNumber)?.doubleValue else { continue }
                let gap = ms - d
                if gap < 150_000 || gap > 450_000 { continue }
                if abs(gap - 300_000) < best { best = abs(gap - 300_000); delta = mg - s }
            }
            let dir = first["direction"] as? String ?? ""
            UserDefaults.standard.set(["mg": mg, "ms": ms, "dir": dir, "delta": delta ?? Int.min], forKey: cacheKey)
            return BGEntry(date: .now, mg: mg, direction: dir, delta: delta,
                           when: Date(timeIntervalSince1970: ms / 1000), mmol: c.mmol)
        } catch {
            // No network: the last reading, which turns grey when it is old.
            if let d = UserDefaults.standard.dictionary(forKey: cacheKey),
               let mg = d["mg"] as? Int, let ms = d["ms"] as? Double {
                let delta = d["delta"] as? Int
                return BGEntry(date: .now, mg: mg, direction: d["dir"] as? String ?? "",
                               delta: delta == Int.min ? nil : delta,
                               when: Date(timeIntervalSince1970: ms / 1000), mmol: c.mmol)
            }
            return BGEntry(date: .now, mmol: c.mmol, message: "Server not reachable")
        }
    }
}

struct BGView: View {
    static let staleAfter: TimeInterval = 15 * 60
    @Environment(\.widgetFamily) var family
    let e: BGEntry

    var stale: Bool {
        guard let w = e.when else { return true }
        return e.date.timeIntervalSince(w) >= BGView.staleAfter
    }

    var color: Color {
        guard let mg = e.mg, !stale else { return .gray }
        if mg < 70 { return Color(red: 1, green: 0.32, blue: 0.32) }
        if mg <= 180 { return Color(red: 0.30, green: 0.69, blue: 0.31) }
        if mg <= 250 { return Color(red: 1, green: 0.76, blue: 0.03) }
        return Color(red: 1, green: 0.32, blue: 0.32)
    }

    var bg: String {
        guard let mg = e.mg else { return "--" }
        return e.mmol ? String(format: "%.1f", Double(mg) / 18.0) : "\(mg)"
    }

    var arrow: String {
        if e.mg != nil && stale { return "⚠" }
        switch e.direction {
        case "DoubleUp": return "⇈"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown": return "↓"
        case "DoubleDown": return "⇊"
        default: return ""
        }
    }

    var delta: String {
        guard let d = e.delta, !stale else { return "" }
        return e.mmol ? String(format: "%+.1f", Double(d) / 18.0) : String(format: "%+d", d)
    }

    var body: some View {
        content.containerBackground(for: .widget) {
            Color(red: 0.05, green: 0.07, blue: 0.09)
        }
    }

    @ViewBuilder var content: some View {
        switch family {
        case .accessoryInline:
            Text("\(bg) \(arrow) \(delta)")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text(bg).font(.system(size: 20, weight: .bold)).minimumScaleFactor(0.6)
                Text(arrow).font(.system(size: 14, weight: .bold))
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bg).font(.system(size: 30, weight: .bold))
                    Text(arrow).font(.system(size: 22, weight: .bold))
                    Text(delta).font(.system(size: 15))
                }
                if let w = e.when {
                    Text(w, style: .relative).font(.system(size: 12))
                } else if let m = e.message {
                    Text(m).font(.system(size: 12))
                }
            }
        default:
            VStack(spacing: 2) {
                Text(bg)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(arrow).font(.system(size: 24, weight: .bold))
                    Text(delta).font(.system(size: 16))
                }
                .foregroundStyle(.white)
                if let w = e.when {
                    HStack(spacing: 4) {
                        Text(w, style: .time)
                        Text("·")
                        Text(w, style: .relative)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                } else if let m = e.message {
                    Text(m).font(.system(size: 12)).foregroundStyle(Color(white: 0.62))
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

struct BGWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "BGWidget", intent: BGConfig.self, provider: Provider()) { entry in
            BGView(e: entry)
        }
        .configurationDisplayName("Glucose")
        .description("The latest glucose reading.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

@main
struct BGWidgets: WidgetBundle {
    var body: some Widget {
        BGWidget()
    }
}
