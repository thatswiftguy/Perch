import AppKit
import CoreGraphics
import Foundation

// Perch's icon: a bird sitting on the menu bar.
//
// Drawn in code so it can be regenerated at any size and reviewed as a diff. Deliberately
// NOT built from an SF Symbol - Apple's SF Symbols licence forbids their use in app icons.

let S: CGFloat = 1024
let inset: CGFloat = 100          // macOS icons sit in an 824pt square on a 1024pt canvas
let side = S - inset * 2
let radius: CGFloat = 185

let cream = CGColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1)
let shade = CGColor(red: 0.80, green: 0.78, blue: 0.73, alpha: 1)
let amber = CGColor(red: 0.94, green: 0.62, blue: 0.15, alpha: 1)
let plateInk = CGColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1)

/// Renders at any pixel size by scaling the 1024pt design grid, rather than downsampling
/// a single large bitmap - flat shapes stay crisp at 16pt that way.
func render(to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / S, y: CGFloat(pixels) / S)
    // The bird plus its perch is top-heavy on the plate; drop it so the space above the
    // head matches the space below the bar.

    let plate = CGRect(x: inset, y: inset, width: side, height: side)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.21, green: 0.23, blue: 0.30, alpha: 1),
        CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: S),
                           end: CGPoint(x: 0, y: inset), options: [])
    ctx.restoreGState()

    // Shift the subject only - the plate stays put. The bird plus its perch is
    // top-heavy otherwise, with twice as much empty plate below it as above.
    ctx.translateBy(x: 0, y: -46)

    // The perch: the menu bar the app lives on.
    let perchY: CGFloat = 300
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 224, y: perchY, width: 576, height: 30),
                       cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.fillPath()

    // Legs, drawn first so the body covers where they meet it.
    ctx.setFillColor(cream)
    for x in [CGFloat(446), CGFloat(546)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: perchY + 16, width: 32, height: 140),
                           cornerWidth: 16, cornerHeight: 16, transform: nil))
    }
    ctx.fillPath()

    // One continuous outline rather than unioned primitives. Overlapping ellipses and
    // triangles kept producing artefacts at the joins - a pinched tail, a wing reading as
    // a belly patch - because every seam had to be tuned against its neighbours. A single
    // path has no seams to get wrong.
    let bird = CGMutablePath()
    bird.move(to: CGPoint(x: 190, y: 700))                                  // beak tip
    bird.addLine(to: CGPoint(x: 306, y: 744))                               // beak, upper edge
    bird.addCurve(to: CGPoint(x: 408, y: 822),                              // forehead
                  control1: CGPoint(x: 332, y: 802), control2: CGPoint(x: 364, y: 824))
    bird.addCurve(to: CGPoint(x: 566, y: 700),                              // crown to nape
                  control1: CGPoint(x: 476, y: 820), control2: CGPoint(x: 548, y: 780))
    bird.addCurve(to: CGPoint(x: 664, y: 596),                              // upper back
                  control1: CGPoint(x: 602, y: 656), control2: CGPoint(x: 634, y: 626))
    bird.addLine(to: CGPoint(x: 838, y: 552))                               // tail, upper edge
    bird.addLine(to: CGPoint(x: 812, y: 452))                               // tail tip
    bird.addCurve(to: CGPoint(x: 596, y: 448),                              // tail underside
                  control1: CGPoint(x: 738, y: 426), control2: CGPoint(x: 664, y: 424))
    bird.addCurve(to: CGPoint(x: 420, y: 404),                              // belly
                  control1: CGPoint(x: 534, y: 398), control2: CGPoint(x: 468, y: 392))
    bird.addCurve(to: CGPoint(x: 288, y: 566),                              // breast
                  control1: CGPoint(x: 330, y: 414), control2: CGPoint(x: 288, y: 474))
    bird.addCurve(to: CGPoint(x: 306, y: 662),                              // throat
                  control1: CGPoint(x: 288, y: 614), control2: CGPoint(x: 292, y: 642))
    bird.closeSubpath()
    ctx.addPath(bird)
    ctx.fillPath()

    // Wing: a small tapered shape high on the body, where a folded wing actually sits.
    ctx.setFillColor(shade)
    let wing = CGMutablePath()
    wing.move(to: CGPoint(x: 430, y: 618))
    wing.addCurve(to: CGPoint(x: 648, y: 556),
                  control1: CGPoint(x: 512, y: 638), control2: CGPoint(x: 596, y: 602))
    wing.addCurve(to: CGPoint(x: 448, y: 522),
                  control1: CGPoint(x: 580, y: 502), control2: CGPoint(x: 508, y: 496))
    wing.addCurve(to: CGPoint(x: 430, y: 618),
                  control1: CGPoint(x: 416, y: 540), control2: CGPoint(x: 410, y: 584))
    ctx.addPath(wing)
    ctx.fillPath()

    // Eye, punched back to the plate colour so it survives down to 16pt.
    ctx.setFillColor(plateInk)
    ctx.fillEllipse(in: CGRect(x: 352, y: 706, width: 46, height: 46))

    // The one accent: the amber the app uses for "needs you", sitting on the bar like a
    // status light. Floating it above the bird read as decoration attached to nothing.
    ctx.setFillColor(amber)
    ctx.fillEllipse(in: CGRect(x: 706, y: 288, width: 54, height: 54))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Writes the appiconset directly - PNGs plus the Contents.json that indexes them - so
// regenerating the icon is one command and cannot drift from the catalog.
//
//   swift Scripts/generate-icon.swift Perch/Assets.xcassets/AppIcon.appiconset
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for px in [16, 32, 64, 128, 256, 512, 1024] {
    render(to: outDir.appending(path: "icon_\(px).png"), pixels: px)
}

// macOS wants each point size at 1x and 2x; the 2x of one size is the 1x of the next, so
// the same seven files cover all ten slots.
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                           (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
let entries = slots.map { size, scale in
    """
        {
          "filename" : "icon_\(size * scale).png",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(size)x\(size)"
        }
    """.trimmingCharacters(in: .whitespacesAndNewlines)
}
let json = """
{
  "images" : [
    \(entries.joined(separator: ",\n    "))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! json.write(to: outDir.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote 7 PNGs and Contents.json to \(outDir.path)")
