import SwiftUI

/// A corner leaf: small, dark, tint-stroked, one tap.
private func leafChip(_ glyph: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button {
        action()
    } label: {
        Image(systemName: glyph)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color(white: 0.03).opacity(0.85)))
            .overlay(Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1))
    }
    .buttonStyle(.plain)
}

/// The grid: one tile per channel — last reply on the face, hold to talk,
/// tap to open the conversation. Cells laws: true black, serif names, one
/// alive accent, painterly hues for content.
struct RootView: View {
    @AppStorage("slappLeftHanded") private var lefty = false
    @StateObject private var model = CaptureModel()
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showWatch = false
    @State private var editing = false
    @State private var showAdd = false
    @State private var openChannelID: String?
    @State private var renaming: Channel?
    @State private var renameDraft = ""
    @State private var startChannel = ""
    @State private var startAction: StartAction = .none
    @State private var watchedSlugs: Set<String> = []

    // MARK: - pencil reorder
    //
    // press the left ~10% of a pencil and it lifts; travel and the box
    // reshuffles around it. hold near an edge and the list walks — slowly
    // at first, then quicker, so a long box stays reachable.

    @State private var liftedID: String?
    @State private var dragY: CGFloat = 0
    @State private var lastStep = Date.distantPast
    @State private var edgeHold: Date?

    // press and HOLD a moment — the pencil lifts with a tick — then drag.
    // the long press claims the touch, so scrolling can never race it
    private func liftGesture(_ id: String) -> AnyGesture<Void> {
        let seq = LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { v in
                guard case .second(true, let drag?) = v else { return }
                if liftedID == nil {
                    liftedID = id
                    Haptics.tick()
                    lastStep = Date.distantPast
                }
                dragY = drag.translation.height
                stepIfNeeded(id, pointerY: drag.startLocation.y + drag.translation.height)
            }
            .onEnded { _ in
                liftedID = nil
                dragY = 0
                edgeHold = nil
            }
        return AnyGesture(seq.map { _ in () })
    }

    private func stepIfNeeded(_ id: String, pointerY: CGFloat) {
        let bars = visibleBars
        guard let idx = bars.firstIndex(where: { $0.id == id }) else { return }
        let screen = UIScreen.main.bounds.height

        // edge zones: hold to walk the list. one steady pace — no
        // acceleration, the list steps at the same calm rate however long
        // you hold
        var stepping: Int? = nil
        if pointerY < 170 { stepping = -1 }
        else if pointerY > screen - 170 { stepping = 1 }
        if stepping == nil { edgeHold = nil }   // back mid-list: swaps live again

        // a plain swap: past a tile's height of travel, trade places
        let travel = dragY
        if stepping == nil {
            if travel > 58 && idx < bars.count - 1 {
                move(id, from: idx, to: idx + 1)
                dragY = 0
                Haptics.tick()
            } else if travel < -58 && idx > 0 {
                move(id, from: idx, to: idx - 1)
                dragY = 0
                Haptics.tick()
            }
            return
        }

        guard let dir = stepping else { return }
        if edgeHold == nil { edgeHold = Date() }
        guard Date().timeIntervalSince(lastStep) > 0.42 else { return }
        let next = idx + dir
        guard bars.indices.contains(next) else { return }
        move(id, from: idx, to: next)
        dragY = 0
        lastStep = Date()
        Haptics.tick()
    }

    private func move(_ id: String, from: Int, to: Int) {
        var bars = visibleBars
        bars.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        saveOrder(bars)
    }

    private func barRow(_ bi: Int, _ ch: Channel) -> some View {
        let isRec = model.recordingChannel == ch.id
        let step = CGFloat(bi % 6) * 16
        let eyed = watchedSlugs.contains { slug in isSessionWebhook(ch.webhook, slug: slug) }
        return ChannelTile(channel: ch, recording: isRec, editing: editing,
                    level: isRec ? model.level : 0, phase: isRec ? model.phase : .idle,
                    tall: sizeClass == .regular, wide: true, stagger: step, barIndex: bi, watched: eyed,
                    lifted: liftedID == ch.id, dragY: liftedID == ch.id ? dragY : 0,
                    reorderGesture: liftGesture(ch.id),
                    onRemove: { Task { await model.removeChannel(ch.id) } },
                    onOpen: { Haptics.pencilTap(); withAnimation(peel) { openChannelID = ch.id } },
                    onKeyboard: { startChannel = ch.id; startAction = .keyboard; withAnimation(peel) { openChannelID = ch.id } },
                    onPhoto: { startChannel = ch.id; startAction = .choose; withAnimation(peel) { openChannelID = ch.id } },
                    onRename: { renameDraft = ch.name; renaming = ch },
                    model: model)
    }

