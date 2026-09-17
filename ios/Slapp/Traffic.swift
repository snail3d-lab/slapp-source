import SwiftUI

/// One line of a session's live traffic — pi's console, pocket-sized.
struct TrafficEvent: Identifiable {
    let id: Int
    let type: String
    var text: String   // var: thinking deltas rewrite the tape in place
    let preview: String
    let ok: Bool?
    let phase: String?

    static let cap = 60
}

/// Streams a slappd session's event SSE — thinking traces, tools, the lot —
/// and carries the stop / run controls.
final class TrafficClient: ObservableObject {
    @Published var events: [TrafficEvent] = []
    @Published var running = false
    let slug: String
    private let sseURL: String
    private let actionBase: String
    private var task: Task<Void, Never>?
    private var seq = 0

    /// slappd-backed channels: webhook names the session; the SSE stream is
    /// the daemon's. The desktop session's channel points at the extension's
    /// own listener — its /traffic mirror plays the same shape. Non-failable:
    /// an unparsable webhook just yields a bar that stays quiet.
    init(webhook: String?, bridgeHost: String) {
        var slug0 = "main"
        var sse0 = ""
        let action0 = "http://\(bridgeHost):8123"
        if let wh = webhook {
            // dumb, safe parsing — substring index math has bitten us twice
            let parts = wh.split(separator: "/").map(String.init)
            if parts.count >= 4, parts.last == "slapp" || parts.last == "monocle",
               parts[parts.count - 3] == "api", parts[parts.count - 4] == "session" {
                let s = parts[parts.count - 2]
                if !s.isEmpty {
                    slug0 = s
                    sse0 = "http://\(bridgeHost):8123/api/session/\(s)/events"
                }
            } else if wh.hasSuffix("/monocle") || wh.hasSuffix("/slapp"),
                       let base = String(wh.dropLast(8)).trimmedURL {
                slug0 = "this session"
                sse0 = base + "/traffic"
            }
        }
        slug = slug0
        sseURL = sse0
        actionBase = action0
    }

    var streamable: Bool { !sseURL.isEmpty }

    func connect() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            var req = URLRequest(url: URL(string: sseURL)!)
            req.timeoutInterval = 3600
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let type = j["type"] as? String else { continue }
                    let ev = TrafficEvent(
                        id: seq, type: type,
                        text: String(j["text"] as? String ?? "").trimmed(type == "thinking" ? 1400 : 160),
                        preview: String(j["preview"] as? String ?? j["name"] as? String ?? "").trimmed(110),
                        ok: j["ok"] as? Bool,
                        phase: j["phase"] as? String)
                    if type == "user" || type == "done" { running = type == "user" }
                    await MainActor.run {
                        // thinking deltas coalesce into ONE evolving row —
                        // the ticker tape — instead of piling up lines
                        if type == "thinking", let last = events.last, last.type == "thinking" {
                            events[events.count - 1].text = ev.text
                        } else {
                            events.append(ev)
                            seq += 1
                            if events.count > TrafficEvent.cap { events.removeFirst(events.count - TrafficEvent.cap) }
                        }
                    }
                }
            } catch { /* stream dropped — the next open retries */ }
        }
    }

    func disconnect() { task?.cancel(); task = nil }

    /// the little stop button — kills the session's current run
    func abort() async {
        var r = URLRequest(url: URL(string: "\(actionBase)/api/session/\(slug)/abort")!)
        r.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: r)
    }

    /// the little run button — nudges it onward
    func nudge() async {
        var r = URLRequest(url: URL(string: "\(actionBase)/api/session/\(slug)/prompt")!)
        r.httpMethod = "POST"
        r.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        r.httpBody = "continue — finish what you were doing".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: r)
    }
}

extension String {
    var trimmedURL: String? {
        let s = self.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("http") ? s : nil
    }
    func trimmed(_ n: Int) -> String {
        let s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > n ? String(s.prefix(n)) + "…" : s
    }
}

/// a session's webhook — the door moved from /monocle to /slapp; both live
func isSessionWebhook(_ wh: String, slug: String) -> Bool {
    wh.contains("/api/session/\(slug)/slapp") || wh.contains("/api/session/\(slug)/monocle")
}
