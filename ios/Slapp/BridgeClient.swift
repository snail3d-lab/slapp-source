import Foundation

/// Bridge address + device identity, persisted in UserDefaults.
struct BridgeConfig {
    var host: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "bridge_host") ?? ""
            // the road, in order: what you set → the tailnet (works anywhere) → the house LAN
            if !saved.isEmpty && saved != "sensebridge.local" { return saved }
            return "snails-macbook-pro.tailae49b0.ts.net"
        }
        set { UserDefaults.standard.set(newValue, forKey: "bridge_host") }
    }

    var port: Int {
        get { UserDefaults.standard.object(forKey: "bridge_port") as? Int ?? 8651 }
        set { UserDefaults.standard.set(newValue, forKey: "bridge_port") }
    }

    /// Host is entered bare (no scheme) — always plain HTTP on the LAN.
    var baseURL: String { "http://\(host.trimmingCharacters(in: .whitespaces)):\(port)" }
}

enum DeviceIdentity {
    /// Stable id in the fleet convention: SLAPP-IOS-xxxx (older installs
    /// keep their stored MONOCLE-IOS identity — it still pairs fine).
    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: "device_id") { return existing }
        let suffix = String(format: "%04X", Int.random(in: 0..<0x10000))
        let id = "SLAPP-IOS-\(suffix)"
        UserDefaults.standard.set(id, forKey: "device_id")
        return id
    }
}

struct CaptureResult: Equatable {
    let cid: String
}

struct ChannelListResult {
    let channels: [Channel]
}

struct HistoryResult {
    let entries: [HistoryEntry]
}

enum BridgeError: LocalizedError {
    case badURL
    case notPaired
    case busy
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad bridge address"
        case .notPaired: return "Not paired — open a pairing window"
        case .busy: return "Bridge busy — retry shortly"
        case .http(let code, let msg): return "Bridge \(code): \(msg)"
        }
    }
}

/// Speaks the bridge protocol: /capture (voice/photo/text, channel-targeted),
/// /channels CRUD, /channels/<id>/history play-by-play, /register pairing.
struct BridgeClient {
    let baseURL: String
    let deviceID: String
    let token: String?

    init(config: BridgeConfig, deviceID: String, token: String?) {
        self.baseURL = config.baseURL
        self.deviceID = deviceID
        self.token = token
    }

    // MARK: - Multipart body (pure, unit-testable)

    static func multipartBody(boundary: String, audio: Data?, photo: Data?,
                              mode: String, device: String, channel: String? = nil,
                              text: String? = nil) -> Data {
        var d = Data()
        func append(_ s: String) { d.append(contentsOf: s.utf8) }
        if let audio {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.wav\"\r\n")
            append("Content-Type: audio/wav\r\n\r\n")
            d.append(audio)
            append("\r\n")
        }
        if let photo {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n")
            append("Content-Type: image/jpeg\r\n\r\n")
            d.append(photo)
            append("\r\n")
        }
        if let text {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
            append("\(text)\r\n")
        }
        if let channel {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"channel\"\r\n\r\n")
            append("\(channel)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"mode\"\r\n\r\n")
        append("\(mode)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"device\"\r\n\r\n")
        append("\(device)\r\n")
        append("--\(boundary)--\r\n")
        return d
    }

    // MARK: - Requests

    private func request(_ path: String, method: String, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw BridgeError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func decodeError(_ data: Data) -> String {
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = j["error"] as? String {
            return err
        }
        return String(data: data.prefix(120), encoding: .utf8) ?? ""
    }

    /// Voice capture (mode=voice), photo note, or typed text — all routed to a
    /// channel when one is given. Returns the capture id.
    func capture(audio: Data?, photo: Data? = nil, channel: String? = nil, text: String? = nil) async throws -> CaptureResult {
        let mode: String
        if photo != nil { mode = audio == nil ? "photo" : "voice_photo" }
        else { mode = "voice" }
        // "main" = the device default route — send no channel at all
        let chan = (channel == nil || channel == "main") ? nil : channel
        var req = try request("/capture", method: "POST", timeout: 600)
        let boundary = "slapp-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(boundary: boundary, audio: audio, photo: photo,
                                          mode: mode, device: deviceID, channel: chan, text: text)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 503 { throw BridgeError.busy }
            throw BridgeError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = j["cid"] as? String else { throw BridgeError.http(http.statusCode, "no cid") }
        return CaptureResult(cid: cid)
    }

    /// Typed input — same pipeline as voice, minus the microphone.
    func sendText(_ text: String, channel: String?) async throws -> CaptureResult {
        var req = try request("/text", method: "POST", timeout: 30)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text]
        if let channel, channel != "main" { body["channel"] = channel }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 503 { throw BridgeError.busy }
            throw BridgeError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = j["cid"] as? String else { throw BridgeError.http(http.statusCode, "no cid") }
        return CaptureResult(cid: cid)
    }

    /// The device's channels, each with its last play-by-play entry.
    func channels() async throws -> [Channel] {
        let (data, resp) = try await URLSession.shared.data(for: try request("/channels", method: "GET"))
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["channels"] as? [[String: Any]] else { throw BridgeError.http(500, "bad channels body") }
        return list.compactMap(Channel.init(json:))
    }

    /// Create a channel: kind "harness" (webhook to a session) or "chat".
    func createChannel(name: String, kind: String, webhook: String?) async throws -> Channel {
        var req = try request("/channels", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "kind": kind]
        if let webhook { body["webhook"] = webhook }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cj = j["channel"] as? [String: Any], let ch = Channel(json: cj) else {
            throw BridgeError.http(500, "bad channel body")
        }
        return ch
    }

    func renameChannel(_ id: String, name: String) async throws {
        var req = try request("/channels/\(id)", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.http((resp as? HTTPURLResponse)?.statusCode ?? 500, "rename failed")
        }
    }

    func deleteChannel(_ id: String) async throws {
        let (data, resp) = try await URLSession.shared.data(for: try request("/channels/\(id)", method: "DELETE"))
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// The play-by-play: entries after `after` (0 = from the start).
    func history(channel: String, after: Double = 0, n: Int = 80) async throws -> [HistoryEntry] {
        var qs = "?n=\(n)"
        if after > 0 { qs += "&after=\(after)" }
        let (data, resp) = try await URLSession.shared.data(for: try request("/channels/\(channel)/history\(qs)", method: "GET"))
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = j["entries"] as? [[String: Any]] else { return [] }
        return list.compactMap(HistoryEntry.init(json:))
    }

    /// Pair during an open window: POST /register, store the token.
    func register() async throws -> String {
        var req = try request("/register", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device": deviceID, "kind": "ios", "app": "slapp-ios", "version": "1.1",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = j["token"] as? String else { throw BridgeError.notPaired }
        return tok
    }
}