    private var visibleBars: [Channel] {
        let base = model.channels.filter {
            !($0.kind == "default" && $0.last == nil && $0.previews.isEmpty)
            && !isSessionWebhook($0.webhook, slug: "launcher")   // the word replaces the line
        }
        if UserDefaults.standard.bool(forKey: "slappSortRecent") {
            return base.sorted { ($0.last?.ts ?? 0) > ($1.last?.ts ?? 0) }
        }
        // your hand-laid order, if you've ever arranged the box
        let order = UserDefaults.standard.stringArray(forKey: "slappPencilOrder") ?? []
        guard !order.isEmpty else { return base }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return base.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    /// remember a hand-laid pencil order (only while "most recent" is off)
    private func saveOrder(_ bars: [Channel]) {
        UserDefaults.standard.set(bars.map(\.id), forKey: "slappPencilOrder")
    }

    @Environment(\ .horizontalSizeClass) private var sizeClass


    var body: some View {
        ZStack {
            // the chat peels over EVERYTHING — full screen, safe areas
            // included, so no edge can flicker on any surface
            if let id = openChannelID {
                let bi = visibleBars.firstIndex { $0.id == id } ?? 0
                ChannelView(channelID: id, model: model,
                            start: startChannel == id ? startAction : .none,
                            accent: ChannelColor.pastel(at: bi),
                            onClose: { withAnimation(peel) { openChannelID = nil } })
                    .transition(peelTransition)
                    .onAppear { if model.recordingChannel != nil { model.cancelHold() } }
                    .zIndex(10)
            }
            NavigationStack {
            ZStack {
                Color(white: 0.90).ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // an empty default road is not a tile — it's just blank space
                        ForEach(Array(visibleBars.enumerated()), id: \.element.id) { bi, ch in
                            barRow(bi, ch)
                        }
                        if editing {
                            addTile
                        }
                    }
                    .padding(.leading, -10)
                    .padding(.top, 56)
                    if model.channelsLoaded && model.channels.isEmpty {
                        Text("no lines yet — tap edit, then +")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.black.opacity(0.45))
                            .padding(.top, 30)
                    } else if let note = model.connectionNote {
                        // the paper never just goes blank — say what's wrong in plain words
                        VStack(spacing: 10) {
                            Text(note)
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(Color.black.opacity(0.55))
                            if !model.channelsLoaded {
                                Button("try again") { Task { await model.refreshChannels() } }
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.25))
                            }
                        }
                        .padding(.top, 34)
                    }
                }
            }
                .overlay(alignment: lefty ? .topTrailing : .topLeading) {
                    // gear + magnifier — turned with the pencils
                    HStack(spacing: 20) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 23, weight: .medium))
                                .foregroundStyle(Color.black.opacity(0.55))
                                .rotationEffect(.degrees(lefty ? 7 : -7))
                        }
                        .buttonStyle(.plain)
                        Button { showSearch = true } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.55))
                                .rotationEffect(.degrees(lefty ? 7 : -7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(lefty ? .trailing : .leading, 22)
                    .offset(y: 4)
                }
            .navigationBarTitleDisplayMode(.inline)

            .overlay(alignment: lefty ? .bottomLeading : .bottomTrailing) {
                // the launch rocket — pinned to the paper's bottom-right
                // (bottom-left for a left hand), aimed with the pencils
                Button {
                    if let ch = model.channels.first(where: { isSessionWebhook($0.webhook, slug: "launcher") }) {
                        withAnimation(peel) { openChannelID = ch.id }
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.white.opacity(0.6)))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .rotationEffect(.degrees(lefty ? 7 : -7))
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.white.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 24)
                .padding(.bottom, 18)
            }

            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showSearch) {
                SearchSheet(model: model) { chid in
                    withAnimation(peel) { openChannelID = chid }
                }
            }
            .sheet(isPresented: $showWatch) { WatchSheet() }
            .sheet(isPresented: $showAdd) { AddChannelSheet(model: model) }
            .alert("rename channel", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("name", text: $renameDraft)
                Button("Save") {
                    if let ch = renaming, !renameDraft.isEmpty {
                        Task { await model.renameChannel(ch.id, to: renameDraft) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("what should this channel be called?")
            }
            .onAppear {
                model.ensureMicPermission()
                model.pairIfPossible()
            }
            .task {
                // the grid breathes: new tiles appear on their own, watched
                // sessions wear the eye
                let slapp = SlappClient(bridgeHost: BridgeConfig().host)
                while !Task.isCancelled {
                    await model.refreshChannels()
                    let ws = await slapp.watches()
                    watchedSlugs = Set(ws.map(\.slug))
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
            .refreshable { await model.refreshChannels() }
        }
        .preferredColorScheme(.light)   // the whole house is light — no dark mode, ever
        }
    }

    private var addTile: some View {
        Button { showAdd = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .light))
                Text("channel")
                    .font(.system(size: 13, design: .serif))
            }
            .foregroundStyle(ChannelColor.alive)
            .frame(maxWidth: .infinity)
            .frame(height: 128)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ChannelColor.alive.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tile

struct ChannelTile: View {
    @AppStorage("slappLeftHanded") private var lefty = false
    let channel: Channel
    let recording: Bool
    let editing: Bool
    let level: Double
    let phase: CaptureModel.Phase
    var tall = false
    var wide = true
    var stagger: CGFloat = 0
    var barIndex = 0
    var watched = false
    var lifted = false
    var dragY: CGFloat = 0
    var reorderGesture: AnyGesture<Void> = AnyGesture(DragGesture(minimumDistance: 9999).map { _ in () })
    let onRemove: () -> Void
    let onOpen: () -> Void
    let onKeyboard: () -> Void
    let onPhoto: () -> Void
    let onRename: () -> Void
    @ObservedObject var model: CaptureModel
    @StateObject private var live: TrafficClient
    @State private var previewTick = 0
    @State private var barState: BarState = .idle
    @State private var liveText = ""
    @State private var lastBeat = Date.distantPast
    @State private var askWake = false
    @State private var askClose = false

    private var asleep: Bool {
        (channel.webhook.contains("/slapp") || channel.webhook.contains("/monocle")) && model.slug(for: channel) != nil
    }

    enum BarState { case idle, working, stuck, done, error }

    private var isStuck: Bool {
        barState == .working && Date().timeIntervalSince(lastBeat) > 45
    }

    init(channel: Channel, recording: Bool, editing: Bool, level: Double,
         phase: CaptureModel.Phase, tall: Bool, wide: Bool, stagger: CGFloat = 0, barIndex: Int = 0, watched: Bool,
         lifted: Bool = false, dragY: CGFloat = 0,
         reorderGesture: AnyGesture<Void> = AnyGesture(DragGesture(minimumDistance: 9999).map { _ in () }),
         onRemove: @escaping () -> Void, onOpen: @escaping () -> Void,
         onKeyboard: @escaping () -> Void, onPhoto: @escaping () -> Void,
         onRename: @escaping () -> Void, model: CaptureModel) {
        self.channel = channel
        self.recording = recording
        self.editing = editing
        self.level = level
        self.phase = phase
        self.tall = tall
        self.wide = wide
        self.stagger = stagger
        self.barIndex = barIndex
        self.watched = watched
        self.lifted = lifted
        self.dragY = dragY
        self.reorderGesture = reorderGesture
        self.onRemove = onRemove
        self.onOpen = onOpen
        self.onKeyboard = onKeyboard
        self.onPhoto = onPhoto
        self.onRename = onRename
        self.model = model
        _live = StateObject(wrappedValue: TrafficClient(webhook: channel.webhook.isEmpty ? nil : channel.webhook,
                                                        bridgeHost: BridgeConfig().host))
    }

    private static let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var previewLines: [HistoryEntry] {
        channel.previews.isEmpty ? (channel.last.map { [$0] } ?? []) : channel.previews
    }

    private var tint: Color { ChannelColor.tint(for: channel.id) }

    private func pastelDark(_ c: Color) -> Color {
        c.ensureContrast()
    }

    private func lineColor(_ pastel: Color) -> Color {
        switch barState {
        case .error: return .red.opacity(0.85)
        case .done: return ChannelColor.alive
        case .working: return pastel.opacity(0.55)
        case .stuck: return Color.orange.opacity(0.85)
        case .idle: return recording ? ChannelColor.alive.opacity(0.8) : pastel.opacity(0.30)
        }
    }

    private func streakTint(_ pastel: Color) -> Color {
        barState == .error ? .red : pastel
    }

    /// done/error pop = a real lift-off-the-paper shadow (ink, like the
    /// paper's own depth), on top of the edge color from lineColor
    private func elevationShadow(_ pastel: Color) -> Color {
        switch barState {
        case .done: return Color.black.opacity(0.32)
        case .error: return Color.black.opacity(0.32)
        case .working: return pastel.opacity(0.25)
        case .stuck: return Color.orange.opacity(0.3)
        case .idle: return recording ? pastel.opacity(0.3) : .clear
        }
    }

    var body: some View {
        tileBody
            .scaleEffect(lifted ? 1.05 : 1)
            .offset(y: lifted ? dragY : 0)
            .shadow(color: lifted ? Color.black.opacity(0.3) : elevationShadow(ChannelColor.pastel(at: barIndex)),
                    radius: lifted ? 22 : ((barState == .done || barState == .error) ? 14 : 8),
                    y: lifted ? 10 : ((barState == .done || barState == .error) ? 7 : 2))
            .overlay(alignment: .leading) {
                // the grip: press, hold a beat, drag — the pencil lifts.
                // the left edge is the grab zone; edit mode marks it
                ZStack {
                    if editing {
                        VStack(spacing: 3) {
                            Capsule().fill(Color.black.opacity(0.2)).frame(width: 14, height: 2)
                            Capsule().fill(Color.black.opacity(0.2)).frame(width: 14, height: 2)
                            Capsule().fill(Color.black.opacity(0.2)).frame(width: 14, height: 2)
                        }
                    }
                    Color.clear
                        .frame(width: 42)
                        .contentShape(Rectangle())
                        .gesture(reorderGesture)
                }
            }
            .zIndex(lifted ? 5 : 0)
            .onReceive(Self.timer) { _ in
                if previewLines.count > 1 { previewTick += 1 }
                if barState == .working && Date().timeIntervalSince(lastBeat) > 45 {
                    withAnimation(.easeInOut(duration: 0.5)) { barState = .stuck }
                }
                if barState == .stuck, Date().timeIntervalSince(lastBeat) <= 45 {
                    withAnimation(.easeOut(duration: 0.4)) { barState = .working }
                }
                if (barState == .working || barState == .stuck), Date().timeIntervalSince(lastBeat) > 150 {
                    withAnimation(.easeOut(duration: 0.8)) { barState = .idle; liveText = "" }
                }
            }
            .onAppear { if live.streamable && channel.kind == "harness" { live.connect() } }
            .onDisappear { live.disconnect() }
            .onChange(of: live.events.count) { _ in
                guard let e = live.events.last else { return }
                switch e.type {
                case "user":
                    barState = .working
                    lastBeat = Date()
                    liveText = e.text
                case "tool", "thinking":
                    guard barState != .done, barState != .error else { return }
                    barState = .working
                    lastBeat = Date()
                    let s = e.type == "tool" ? (e.preview.isEmpty ? "working…" : e.preview) : e.text
                    if !s.isEmpty { liveText = s }
                        case "done":
                    barState = .done
                    lastBeat = Date()
                    liveText = e.text
                    LineNotifications.post("done-\(channel.id)", title: "\(channel.name) is done", body: e.text.isEmpty ? "the line finished its run" : e.text)
                    // no auto-reset: the pencil stays popped until the next
                    // thing starts — that's the "waiting for you" signal
                case "error":
                    barState = .error
                    lastBeat = Date()
                    liveText = e.text.isEmpty ? "something broke" : e.text
                    LineNotifications.post("err-\(channel.id)", title: "\(channel.name) needs help", body: liveText)
                default: break
                }
            }
            // quick tap opens; one second of stillness starts the voice;
            // after that the finger may wander the bar without dropping it
            .gesture(pencilGesture)
    }

    // MARK: - the pencil's one gesture
    //
    // tap            → open the chat
    // hold still     → voice (anywhere on the pencil — the whole thing is
    //                  the button; a hold anywhere ≥0.35s talks)
    // rub along it   → reveal the real herdr space on the Mac
    // One gesture owns the finger, so nothing can jam the voice state.

    @State private var touchStart = Date.distantPast
    @State private var touchDown = false
    @State private var voiceArmed = false
    @State private var rubFired = false

    private var pencilGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                guard !editing else { return }
                if !touchDown { touchDown = true; touchStart = Date() }
                let moved = max(abs(v.translation.width), abs(v.translation.height))

                // another pencil owns the mic — fingers off
                if model.recordingChannel != nil && model.recordingChannel != channel.id { return }

                // a still press becomes a voice hold after a beat
                if moved < 12 && Date().timeIntervalSince(touchStart) > 0.35 {
                    voiceArmed = true
                    Haptics.tick()
                    if barState == .done || barState == .error { barState = .idle }
                    model.pressDown(channel: channel.id)
                    return
                }

                // a moving press is a rub — reveal at ~a third of the pencil
                let travel = abs(v.translation.width) + abs(v.translation.height) * 0.12
                    if travel > 110 && !rubFired {
                        rubFired = true
                        Haptics.tick()
                        let revealOn = UserDefaults.standard.object(forKey: "slappSwipeReveal") == nil
                            ? true : UserDefaults.standard.bool(forKey: "slappSwipeReveal")
                        if revealOn, let slug = model.slug(for: channel) ?? slugFromWebhook(channel.webhook) {
                            Task { await model.reveal(slug) }
                        }
                    }
            }
            .onEnded { _ in
                defer {
                    touchDown = false
                    touchStart = .distantPast
                    voiceArmed = false
                    rubFired = false
                }
                if voiceArmed {
                    if model.elapsed >= 0.9 {
                        model.pressUp()
                    } else {
                        model.cancelHold()
                    }
                    return
                }
                // a quick, still touch = open
                if !editing && Date().timeIntervalSince(touchStart) < 0.3 {
                    if model.recordingChannel == nil { onOpen() }
                }
            }
    }


    @ViewBuilder private var tileBody: some View {
        let pastel = ChannelColor.pastel(at: barIndex)
        HStack(alignment: .center, spacing: 12) {
            tileText
            Spacer(minLength: 0)
            if asleep {
                asleepPills
            }
        }
        .padding(.horizontal, 14)
        .frame(height: tall ? 96 : 78)
        .background(
            Rectangle()
                .fill(pastel.opacity(recording ? 1.0 : (barState == .idle ? 0.88 : 1.0)))
                // full sheet: the color runs past both edges — the tile stays
                // put, only the paint overflows
                .frame(width: UIScreen.main.bounds.width + 160)
        )
        .overlay(
            Rectangle()
                .strokeBorder(lineColor(pastel), lineWidth: barState == .done || barState == .error ? 2 : 0)
        )
        .rotationEffect(.degrees(lefty ? 7 : -7))

        .overlay { Streaks(tint: streakTint(pastel), active: recording || barState == .working,
                           state: barState, rideText: barState == .working ? liveText : "") }
        // done/error = the card pops off the paper: lifted, shadowed, waiting
        .shadow(color: elevationShadow(pastel),
                radius: (barState == .done || barState == .error) ? 14 : 8,
                y: (barState == .done || barState == .error) ? 7 : 2)
        .scaleEffect(barState == .done ? 1.03 : (barState == .error ? 1.02 : 1))
        .modifier(PulseIf(pulsing: barState == .stuck))
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: barState)
        .overlay(alignment: .topLeading) { watchedBadge }
        .overlay(alignment: .topTrailing) { editMinus }
        .contentShape(Rectangle())
        .gesture(editing ? reorderGesture : nil)
    }

    // the tile's words: name, age, and whatever is happening right now
    @ViewBuilder private var tileText: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(channel.name)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .lineLimit(1)
                if let last = channel.last {
                    Text(agoLabel(last.ts))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.45))
                }
            }
            if recording {
                    // the alive meter while you talk
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ChannelColor.alive)
                            .frame(width: max(14, CGFloat(level) * 190), height: 4)
                            .animation(.easeOut(duration: 0.08), value: level)
                        Text("\(Int(model.elapsed))s — release to send")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.75))
                    }
                } else if let current = previewLines.last {
                    HStack(alignment: .top, spacing: 5) {
                        Circle().fill(current.role == "agent" ? Color.black.opacity(0.7) : Color.black.opacity(0.3))
                            .frame(width: 4, height: 4).padding(.top, 4)
                        if current.text.isEmpty {
                            PhotoGlyph()
                            Text("photo")
                                .font(.system(size: 12))
                        } else {
                            Text(current.text)
                                .font(.system(size: 12, design: current.role == "agent" ? .serif : .default))
                                .foregroundStyle(Color.black.opacity(0.62))
                                .lineLimit(1)
                        }
                    }
        } else {
            Text(channel.kind == "harness" ? "live session — hold to talk" : "quiet — hold to talk")
                .font(.system(size: 11.5, design: .serif))
                .foregroundStyle(Color.black.opacity(0.4))
        }
        }
    }

    // the nanny is on this one
    @ViewBuilder private var watchedBadge: some View {
        if watched {
            Image(systemName: "eye")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ChannelColor.alive)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(white: 0.03).opacity(0.85)))
                .overlay(Circle().strokeBorder(ChannelColor.alive.opacity(0.6), lineWidth: 1))
                .offset(x: 5, y: -5)
        }
    }

    // edit mode: the minus that closes a session out
    @ViewBuilder private var editMinus: some View {
        if editing {
            Button {
                model.cancelHold()
                onRemove()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.red, Color(white: 0.1))
            }
            .offset(x: 8, y: -8)
        }
    }

    // the zzz pill and the close-it-out x, with their plain-words dialogs
    private var asleepPills: some View {
        HStack(spacing: 6) {
            Button {
                Haptics.tick()
                askWake = true
            } label: {
                Text("zzz")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.55)))
            }
            .buttonStyle(.plain)
            Button {
                Haptics.tick()
                askClose = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .padding(8.5)
                    .background(Capsule().fill(Color.white.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .confirmationDialog("close \(channel.name) out for good?", isPresented: $askClose, titleVisibility: .visible) {
                Button("close it out", role: .destructive) { Haptics.pencilTap(); onRemove() }
                Button("keep it asleep", role: .cancel) {}
            } message: {
                Text("its space on the Mac is already closed. this removes it from slapp — the repo and everything it wrote stay on disk.")
            }
        }
        .confirmationDialog("wake \(channel.name) on the Mac?", isPresented: $askWake, titleVisibility: .visible) {
            Button("wake it up") { Haptics.rise(); Task { await model.wake(model.slug(for: channel) ?? "") } }
            Button("leave it asleep", role: .cancel) {}
        } message: {
            Text("its space was closed in herdr. waking reopens a real pi session in its own space.")
        }
    }
}

