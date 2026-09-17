import SwiftUI
import PhotosUI
import AVFoundation

/// One channel's play-by-play: history, tappable links, keyboard input, and
/// its own hold-to-talk mic. Polls the bridge for live updates.
struct ChannelView: View {
    @AppStorage("slappLeftHanded") private var lefty = false
    let channelID: String
    @ObservedObject var model: CaptureModel
    var start: StartAction = .none
    var accent: Color = ChannelColor.alive
    var onClose: (() -> Void)? = nil

    @State private var entries: [HistoryEntry] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var lastError: String?
    @State private var pollTimer: Timer?
    @FocusState private var kbFocus: Bool
    @State private var showTraffic = false
    @State private var showLive = true
    @State private var traffic: TrafficClient?
    @State private var lastEventCount = 0
    @State private var lastDoneFired = false   // true while a run is underway
    @State private var renaming = false
    @State private var renameDraft = ""
    @State private var peeled = false
    @State private var ripple: UUID? = nil
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var uploadNote: String?
    @State private var annotateItem: AnnotateItem?   // photo awaiting markup + caption

    /// iPhone photos are huge — bring them down to what a vision model can
    /// actually see (1568px JPEG). Same road as dragging a screenshot into pi.
    private func downscaled(_ img: UIImage) -> UIImage {
        let maxSide: CGFloat = 1568
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        guard scale < 1 else { return img }
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// the agent is mid-run: last traffic event isn't done/error yet
    private var agentBusy: Bool {
        guard let t = traffic, let last = t.events.last else { return false }
        return !["done", "error"].contains(last.type)
    }

    /// the session slug this channel feeds (for the file inbox)
    private var sessionSlug: String? {
        channel.flatMap { ch in
            ch.webhook.split(separator: "/").count > 0
                ? extractSlug(ch.webhook) : nil
        }
    }

    private var channel: Channel? { model.channels.first { $0.id == channelID } }

    /// the agent's live work, pi-style: last few minutes of thinking and tools
    private var liveTail: [TrafficEvent] {
        guard let t = traffic, showLive else { return [] }
        return Array(t.events.suffix(12))
    }
    private var tint: Color { accent }

    var body: some View {
        ZStack(alignment: .top) {
            // the pencil, going the other way — 45° rising, so the chat is
            // unmistakably the same thing as the tile you tapped
            PencilBackdrop(tint: tint)
                .ignoresSafeArea()
            historyList                     // full-bleed: scrolls under the clock
            chatHeader                      // floats — never blocks the scroll
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) { inputBar }
        }
        .overlay {
            if let rid = ripple {
                RippleView { ripple = nil }
                    .id(rid)
            }
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .sheet(isPresented: $showCamera) {
            CameraPicker(onImage: { data in
                if let img = UIImage(data: data)?.normalized() {
                    // present after the camera sheet is gone — a sheet racing
                    // a sheet renders blank
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        annotateItem = AnnotateItem(image: img)
                    }
                }
            })
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data)?.normalized() {
                    photoItem = nil
                    // wait out the picker's dismissal — a sheet presented
                    // mid-dismiss renders as a blank page
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    annotateItem = AnnotateItem(image: img)
                } else {
                    photoItem = nil
                    lastError = "couldn't open that photo — try taking one instead"
                }
            }
        }
        .sheet(item: $annotateItem) { item in
            AnnotateView(base: item.image, tint: tint) { marked, caption in
                annotateItem = nil
                Task {
                    guard let jpeg = downscaled(marked).jpegData(compressionQuality: 0.8) else {
                        lastError = "couldn't read the photo"
                        return
                    }
                    let ok = await model.sendPhoto(jpeg, channel: channelID, caption: caption)
                    lastError = ok ? nil : "couldn't send the photo"
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { Task { await uploadFile(url) } }
        }
        .safeAreaInset(edge: .bottom) {
            if let note = uploadNote {
                Text(note)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .padding(.vertical, 4)
            }
        }
        .alert("rename this line", isPresented: $renaming) {
            TextField("name", text: $renameDraft)
            Button("rename") {
                if let cid = channel?.id, !renameDraft.isEmpty {
                    Task { await model.renameChannel(cid, to: renameDraft) }
                }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            Spacer()
            // the small title appears only after the big one scrolls away
            if bigTitleGone {
                Button {
                    renameDraft = channel?.name ?? ""
                    renaming = true
                } label: {
                    HStack(spacing: 6) {
                        Text(channel?.name ?? channelID)
                            .font(.system(size: 19, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .kerning(0.2)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            Spacer()
        }
        .overlay(alignment: .trailing) {
            if agentBusy {
                // stop the run from inside the chat — alive, breathing
                Button { Haptics.thud(); Task { await traffic?.abort() } } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white.opacity(0.65)))
                        .modifier(PulseStop())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: bigTitleGone)
    }

    // MARK: - History
    //
    // The chat scrolls edge to edge — under the clock, over the home bar —
    // and never loses your place: autoscroll only fires while you're
    // already near the bottom, so an output stream can't yank you around.
    // The big serif title rides up and away with the conversation; a small
    // one fades into the floating header once it's gone.

    @State private var bigTitleGone = false
    @State private var nearBottom = true
    @State private var pinned = false   // ride the stream (expand sets, scroll-up breaks)

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 76)   // room under the floating header + clock
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TitleGoneKey.self,
                                                   value: g.frame(in: .named("chatScroll")).maxY < 44)
                        })
                    content
                }
            }
            .coordinateSpace(name: "chatScroll")
            .onPreferenceChange(TitleGoneKey.self) { bigTitleGone = $0 }
            .onPreferenceChange(BottomNearKey.self) { v in
                nearBottom = v
                if !v { pinned = false }   // the reader took the wheel
            }
            .simultaneousGesture(
                // right-handed: swipe right anywhere → back to the pencil box.
                // left-handed: the mirror — swipe left.
                DragGesture(minimumDistance: 34, coordinateSpace: .local).onEnded { v in
                    let w = lefty ? -v.translation.width : v.translation.width
                    if w > 90 && abs(v.translation.width) > abs(v.translation.height) * 1.6 {
                        onClose?()
                    }
                }
            )
            .onChange(of: entries.count) { _ in maybeFollow(proxy) }
            .onChange(of: traffic?.events.count ?? 0) { _, n in
                maybeFollow(proxy)
                // the item-get: a run just landed while you're watching
                if n > lastEventCount, let t = traffic, let last = t.events.last {
                    if last.type == "done", lastDoneFired { Haptics.alive() }
                    if last.type == "error", lastDoneFired { Haptics.play(.error) }
                    lastDoneFired = !["done", "error"].contains(last.type)
                }
                lastEventCount = n
            }
        }
    }

    /// follow the stream when the reader is near the bottom, or when the
    /// thinking is pinned open (expand = ride it). scrolling up is sacred:
    /// it breaks the ride, and returning to the bottom resumes it. one
    /// writer touches the scroll offset — this function — so nothing fights.
    private func maybeFollow(_ proxy: ScrollViewProxy) {
        guard nearBottom || pinned else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
    }

    struct TitleGoneKey: PreferenceKey {
        static var defaultValue: Bool = false
        static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
    }

    struct BottomNearKey: PreferenceKey {
        static var defaultValue: Bool = true
        static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
    }

    @ViewBuilder private var content: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { e in
                        Bubble(entry: e, tint: tint, slug: sessionSlug)
                            .modifier(PerspectiveRoad(lean: (e.isUser ? -1 : 1) * (lefty ? -1 : 1)))
                            .id(e.id)
                    }
                    // the live mind: thinking and tools stream right in the chat
                    ForEach(liveTail) { ev in
                        LiveLine(ev: ev, onExpand: { pinned = $0 })
                            .modifier(PerspectiveRoad(lean: lefty ? -1 : 1))
                            .id("live-\(ev.id)")
                    }
                    Color.clear.frame(height: 8).id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BottomNearKey.self,
                                                   value: g.frame(in: .named("chatScroll")).maxY < UIScreen.main.bounds.height * 1.2)
                        })
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 12) {
            if traffic != nil && !lefty {
                // the flip: keyboard ⇄ live traffic
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showTraffic.toggle() }
                } label: {
                    Image(systemName: showTraffic ? "keyboard" : "waveform.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(showTraffic ? ChannelColor.alive : .secondary)
                }
            }
            if showTraffic {
                trafficConsole
            } else if lefty {
            MicSendButton(tint: tint,
                          draft: $draft,
                          onSend: { sendDraft() },
                          onRipple: { ripple = UUID() },
                          bridgeHost: BridgeConfig().host)
            TextField(channel?.name ?? channelID, text: $draft, axis: .vertical)
                .focused($kbFocus)
                .lineLimit(1...6)
                .font(.system(size: 17.5))
                .foregroundStyle(Color.black.opacity(0.78))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(minHeight: 58)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                .onSubmit(sendDraft)
            cameraButton
            }
            else {
            cameraButton
            TextField(channel?.name ?? channelID, text: $draft, axis: .vertical)
                .focused($kbFocus)
                .lineLimit(1...6)
                .font(.system(size: 17.5))
                .foregroundStyle(Color.black.opacity(0.78))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(minHeight: 58)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                .onSubmit(sendDraft)
            MicSendButton(tint: tint,
                          draft: $draft,
                          onSend: { sendDraft() },
                          onRipple: { ripple = UUID() },
                          bridgeHost: BridgeConfig().host)
            }
            if traffic != nil && lefty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showTraffic.toggle() }
                } label: {
                    Image(systemName: showTraffic ? "keyboard" : "waveform.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(showTraffic ? ChannelColor.alive : .secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint)
        .safeAreaInset(edge: .bottom) {
            if let lastError {
                Text(lastError).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    /// The big hold-to-talk disc, channel-bound.
    private var holdMic: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22)).frame(width: 44, height: 44)
            Circle()
                .fill(model.recordingChannel == channelID ? ChannelColor.alive : tint)
                .frame(width: 34, height: 34)
                .scaleEffect(1 + (model.recordingChannel == channelID ? model.level * 0.2 : 0))
            Image(systemName: model.recordingChannel == channelID ? "waveform" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
        }
        .animation(.easeOut(duration: 0.08), value: model.level)
        .onLongPressGesture(minimumDuration: 3600, maximumDistance: 150) {} onPressingChanged: { pressing in
            if pressing {
                lastError = nil
                model.pressDown(channel: channelID)
            } else if model.elapsed < 0.4 {
                model.cancelHold()
            } else {
                model.pressUp()
            }
        }
    }

    /// pi's console in the keyboard's seat — thinking traces and all,
    /// with the little stop / run buttons up top.
    private var trafficConsole: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = traffic {
                HStack(spacing: 10) {
                    Text("traffic · \(t.slug)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await t.nudge() } } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(ChannelColor.alive)
                    }
                    Button { Haptics.thud(); Task { await t.abort() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(t.events.suffix(9)) { e in
                                trafficLine(e).id(e.id)
                            }
                            Color.clear.frame(height: 2).id("tbottom")
                        }
                    }
                    .frame(height: 118)
                    .onChange(of: t.events.count) { _ in
                        proxy.scrollTo("tbottom")
                    }
                }
            }
        }
    }

    @ViewBuilder private func trafficLine(_ e: TrafficEvent) -> some View {
        let label = e.type == "tool" ? (e.preview.isEmpty ? "working" : e.preview) : e.text
        HStack(alignment: .top, spacing: 5) {
            Text(trafficGlyph(e))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(trafficColor(e))
                .padding(.top, 2)
            Text(label.isEmpty ? e.type : label)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(trafficColor(e).opacity(0.85))
                .lineLimit(2)
        }
    }

    // MARK: - the camera

    /// a little vintage camera, drawn by hand — ink on the pastel.
    /// opens three roads: the reel, the lens, or a file.
    private var cameraButton: some View {
        Menu {
            Button { showPhotoPicker = true } label: {
                Label("from the photo reel", systemImage: "photo.on.rectangle")
            }
            Button { showCamera = true } label: {
                Label("take a photo", systemImage: "camera")
            }
            Button { showFilePicker = true } label: {
                Label("upload a file", systemImage: "doc")
            }
        } label: {
            KodakIcon()
                .frame(width: 44, height: 58)
        }
    }

    // MARK: - the file road

    /// copy a file from the phone into the session's inbox on the Mac,
    /// then tell the agent where it landed.
    private func uploadFile(_ url: URL) async {
        guard let slug = sessionSlug else {
            uploadNote = "no session behind this line — can't land files"
            return
        }
        let mustAccess = url.startAccessingSecurityScopedResource()
        defer { if mustAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let enc = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "file.bin"
            var r = URLRequest(url: URL(string: "http://\(BridgeConfig().host):8123/api/session/\(slug)/upload?filename=\(enc)")!)
            r.httpMethod = "POST"
            r.timeoutInterval = 120
            r.httpBody = data
            let (respData, _) = try await URLSession.shared.data(for: r)
            guard let j = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let dest = j["path"] as? String else {
                uploadNote = "the Mac wouldn't take the file"
                return
            }
            uploadNote = "landed: \((dest as NSString).lastPathComponent)"
            let ok = await model.sendText("I just dropped a file for you at \(dest) — it's in the project, take a look.", channel: channelID)
            if !ok { uploadNote = "file landed but the note didn't send" }
        } catch {
            uploadNote = "couldn't read that file"
        }
    }

    private func trafficGlyph(_ e: TrafficEvent) -> String {
        switch e.type {
        case "user": return "❯"
        case "done": return "◆"
        case "tool": return e.phase == "end" ? (e.ok == false ? "✗" : "✓") : "$"
        case "thinking": return "◦"
        case "error": return "!!"
        default: return "•"
        }
    }

    private func trafficColor(_ e: TrafficEvent) -> Color {
        switch e.type {
        case "user", "done": return ChannelColor.alive
        case "tool": return e.ok == false ? .red : .green
        case "error": return .red
        default: return Color(white: 0.55)
        }
    }

    private func sendDraft() { sendNow() }

    private func sendNow() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sending = true
        // the egg: the chorus rides along whenever the words ask for it
        let lowered = text.lowercased()
        if lowered.contains("never gonna give you up") || lowered.contains("rick roll") || lowered.contains("rickroll") {
            Haptics.rickRoll()
        } else {
            Haptics.write()
        }
        Task {
            let ok = await model.sendText(text, channel: channelID)
            sending = false
            if !ok { lastError = model.sendNote ?? "send failed"; draft = text }
        }
    }

    // MARK: - Polling (the play-by-play)

    private func startPolling() {
        Task { await pull() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in await pull() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pull() async {
        let after = entries.last?.ts ?? 0
        do {
            let fresh = try await model.client.history(channel: channelID, after: after)
            if !fresh.isEmpty { entries.append(contentsOf: fresh) }
        } catch {
            // bridge asleep or away — the next beat retries quietly
        }
    }
}

// MARK: - the pencil backdrop — same pencil, tilted the OTHER way (45°
// rising), painted wide and quiet behind the chat
struct PencilBackdrop: View {
    var tint: Color
    var body: some View {
        ZStack {
            tint                       // the chat lives ON the pencil's color
            GeometryReader { geo in
                let w = max(geo.size.width, geo.size.height) * 2.2
                Group {
                    PencilStripe(tint: .white, width: geo.size.width * 0.55)
                        .opacity(0.16)
                        .offset(x: -geo.size.width * 0.28, y: -geo.size.height * 0.10)
                    PencilStripe(tint: .black, width: geo.size.width * 0.10)
                        .opacity(0.05)
                        .offset(x: geo.size.width * 0.36, y: geo.size.height * 0.16)
                }
                .frame(width: w, alignment: .center)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }
}

struct PencilStripe: View {
    @AppStorage("slappLeftHanded") private var lefty = false
    var tint: Color
    var width: CGFloat
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.045)],
                               startPoint: .top, endPoint: .bottom)
            )
            .frame(width: width, height: 2600)
            .rotationEffect(.degrees(lefty ? -45 : 45))
            .blendMode(.plusLighter)
    }
}

