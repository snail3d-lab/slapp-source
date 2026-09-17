import SwiftUI

/// A destination for your voice: the connected session, a chat, anything the
/// bridge routes to. One tile in the grid, one play-by-play.
struct Channel: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let created: TimeInterval
    let last: HistoryEntry?
    var webhook: String = ""
    var previews: [HistoryEntry] = []   // recent entries — tiles shift between them

    static func == (a: Channel, b: Channel) -> Bool { a.id == b.id && a.last == b.last && a.name == b.name }
}

/// One line of a channel's play-by-play.
struct HistoryEntry: Identifiable, Equatable {
    let ts: Double
    let role: String   // "user" | "agent"
    let text: String
    let photo: String?
    let audio: String?

    var id: String { "\(ts)-\(role)" }

    static func == (a: HistoryEntry, b: HistoryEntry) -> Bool { a.ts == b.ts && a.role == b.role }

    var isUser: Bool { role == "user" }

    /// Short clock label — 4:51 PM style.
    var timeLabel: String {
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = d.timeIntervalSinceNow > -86400 ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: d)
    }
}

/// Channels decode from the bridge's /channels shape.
extension Channel {
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        self.name = (json["name"] as? String) ?? id
        self.kind = (json["kind"] as? String) ?? "default"
        self.created = (json["created"] as? Double) ?? 0
        self.webhook = (json["webhook"] as? String) ?? ""
        if let l = json["last"] as? [String: Any] {
            self.last = HistoryEntry(json: l)
        } else {
            self.last = nil
        }
    }
}

extension HistoryEntry {
    init?(json: [String: Any]) {
        guard let ts = (json["ts"] as? Double) ?? (json["ts"] as? Int).map(Double.init),
              let role = json["role"] as? String else { return nil }
        self.ts = ts
        self.role = role
        self.text = (json["text"] as? String) ?? ""
        self.photo = json["photo"] as? String
        self.audio = json["audio"] as? String
    }
}

// MARK: - Cells color math (same djb2 → painterly hue as the fleet)

enum ChannelColor {
    static let alive = Color(red: 0.78, green: 0.90, blue: 0.28)

    private static let hues: [Double]    = [0.53, 0.58, 0.40, 0.19, 0.08, 0.97, 0.14, 0.45]
    private static let sats: [Double]    = [0.62, 0.55, 0.58, 0.85, 0.95, 0.78, 0.88, 0.50]

    /// Deterministic painterly hue from a channel id (BigInt-free 64-bit wrap).
    static func tint(for id: String) -> Color {
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        let i = Int(h % 8)
        return Color(hue: hues[i], saturation: sats[i], brightness: 0.93)
    }

    /// the same painterly hue, softened — crossbars wear pastels
    static func pastel(for id: String) -> Color {
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        let i = Int(h % 8)
        return Color(hue: hues[i], saturation: 0.55, brightness: 0.92)
    }

    /// a new line gets a new color — cycled by position, never repeating
    /// until the box of eight is used up
    static func pastel(at index: Int) -> Color {
        Color(hue: hues[index % hues.count], saturation: 0.55, brightness: 0.92)
    }

    static func glyph(for kind: String) -> String {
        switch kind {
        case "harness": return "bolt.fill"       // a live session
        case "chat": return "bubble.left.fill"   // telegram / discord
        default: return "dot.radiowaves.left.and.right" // main route
        }
    }
}

// MARK: - Linkified text (tappable URLs inside any bubble)

func linkified(_ s: String) -> AttributedString {
    let base = NSMutableAttributedString(string: s)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(location: 0, length: (s as NSString).length)
    let out = NSMutableAttributedString(attributedString: base)
    detector?.enumerateMatches(in: s, range: range) { m, _, _ in
        guard let m, let url = m.url else { return }
        out.addAttribute(.link, value: url, range: m.range)
    }
    return AttributedString(out)
}

/// Relative-ish time for tile previews.
func agoLabel(_ ts: Double) -> String {
    let dt = Date().timeIntervalSince1970 - ts
    if dt < 60 { return "now" }
    if dt < 3600 { return "\(Int(dt / 60))m" }
    if dt < 86400 { return "\(Int(dt / 3600))h" }
    return "\(Int(dt / 86400))d"
}