// MARK: - Add channel

struct AddChannelSheet: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "harness"
    @State private var webhook = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("New channel") {
                    TextField("Name", text: $name)
                    Picker("Kind", selection: $kind) {
                        Text("Live session").tag("harness")
                        Text("Chat (telegram)").tag("chat")
                    }
                    if kind == "harness" {
                        TextField("Webhook URL", text: $webhook)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                Section {
                    Text(kind == "harness"
                         ? "Points at a session's live listener (http://host:8661). The bridge fills in its token automatically."
                         : "Speaks the classic path: captures go to your chat.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.orange).font(.system(size: 12))
                }
            }
            .navigationTitle("add channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        busy = true
                        Task {
                            let ok = await model.addChannel(name: name, kind: kind,
                                                            webhook: kind == "harness" ? webhook : nil)
                            busy = false
                            if ok { dismiss() } else { error = "couldn't add — check the bridge" }
                        }
                    }
                    .disabled(name.isEmpty || busy || (kind == "harness" && webhook.isEmpty))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// a stuck line breathes — slow pulse until someone looks
struct PulseIf: ViewModifier {
    var pulsing: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? (on ? 1.012 : 1.0) : 1)
            .opacity(pulsing ? (on ? 1.0 : 0.78) : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
            .onChange(of: pulsing) { p in if !p { on = false } }
    }
}

/// diagonal streaks of light riding each crossbar — the agent's words
/// travel along the line while it works
struct Streaks: View {
    @AppStorage("slappLeftHanded") private var lefty = false
    let tint: Color
    var active = false
    var state: ChannelTile.BarState = .idle
    var rideText = ""

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let speed = state == .working ? 0.16 : 0.075
                let slope = size.height * 0.42          // the diagonal drop
                for (i, phaseSpeed) in [speed, speed * 0.62].enumerated() {
                    let phase = (t * phaseSpeed).truncatingRemainder(dividingBy: 1.35)
                    let x = CGFloat(phase) * (size.width * 1.4) - size.width * 0.2
                    let y0 = size.height * (i == 0 ? 0.62 : 0.88)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: y0))
                    p.addLine(to: CGPoint(x: x + size.width * 0.30, y: y0 - slope))
                    let line = state == .error ? Color.red : (state == .done ? ChannelColor.alive : tint)
                    ctx.stroke(p, with: .color(line.opacity(active ? 0.55 : (state == .done ? 0.65 : 0.22))),
                               style: StrokeStyle(lineWidth: active ? 2.2 : (state == .done ? 2.0 : 1.3), lineCap: .round))
                }
                // the stream of words riding the upper diagonal
                if !rideText.isEmpty {
                    let prog = CGFloat((t * speed).truncatingRemainder(dividingBy: 1.35)) / 1.35
                    let fadeIn = min(1, prog / 0.14)
                    let fadeOut = min(1, (1 - prog) / 0.14)
                    let alpha = 0.8 * min(fadeIn, fadeOut)
                    if alpha > 0.02 {
                        let resolved = ctx.resolve(Text(rideText.suffix(60))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.black.opacity(alpha)))
                        let x = CGFloat(prog) * (size.width * 1.4) - size.width * 0.2
                        var tctx = ctx
                        tctx.translateBy(x: x, y: size.height * 0.60)
                        tctx.rotate(by: .degrees(lefty ? 9 : -9))
                        tctx.draw(resolved, at: CGPoint(x: size.width * 0.15, y: 0), anchor: .leading)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// corner triangles: bottom = the launcher, top = settings
struct CornerWedge: View {
    enum Corner { case topRight, bottomRight }
    let corner: Corner
    let tint: Color
    let icon: String
    let action: () -> Void
    private let s: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let tri = Path { p in
                switch corner {
                case .bottomRight:
                    p.move(to: CGPoint(x: w, y: h - s)); p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w - s, y: h)); p.closeSubpath()
                case .topRight:
                    p.move(to: CGPoint(x: w - s, y: 0)); p.addLine(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w, y: s)); p.closeSubpath()
                }
            }
            Button(action: action) {
                ZStack {
                    tri.fill(tint.opacity(0.10))
                    tri.stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .offset(corner == .bottomRight ? CGSize(width: -14, height: -14) : CGSize(width: -14, height: 14))
                }
            }
            .buttonStyle(.plain)
            .contentShape(tri)
        }
        .frame(width: s, height: s)
        .allowsHitTesting(true)
    }
}

