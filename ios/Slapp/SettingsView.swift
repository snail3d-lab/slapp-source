import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var host: String = UserDefaults.standard.string(forKey: "bridge_host") ?? ""
    @State private var port: String = String(UserDefaults.standard.object(forKey: "bridge_port") as? Int ?? 8651)
    @State private var pairing = false
    @State private var message: String?
    @State private var connected = false
    @State private var maxSess = 4
    @State private var activeSess = 0

    var body: some View {
        NavigationStack {
            Form {
                content
                    .onAppear { ping() }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("settings")
                        .font(.system(size: 32, weight: .bold, design: .serif))
                        .kerning(0.3)
                        .foregroundStyle(Color.black.opacity(0.85))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        var cfg = BridgeConfig()
                        cfg.host = host.trimmingCharacters(in: .whitespaces)
                        if let p = Int(port), (1...65535).contains(p) { cfg.port = p }
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
Section(header: Text("connection")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .textCase(nil)) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connected ? ChannelColor.alive : Color.orange)
                    .frame(width: 9, height: 9)
                Text(connected ? "connected" : "not connected — is Tailscale on?")
                    .font(.system(size: 14, design: .serif))
            }
            TextField("road (tailnet name or IP)", text: $host)
                .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                .font(.system(size: 13, design: .monospaced))
            TextField("port", text: $port).keyboardType(.numberPad)
        }
Section(header: Text("hands")
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(Color.black.opacity(0.45))
                .textCase(nil)) {
            Toggle("left-handed — the whole thing mirrors: tilts, buttons, chat sides", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "slappLeftHanded") },
                set: { UserDefaults.standard.set($0, forKey: "slappLeftHanded") }))
                .font(.system(size: 14, design: .serif))
        }
        Section(header: Text("device")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .textCase(nil)) {
            Button(pairing ? "pairing…" : "pair — open a window on the Mac first") { pair() }
                .disabled(pairing)
            if let token = Keychain.get() {
                Label("paired", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Label("not paired", systemImage: "seal").foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            LabeledContent("id", value: DeviceIdentity.id)
            Button("unpair", role: .destructive) {
                Keychain.clear()
                message = "token cleared — pair again to reconnect."
            }
        }
Section(header: Text("notifications")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .textCase(nil)) {
            Toggle("tell me when a line finishes or needs help", isOn: Binding(
                get: { LineNotifications.enabled }, set: { LineNotifications.enabled = $0 }))
                .font(.system(size: 14, design: .serif))
        }
Section(header: Text("sessions")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .textCase(nil)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("how many can work at once")
                        .font(.system(size: 14, design: .serif))
                    Text("\(activeSess) of \(maxSess) agents working right now")
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.45))
                }
                Picker("max active", selection: $maxSess) {
                    ForEach(1...12, id: \.self) { n in
                        Text("\(n)").font(.system(size: 20, weight: .semibold, design: .serif)).tag(n)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 116)
                .onChange(of: maxSess) { _, n in
                    // the wheel clicks as it turns — and twelve gets the joke
                    if n == 12 { Haptics.eleven() } else { Haptics.select() }
                    Task { _ = await model.slapp.setMaxSessions(n) }
                }
            }
            Section(header: Text("pencils")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .textCase(nil)) {
            @AppStorage("slappSwipeReveal") var swipeReveal: Bool = false
            Toggle("most recent pencil at the top", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "slappSortRecent") },
                set: { UserDefaults.standard.set($0, forKey: "slappSortRecent") }))
                .font(.system(size: 14, design: .serif))
            Toggle("rub along a pencil brings its space up in herdr", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "slappSwipeReveal") == nil ? true : UserDefaults.standard.bool(forKey: "slappSwipeReveal") },
                set: { UserDefaults.standard.set($0, forKey: "slappSwipeReveal") }))
                .font(.system(size: 14, design: .serif))
            Toggle("swipe up sends straight to the agent", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "slappSwipeSend") },
                set: { UserDefaults.standard.set($0, forKey: "slappSwipeSend") }))
                .font(.system(size: 14, design: .serif))
        }
Section(header: Text("about")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .textCase(nil)) {
            LabeledContent("version", value: version)
            Text("Slapp talks to your own Mac over Tailscale — the fleet runs at home and meets you anywhere.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private func ping() {
        Task {
            if let cap = await model.slapp.sessionCap() {
                maxSess = cap.max
                activeSess = cap.active
            }
        }
        var cfg = BridgeConfig()
        cfg.host = host.trimmingCharacters(in: .whitespaces)
        if let p = Int(port), (1...65535).contains(p) { cfg.port = p }
        guard let url = URL(string: "http://\(cfg.host):\(cfg.port)/health") else { return }
        var r = URLRequest(url: url)
        r.timeoutInterval = 4
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { self.connected = ok }
        }.resume()
    }

    private func pair() {
        pairing = true
        message = nil
        var cfg = BridgeConfig()
        cfg.host = host.trimmingCharacters(in: .whitespaces)
        if let p = Int(port), (1...65535).contains(p) { cfg.port = p }
        let client = BridgeClient(config: cfg, deviceID: DeviceIdentity.id, token: nil)
        Task {
            defer { pairing = false }
            do {
                let token = try await client.register()
                Keychain.set(token)
                message = nil
                Haptics.play(.success)
                ping()
            } catch {
                message = "couldn't pair — is the window open on the Mac?"
                Haptics.play(.error)
            }
        }
    }
}
