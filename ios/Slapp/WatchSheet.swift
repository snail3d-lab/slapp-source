import SwiftUI
import AVFoundation

/// Talks to the daemon (slappd) — same Mac as the bridge, port 8123.
struct SlappClient {
    let base: String

    init(bridgeHost: String) {
        self.base = "http://\(bridgeHost):8123"
    }

    struct SessionRow: Identifiable {
        let slug: String
        let phase: String
        var id: String { slug }
    }

    struct WatchRow: Identifiable {
        let id: String
        let slug: String
        let goal: String
        let hours: Double
        let minutesLeft: Int
    }

    private func req(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = method
        r.timeoutInterval = 20
        return r
    }

    func sessions() async -> [SessionRow] {
        guard let (data, _) = try? await URLSession.shared.data(for: req("/api/health")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["sessions"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let slug = d["slug"] as? String else { return nil }
            return SessionRow(slug: slug, phase: d["phase"] as? String ?? "?")
        }
    }

    struct SearchHit: Identifiable {
        let slug: String
        let session: String
        let file: String
        let title: String
        let snippet: String
        let turns: Int
        let age: String
        var id: String { file }
    }

    func search(_ q: String) async -> [SearchHit] {
        var r = req("/api/search?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)")
        r.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["results"] as? [[String: Any]] else { return [] }
        let df = DateFormatter(); df.dateFormat = "MMM d HH:mm"
        return list.compactMap { d in
            guard let file = d["file"] as? String,
                  let slug = d["slug"] as? String else { return nil }
            let mtime = d["mtime"] as? Double ?? 0
            return SearchHit(slug: slug, session: d["session"] as? String ?? slug,
                             file: file,
                             title: (d["title"] as? String) ?? "(untitled)",
                             snippet: (d["snippet"] as? String) ?? "",
                             turns: d["turns"] as? Int ?? 0,
                             age: mtime > 0 ? df.string(from: Date(timeIntervalSince1970: mtime)) : "")
        }
    }

    func openSession(_ slug: String, file: String) async -> Bool {
        var r = req("/api/session/\(slug)/open", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 30
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["file": file])
        guard let (_, resp) = try? await URLSession.shared.data(for: r) as? (Data, HTTPURLResponse) else { return false }
        return (200..<300).contains(resp.statusCode)
    }

    /// slugs whose herdr space is closed on the Mac — safe, but asleep
    func asleepSlugs() async -> Set<String> {
        guard let (data, _) = try? await URLSession.shared.data(for: req("/api/health")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["sessions"] as? [[String: Any]] else { return [] }
        return Set(list.compactMap { d in
            (d["asleep"] as? Bool) == true ? (d["slug"] as? String) : nil
        })
    }

    func wake(_ slug: String) async -> (ok: Bool, note: String?) {
        var r = req("/api/session/\(slug)/wake", method: "POST")
        r.timeoutInterval = 30
        guard let (data, resp) = try? await URLSession.shared.data(for: r) as? (Data, HTTPURLResponse) else { return (false, nil) }
        if (200..<300).contains(resp.statusCode) { return (true, nil) }
        let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["error"] as? String }
        return (false, msg)
    }

    /// the phone lost its bridge identity — ask the Mac to open the bridge's
    /// pairing window so the re-register knock can land
    func openPairWindow() async {
        var r = req("/api/pairwindow", method: "POST")
        r.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: r)
    }