// MARK: - Bubble

struct Bubble: View {
    @AppStorage("slappLeftHanded") private var lefty = false
    let entry: HistoryEntry
    let tint: Color
    var slug: String? = nil

    private var audioSrc: String? {
        if let a = entry.audio, !a.isEmpty { return a }
        return nil
    }
    private var photoSrc: String? {
        if let p = entry.photo, !p.isEmpty { return p }
        // bare image URLs in the text render inline too
        for token in entry.text.split(whereSeparator: { $0.isWhitespace || $0 == ")" || $0 == "(" }) {
            let t = token.lowercased()
            if t.hasPrefix("http"),
               ["png", "jpg", "jpeg", "gif", "webp"].contains(where: { t.hasSuffix("." + $0) }) {
                return String(token)
            }
        }
        return nil
    }

    /// which side the user's ink lives on — leading for a left hand
    private var userSide: HorizontalAlignment { lefty ? .leading : .trailing }
    private var agentSide: HorizontalAlignment { lefty ? .trailing : .leading }
    private var userAlign: Alignment { Alignment(horizontal: userSide, vertical: .center) }
    private var agentAlign: Alignment { Alignment(horizontal: agentSide, vertical: .center) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if entry.isUser != lefty { Spacer(minLength: 84) }
            VStack(alignment: entry.isUser ? userSide : agentSide, spacing: 4) {
                if !entry.text.isEmpty {
                    Text(linkified(entry.text))
                        .font(.system(size: 16.5, design: entry.isUser ? .default : .serif))
                        .environment(\.openURL, OpenURLAction { url in .systemAction })
                        .foregroundStyle(entry.isUser ? .white : Color.black.opacity(0.82))
                        .tint(entry.isUser ? .white : .blue)
                        .textSelection(.enabled)
                }
                if let p = photoSrc {
                    MediaPhoto(src: p, slug: slug, light: entry.isUser)
                }
                if let a = audioSrc {
                    MediaAudio(src: a, slug: slug, light: entry.isUser)
                }
                if entry.text.isEmpty && photoSrc == nil && audioSrc == nil {
                    HStack(spacing: 8) {
                        PhotoGlyph(ink: .white.opacity(0.9))
                        Text("photo").font(.system(size: 16.5))
                    }
                }
                Text(entry.timeLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .serif))
                    .tracking(0.3)
                    .foregroundStyle(entry.isUser ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(entry.isUser ? Color.black.opacity(0.78) : Color.white.opacity(0.92))
            )
            .overlay(alignment: entry.isUser == lefty ? .topTrailing : .topLeading) {
                // three angled lines stretching across the corner — the tap
                // spot that copies this whole message
                Button {
                    UIPasteboard.general.string = entry.text
                    Haptics.pencilTap()
                } label: {
                    CornerHatch(ink: entry.isUser ? Color.white.opacity(0.5) : Color.black.opacity(0.28), mirrored: entry.isUser != lefty)
                        .frame(width: 40, height: 40)
                }
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = entry.text
                } label: { Label("copy the whole thing", systemImage: "doc.on.doc") }
            }
            .shadow(color: Color.black.opacity(0.08), radius: 5, y: 2)
            if !entry.isUser { Spacer(minLength: 84) }
        }
        .frame(maxWidth: .infinity, alignment: entry.isUser ? userAlign : agentAlign)
    }
}

