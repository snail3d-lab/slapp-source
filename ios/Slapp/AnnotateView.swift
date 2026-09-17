import SwiftUI
import UIKit

// Mark up a screenshot or photo: circle it, point at it, caption it, send it.
// Glass over deep ink, lime ink by default.
struct AnnotateView: View {
    @AppStorage("slappLeftHanded") private var lefty = false
    let base: UIImage
    var tint: Color = Color(white: 0.90)   // the pencil's pastel, by default
    let onSend: (UIImage, String) -> Void

    // paper + ink — the house look, no dark mode anywhere
    private let paper = Color(white: 0.90)
    private let inkColor = Color.black.opacity(0.8)
    private let line = Color.black.opacity(0.1)
    private let muted = Color.black.opacity(0.45)

    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [Stroke] = []
    @State private var current: Stroke?
    @State private var tool: Tool = .pen
    @State private var ink: Ink = .lime
    @State private var caption = ""
    @FocusState private var captionFocused: Bool

    enum Tool { case pen, arrow }
    enum Ink: String, CaseIterable, Identifiable {
        case lime, red, white
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .lime: return ChannelColor.alive
            case .red: return .red
            case .white: return .white
            }
        }
        var uiColor: UIColor {
            switch self {
            case .lime: return UIColor(red: 0.78, green: 0.94, blue: 0.30, alpha: 1)
            case .red: return UIColor(red: 0.95, green: 0.35, blue: 0.30, alpha: 1)
            case .white: return .white
            }
        }
    }

    var body: some View {
        ZStack {
            tint.ignoresSafeArea()
            // the stripe lays out 2600pt tall (rotation is visual-only) —
            // cage it in a GeometryReader or it drags the whole sheet's
            // layout off-screen
            GeometryReader { _ in
                PencilStripe(tint: .white, width: 500)
                    .opacity(0.14)
            }
            .ignoresSafeArea()
            VStack(spacing: 14) {
                canvasArea
                toolPill
                captionBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
        .preferredColorScheme(.light)
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            let disp = displayRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: base)
                    .resizable()
                    .scaledToFit()
                    .frame(width: disp.width, height: disp.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(line))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
                    .offset(x: disp.minX, y: disp.minY)
                // drawing layer exactly over the image
                ZStack {
                    ForEach(strokes) { s in StrokeView(stroke: s, displaySize: disp.size) }
                    if let c = current { StrokeView(stroke: c, displaySize: disp.size) }
                }
                .frame(width: disp.width, height: disp.height)
                .contentShape(Rectangle())
                .gesture(drawGesture(displayRect: disp))
                .offset(x: disp.minX, y: disp.minY)
            }
            .coordinateSpace(name: "annotatespace")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func displayRect(in geo: CGSize) -> CGRect {
        let aspect = base.size.width / max(base.size.height, 1)
        var w = geo.width, h = w / aspect
        if h > geo.height { h = geo.height; w = h * aspect }
        return CGRect(x: (geo.width - w) / 2, y: (geo.height - h) / 2, width: w, height: h)
    }

    private func drawGesture(displayRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("annotatespace"))
            .onChanged { v in
                if current == nil {
                    current = Stroke(color: ink.color, uiColor: ink.uiColor, isArrow: tool == .arrow)
                }
                let p = v.location
                let nx = (p.x - displayRect.minX) / max(displayRect.width, 1)
                let ny = (p.y - displayRect.minY) / max(displayRect.height, 1)
                guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }
                current?.points.append(CGPoint(x: nx, y: ny))
            }
            .onEnded { _ in
                if let c = current, c.points.count > 1 { strokes.append(c) }
                current = nil
            }
    }

    private var toolPill: some View {
        HStack(spacing: 18) {
            toolButton("pencil.tip", active: tool == .pen, label: "pen") { tool = .pen }
            toolButton("arrow.up.right", active: tool == .arrow, label: "arrow") { tool = .arrow }
            Rectangle().fill(line).frame(width: 1, height: 22)
            ForEach(Ink.allCases) { i in
                Button { ink = i } label: {
                    Circle()
                        .fill(i.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(inkColor.opacity(ink == i ? 0.9 : 0.15), lineWidth: ink == i ? 2.5 : 1))
                }
                .accessibilityLabel("ink \(i.rawValue)")
            }
            Rectangle().fill(line).frame(width: 1, height: 22)
            toolButton("arrow.uturn.backward.circle", active: false, label: "undo") { _ = strokes.popLast() }
            toolButton("trash", active: false, label: "clear") { strokes.removeAll() }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.white.opacity(0.55)))
                .overlay(Capsule().stroke(line)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }

    private func toolButton(_ icon: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        // selected = dark icon in a white disc with a dark ring — the old
        // chartreuse tint vanished on the cream pill
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.black.opacity(0.8) : muted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? Color.white.opacity(0.95) : Color.clear))
                .overlay(Circle().stroke(active ? Color.black.opacity(0.55) : Color.clear, lineWidth: 1.5))
        }
        .accessibilityLabel(label)
    }

    private var captionBar: some View {
        HStack(spacing: 12) {
            // the ONE button, same as chat: mic until words, then the plane —
            // on the left for a left hand
            MicSendButton(tint: tint, size: 46, draft: $caption, onSend: { send() }, onRipple: {}, bridgeHost: BridgeConfig().host)
            TextField("say what to change", text: $caption, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(inkColor)
                .lineLimit(1...3)
                .focused($captionFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(line))
                .accessibilityLabel("caption field")
        }
        .padding(.bottom, 30)
    }

    private func send() {
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !strokes.isEmpty || !cap.isEmpty else { return }
        onSend(base.annotated(with: strokes), cap)
        dismiss()
    }
}