    /// the session cap: how many are live, and the max allowed
    func sessionCap() async -> (active: Int, max: Int)? {
        guard let (data, _) = try? await URLSession.shared.data(for: req("/api/health")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mx = j["maxSessions"] as? Int else { return nil }
        return (j["active"] as? Int ?? 0, mx)
    }

    func setMaxSessions(_ n: Int) async -> Bool {
        var r = req("/api/maxsessions", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["n": n])
        guard let (_, resp) = try? await URLSession.shared.data(for: r) as? (Data, HTTPURLResponse) else { return false }
        return (200..<300).contains(resp.statusCode)
    }

    func reveal(_ slug: String) async -> Bool {
        var r = req("/api/session/\(slug)/reveal", method: "POST")
        r.timeoutInterval = 15
        guard let (_, resp) = try? await URLSession.shared.data(for: r) as? (Data, HTTPURLResponse) else { return false }
        return (200..<300).contains(resp.statusCode)
    }

    func deleteSession(_ slug: String) async -> Bool {
        var r = req("/api/session/\(slug)/delete", method: "POST")
        r.timeoutInterval = 30
        guard let (_, resp) = try? await URLSession.shared.data(for: r) as? (Data, HTTPURLResponse) else { return false }
        return (200..<300).contains(resp.statusCode)
    }

    func watches() async -> [WatchRow] {
        guard let (data, _) = try? await URLSession.shared.data(for: req("/api/session/launcher/watch")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["watches"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let id = d["id"] as? String, let slug = d["slug"] as? String else { return nil }
            return WatchRow(id: id, slug: slug,
                            goal: d["goal"] as? String ?? "",
                            hours: d["hours"] as? Double ?? 0,
                            minutesLeft: d["minutesLeft"] as? Int ?? 0)
        }
    }

    func startWatch(slug: String, goal: String, hours: Double) async -> Bool {
        var r = req("/api/session/launcher/watch", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["slug": slug, "goal": goal, "hours": hours])
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return j["ok"] as? Bool == true
    }

    func stopWatch(_ id: String) async {
        var r = req("/api/session/launcher/watch", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["remove": id])
        _ = try? await URLSession.shared.data(for: r)
    }

    /// Raw wav → words. The daemon's session-less transcribe door.
    func transcribe(_ wav: Data) async -> String? {
        var r = req("/api/voice?format=wav", method: "POST")
        r.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        r.httpBody = wav
        r.timeoutInterval = 120
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let t = j["transcript"] as? String ?? ""
        return t.isEmpty ? nil : t
    }
}

/// The watch: tell it a goal and how long; the launcher keeps the thing going.
struct WatchSheet: View {
    var initialTarget: String? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = MicRecorder()
    @State private var client: SlappClient?
    @State private var sessions: [SlappClient.SessionRow] = []
    @State private var watches: [SlappClient.WatchRow] = []
    @State private var target: String? = nil
    @State private var goal = ""
    @State private var hours: Double = 2
    @State private var busy = false
    @State private var listening = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // goal, spoken or typed
                        VStack(alignment: .leading, spacing: 10) {
                            Text("the goal")
                                .font(.system(size: 13, weight: .medium, design: .serif))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 14) {
                                holdMic
                                TextField("say it or type it", text: $goal, axis: .vertical)
                                    .lineLimit(1...4)
                                    .font(.system(size: 15))
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.07)))
                            }
                        }
                        // which thing
                        VStack(alignment: .leading, spacing: 8) {
                            Text("which thing")
                                .font(.system(size: 13, weight: .medium, design: .serif))
                                .foregroundStyle(.secondary)
                            Menu {
                                ForEach(sessions.filter { $0.slug != "launcher" }) { s in
                                    Button(s.slug) { target = s.slug }
                                }
                            } label: {
                                HStack {
                                    Text(target ?? "pick a session")
                                        .font(.system(size: 15, design: .monospaced))
                                        .foregroundStyle(target == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.07)))
                            }
                        }
                        // how long
                        VStack(alignment: .leading, spacing: 8) {
                            Text("goes for")
                                .font(.system(size: 13, weight: .medium, design: .serif))
                                .foregroundStyle(.secondary)
                            Picker("hours", selection: $hours) {
                                ForEach([0.5, 1, 2, 4, 6, 8, 12], id: \.self) { h in
                                    Text(h == 0.5 ? "30 min" : "\(Int(h)) h").tag(h)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        Button {
                            guard let tgt = target, let client else { return }
                            busy = true
                            Task {
                                let ok = await client.startWatch(slug: tgt, goal: goal, hours: hours)
                                busy = false
                                if ok {
                                    goal = ""; target = nil
                                    await reload()
                                } else { error = "the watch didn't take — try again" }
                            }
                        } label: {
                            Text(busy ? "arming…" : "start the watch")
                                .font(.system(size: 15, weight: .semibold, design: .serif))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(RoundedRectangle(cornerRadius: 14)
                                    .fill(canStart ? ChannelColor.alive : Color(white: 0.15)))
                        }
                        .disabled(!canStart || busy)
                        if let error {
                            Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                        }
                        // already watching
                        if !watches.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("keeping watch")
                                    .font(.system(size: 13, weight: .medium, design: .serif))
                                    .foregroundStyle(.secondary)
                                ForEach(watches) { w in
                                    HStack(alignment: .top, spacing: 10) {
                                        Circle().fill(ChannelColor.alive).frame(width: 7, height: 7).padding(.top, 5)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(w.slug).font(.system(size: 14, weight: .semibold, design: .serif))
                                            Text("\(w.goal.prefix(80)) · \(w.minutesLeft) min left")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button {
                                            Task { await client?.stopWatch(w.id); await reload() }
                                        } label: {
                                            Image(systemName: "stop.circle")
                                                .font(.system(size: 18))
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.06)))
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("the watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
    }

    private var canStart: Bool { !goal.isEmpty && target != nil }

    private var holdMic: some View {
        ZStack {
            Circle().fill(Color(white: 0.07)).frame(width: 52, height: 52)
            Circle()
                .fill(listening ? ChannelColor.alive : Color(white: 0.2))
                .frame(width: 40, height: 40)
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(listening ? .black : .white)
        }
        .onLongPressGesture(minimumDuration: 3600, maximumDistance: 150) {} onPressingChanged: { pressing in
            if pressing {
                listening = true
                rec.start()
            } else {
                listening = false
                let wav = rec.stop()
                guard let wav else { return }
                busy = true
                Task {
                    if let text = await client?.transcribe(wav) {
                        goal = goal.isEmpty ? text : goal + " " + text
                    } else { error = "didn't catch that — type it instead" }
                    busy = false
                }
            }
        }
    }

    private func load() {
        let host = BridgeConfig().host
        client = SlappClient(bridgeHost: host)
        if target == nil { target = initialTarget }
        Task { await reload() }
    }

    private func reload() async {
        sessions = await client?.sessions() ?? []
        watches = await client?.watches() ?? []
    }
}

/// Standalone wav recorder for the watch's mic (16 kHz mono — the house format).
@MainActor
final class MicRecorder: ObservableObject {
    private let recorder = Recorder()

    func start() {
        do { try recorder.start() } catch { }
    }
    func stop() -> Data? { recorder.stop() }
}