/// the perspective road: as a row travels up the chat it eases smaller and
/// more translucent, leaning toward the middle — a road going away from you.
/// fresh rows at the bottom are untouched; the effect grows with the climb.
struct PerspectiveRoad: ViewModifier {
    var lean: CGFloat   // -1 user rows drift left, +1 agent rows drift right
    @State private var t: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                let vh = UIScreen.main.bounds.height
                let minY = g.frame(in: .named("chatScroll")).minY
                DispatchQueue.main.async {
                    t = min(1, max(0, (vh * 0.86 - minY) / (vh * 0.86)))
                }
                return Color.clear
            })
            .scaleEffect(1 - t * 0.14, anchor: .bottom)
            .opacity(1 - t * 0.42)
            .offset(x: t * 26 * lean)
            .animation(.easeOut(duration: 0.12), value: t)
    }
}

/// a photo the agent made (or sent) — resolved to a tappable URL
struct MediaPhoto: View {
    let src: String
    var slug: String? = nil
    var light = false
    @State private var img: UIImage?
    @State private var showFull = false

    var body: some View {
        Group {
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 150)      // a small print — tap to see it big
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.08))
                    .frame(width: 120, height: 84)
            }
        }
        .task { await load() }
        .onTapGesture { showFull = true }
        .contextMenu { Button { if let img { UIPasteboard.general.image = img } } label: { Label("copy the photo", systemImage: "photo") } }
        .fullScreenCover(isPresented: $showFull) {
            // the full preview — pinch-out of the chat, tap anywhere to close
            ZStack {
                Color(white: 0.06).ignoresSafeArea()
                VStack(spacing: 12) {
                    if let img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding()
                    } else if let url = SlappMedia.resolve(src, slug: slug) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit().padding()
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                    }
                    Text("tap to close")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .onTapGesture { showFull = false }
        }
    }

    private func load() async {
        if src.hasPrefix("data:") {
            let b64 = src.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
            img = Data(base64Encoded: b64).flatMap(UIImage.init)
            return
        }
        guard let url = SlappMedia.resolve(src, slug: slug) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            img = UIImage(data: data)
        } catch {}
    }
}

