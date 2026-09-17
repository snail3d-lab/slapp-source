import SwiftUI
import UIKit

// An annotation stroke in normalized image coords (0…1), so it survives
// any display size and flattening back onto the full-res image.
struct Stroke: Identifiable {
    let id = UUID()
    var points: [CGPoint] = []
    var color: Color = ChannelColor.alive
    var uiColor: UIColor = UIColor(red: 0.78, green: 0.94, blue: 0.30, alpha: 1)
    var width: CGFloat = 0.012            // fraction of min(image side) — fat enough for the model to see
    var isArrow = false
}

// stroke path (pen + arrow tail)
struct StrokePath: Shape {
    let stroke: Stroke
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = stroke.points.map { CGPoint(x: $0.x * rect.width, y: $0.y * rect.height) }
        guard pts.count > 1 else { return p }
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }
}

// filled arrowhead at the end of an arrow stroke
struct ArrowHead: Shape {
    let stroke: Stroke
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = stroke.points.map { CGPoint(x: $0.x * rect.width, y: $0.y * rect.height) }
        guard pts.count > 1 else { return p }
        let a = pts[pts.count - 2], b = pts[pts.count - 1]
        let ang = atan2(b.y - a.y, b.x - a.x)
        let w = stroke.width * min(rect.width, rect.height)
        let L = max(14, w * 5)
        p.move(to: b)
        p.addLine(to: CGPoint(x: b.x - L * cos(ang - 0.42), y: b.y - L * sin(ang - 0.42)))
        p.addLine(to: CGPoint(x: b.x - L * cos(ang + 0.42), y: b.y - L * sin(ang + 0.42)))
        p.closeSubpath()
        return p
    }
}

// one stroke, drawn at display scale
struct StrokeView: View {
    let stroke: Stroke
    let displaySize: CGSize

    private var lineWidth: CGFloat {
        stroke.width * min(displaySize.width, displaySize.height)
    }

    var body: some View {
        StrokePath(stroke: stroke)
            .stroke(stroke.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .shadow(color: .black.opacity(0.35), radius: 1.5)
        if stroke.isArrow {
            ArrowHead(stroke: stroke)
                .fill(stroke.color)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
        }
    }
}

extension UIImage {
    // flatten annotations onto the full-res image
    func annotated(with strokes: [Stroke]) -> UIImage {
        let size = self.size
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = self.scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            self.draw(at: .zero)
            let cg = ctx.cgContext
            for s in strokes {
                let pts = s.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard pts.count > 1 else { continue }
                let w = s.width * min(size.width, size.height)
                cg.setStrokeColor(s.uiColor.cgColor)
                cg.setFillColor(s.uiColor.cgColor)
                cg.setLineWidth(w)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.beginPath()
                cg.move(to: pts[0])
                pts.dropFirst().forEach { cg.addLine(to: $0) }
                cg.strokePath()
                if s.isArrow {
                    let a = pts[pts.count - 2], b = pts[pts.count - 1]
                    let ang = atan2(b.y - a.y, b.x - a.x)
                    let L = max(14, w * 5)
                    cg.beginPath()
                    cg.move(to: b)
                    cg.addLine(to: CGPoint(x: b.x - L * cos(ang - 0.42), y: b.y - L * sin(ang - 0.42)))
                    cg.addLine(to: CGPoint(x: b.x - L * cos(ang + 0.42), y: b.y - L * sin(ang + 0.42)))
                    cg.closePath()
                    cg.fillPath()
                }
            }
        }
    }
}
