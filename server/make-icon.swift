import AppKit

// slapp icon painter — every app is born with a face.
// args: <out.png> <letter> <hue 0-1> <sat 0-1>
// ink ground, hue glow, serif letter, one quiet ring. living cells.

let a = CommandLine.arguments
guard a.count >= 5, let out = a[1].cString(using: .utf8) else {
    FileHandle.standardError.write("usage: make-icon.swift <out.png> <letter> <hue> <sat>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = String(cString: out)
let letter = String(a[2].prefix(1)).uppercased()
let hue = Double(a[3]) ?? 0.5
let sat = Double(a[4]) ?? 0.6

let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// ink ground
let bg = CGGradient(colorsSpace: nil, colors: [
    CGColor(red: 0.075, green: 0.075, blue: 0.09, alpha: 1),
    CGColor(red: 0.033, green: 0.033, blue: 0.045, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// hue glow, breathing from above center
let glowColor = NSColor(hue: hue, saturation: sat, brightness: 0.85, alpha: 1)
let glow = CGGradient(colorsSpace: nil, colors: [
    glowColor.withAlphaComponent(0.42).cgColor,
    glowColor.withAlphaComponent(0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S/2, y: S*0.62), startRadius: 0,
                       endCenter: CGPoint(x: S/2, y: S*0.62), endRadius: 640, options: [])

// one quiet ring — the cells' concentric line
ctx.setStrokeColor(glowColor.withAlphaComponent(0.30).cgColor)
ctx.setLineWidth(6)
let ring = CGRect(x: 128, y: 128, width: S-256, height: S-256)
let path = CGPath(roundedRect: ring, cornerWidth: 224, cornerHeight: 224, transform: nil)
ctx.addPath(path)
ctx.strokePath()

// the letter, serif, luminous
let letterColor = NSColor(hue: hue, saturation: sat, brightness: 0.92, alpha: 1)
let desc = NSFont.systemFont(ofSize: 520, weight: .bold).fontDescriptor
    .withDesign(.serif)
let font = desc.flatMap { NSFont(descriptor: $0, size: 520) } ?? NSFont.systemFont(ofSize: 520, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: letterColor,
]
let str = NSAttributedString(string: letter, attributes: attrs)
let line = CTLineCreateWithAttributedString(str)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
ctx.textPosition = CGPoint(x: S/2 - bounds.width/2 - bounds.minX,
                           y: S/2 - bounds.height/2 - bounds.minY + 12)
CTLineDraw(line, ctx)

// out
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath)")