/// audio the agent made — a small play/pause player right in the bubble
struct MediaAudio: View {
    let src: String
    var slug: String? = nil
    var light = false
    @StateObject private var player = AudioPlayer()

    var ink: Color { light ? Color.white.opacity(0.9) : Color.black.opacity(0.7) }

    var body: some View {
        Button {
            if let url = SlappMedia.resolve(src, slug: slug) {
                player.toggle(url: url)
                Haptics.tick()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                if player.playing {
                    // three breathing bars
                    HStack(spacing: 2.5) {
                        AudioBar(delay: 0)
                        AudioBar(delay: 0.2)
                        AudioBar(delay: 0.4)
                    }
                    .frame(height: 14)
                } else {
                    Text("play").font(.system(size: 14, design: .serif))
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(light ? Color.white.opacity(0.18) : Color.black.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

struct AudioBar: View {
    var delay: Double
    @State private var up = false
    var body: some View {
        Capsule().fill(Color.white.opacity(0.9))
            .frame(width: 3, height: up ? 14 : 5)
            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(delay), value: up)
            .onAppear { up = true }
    }
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published var playing = false
    private var p: AVPlayer?
    private var observer: Any?

    func toggle(url: URL) {
        if playing { stop(); return }
        let item = AVPlayerItem(url: url)
        let pl = AVPlayer(playerItem: item)
        p = pl
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        pl.play()
        playing = true
    }

    func stop() {
        p?.pause()
        p = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        playing = false
    }
}

/// resolve a media source (abs Mac path, file under a session, or URL) to a
/// URL the phone can fetch
enum SlappMedia {
    static func resolve(_ src: String, slug: String?) -> URL? {
        if src.hasPrefix("http") { return URL(string: src) }
        if src.hasPrefix("/") {
            guard let slug else { return nil }
            let enc = src.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? src
            return URL(string: "http://\(BridgeConfig().host):8123/api/session/\(slug)/file?p=\(enc)")
        }
        return nil
    }
}

/// one beat of the agent's mind, inline in the chat
struct LiveLine: View {
    let ev: TrafficEvent
    var onExpand: (Bool) -> Void = { _ in }
    @State private var open = false
    private var isThinking: Bool { ev.type == "thinking" }

    var body: some View {
        Button {
            guard isThinking else { return }
            Haptics.select()
            withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            onExpand(open)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(glyph)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .padding(.top, 3)
                if isThinking && !open {
                    // the ticker: the freshest words slide in from the right
                    Text(String(ev.text.suffix(130)))
                        .font(.system(size: 12.5, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(ev.type == "tool" ? (ev.preview.isEmpty ? "working…" : ev.preview) : ev.text)
                        .font(.system(size: 12.5, design: isThinking ? .serif : .monospaced))
                        .foregroundStyle(Color.black.opacity(0.6))
                }
                if isThinking {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.35))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private var glyph: String {
        switch ev.type {
        case "user": return "❯"
        case "tool": return ev.phase == "end" ? (ev.ok == false ? "✗" : "✓") : "$"
        case "thinking": return "◦"
        case "done": return "◆"
        case "error": return "!!"
        default: return "•"
        }
    }

    private var color: Color {
        switch ev.type {
        case "user", "done": return ChannelColor.alive
        case "tool": return ev.ok == false ? .red : .green
        case "error": return .red
        default: return Color(white: 0.5)
        }
    }
}

/// pulls the session slug out of a channel webhook like
/// http://…/api/session/<slug>/slapp
private func extractSlug(_ webhook: String) -> String? {
    guard let range = webhook.range(of: "/api/session/") else { return nil }
    let tail = webhook[range.upperBound...]
    return tail.split(separator: "/").first.map(String.init)
}

/// the breathing stop button
struct PulseStop: ViewModifier {
    @State private var up = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(up ? 1.06 : 0.98)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: up)
            .onAppear { up = true }
    }
}

/// the little hand-drawn camera: body, lens, viewfinder bump, flash dot
struct KodakIcon: View {
    var body: some View {
        ZStack {
            // body
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.black.opacity(0.65), lineWidth: 2.4)
                .frame(width: 30, height: 21)
            // viewfinder bump
            Rectangle()
                .fill(Color.black.opacity(0.65))
                .frame(width: 10, height: 4)
                .offset(y: -13)
            // lens
            Circle()
                .strokeBorder(Color.black.opacity(0.65), lineWidth: 2.2)
                .frame(width: 13, height: 13)
            Circle()
                .fill(Color.black.opacity(0.65))
                .frame(width: 4, height: 4)
            // shutter button
            Rectangle()
                .fill(Color.black.opacity(0.65))
                .frame(width: 4, height: 4)
                .offset(x: 12, y: -7)
        }
    }
}

/// two angled lines crossing a box's corner — the copy mark
struct CornerHatch: View {
    var ink: Color = Color.black.opacity(0.3)
    var mirrored = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { path in
                let r = CGFloat(20)   // the bubble's own corner radius
                let inset = CGFloat(0.9)  // half the stroke: ink stops AT the edge
                for i in 0..<2 {
                    // a breath off the corner arc, the pair close together —
                    // every chord leaves the TOP edge and lands on the SIDE edge
                    let off = CGFloat(3) + CGFloat(i) * 6
                    path.move(to: CGPoint(x: w - r - off, y: inset))
                    path.addLine(to: CGPoint(x: w - inset, y: r + off))
                }
            }
            .stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: .center)
        }
        .allowsHitTesting(false)
    }
}

/// a tiny drawn photo mark — a framed mountain, ink. no emoji in this house.
struct PhotoGlyph: View {
    var ink: Color = Color.black.opacity(0.5)
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(ink, lineWidth: 1.6)
            // the sun
            Circle().fill(ink).frame(width: 3, height: 3).offset(x: -5, y: -4)
            // the mountain
            Path { path in
                path.move(to: CGPoint(x: 3, y: 12))
                path.addLine(to: CGPoint(x: 8, y: 6.5))
                path.addLine(to: CGPoint(x: 12, y: 11))
                path.addLine(to: CGPoint(x: 14, y: 9))
                path.addLine(to: CGPoint(x: 17, y: 12))
            }
            .stroke(ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 20, height: 16)
    }
}