extension Color {
    /// the pencil's ink — the pastel darkened enough to read on itself
    func ensureContrast() -> Color {
        UIColor(self).darker(0.45)
    }
}

extension UIColor {
    func darker(_ f: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: r * f, green: g * f, blue: b * f, opacity: Double(a))
    }
}

// MARK: - the peel — opening a chat peels in from the bottom-right corner,
// like lifting the page. No sliding-door push.
private var peel: Animation { .spring(response: 0.65, dampingFraction: 0.95) }

extension RootView {
    var peelTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: Peel(offset: lefty ? -90 : 90, scale: 1.12, angle: lefty ? -6 : 6, fade: 0),
                identity: Peel(offset: 0, scale: 1, angle: 0, fade: 1)),
            removal: .modifier(
                active: Peel(offset: lefty ? -110 : 110, scale: 1.08, angle: lefty ? 5 : -5, fade: 0),
                identity: Peel(offset: 0, scale: 1, angle: 0, fade: 1)))
    }
}

struct Peel: ViewModifier {
    var offset: CGFloat
    var scale: CGFloat
    var angle: Double
    var fade: Double
    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .bottomTrailing)
            .rotationEffect(.degrees(angle), anchor: .bottomTrailing)
            .offset(x: offset * 0.5, y: offset)
            .opacity(fade)
    }
}

/// webhook → session slug (shared by the pencil's swipe-up)
func slugFromWebhook(_ webhook: String) -> String? {
    guard let r = webhook.range(of: "/api/session/") else { return nil }
    return webhook[r.upperBound...].split(separator: "/").first.map(String.init)
}
