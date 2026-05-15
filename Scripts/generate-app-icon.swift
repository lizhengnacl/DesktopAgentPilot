import AppKit
import Foundation

let appName = "DesktopAgentPilot"
let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let outputURL = rootURL
    .appendingPathComponent("Sources")
    .appendingPathComponent(appName)
    .appendingPathComponent("Resources")
    .appendingPathComponent("AppIcon.icns")

let tempURL = fileManager.temporaryDirectory
    .appendingPathComponent("\(appName)-AppIcon-\(UUID().uuidString)")
let iconsetURL = tempURL.appendingPathComponent("AppIcon.iconset")

try fileManager.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func roundedRect(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }

    try data.write(to: url)
}

func resized(_ image: NSImage, pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let result = NSImage(size: size)

    result.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size))
    result.unlockFocus()

    return result
}

func drawLine(from start: NSPoint, to end: NSPoint) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineCapStyle = .round
    path.lineWidth = 12
    NSColor(calibratedRed: 0.48, green: 0.94, blue: 0.91, alpha: 0.62).setStroke()
    path.stroke()
}

func drawDot(center: NSPoint, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    )).fill()
}

let master = NSImage(size: NSSize(width: 1024, height: 1024))
master.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
NSColor.clear.setFill()
canvas.fill()

let background = roundedRect(NSRect(x: 50, y: 50, width: 924, height: 924), 214)
NSGradient(colors: [
    NSColor(calibratedRed: 0.04, green: 0.15, blue: 0.26, alpha: 1.0),
    NSColor(calibratedRed: 0.07, green: 0.44, blue: 0.51, alpha: 1.0),
    NSColor(calibratedRed: 0.32, green: 0.74, blue: 0.55, alpha: 1.0),
])?.draw(in: background, angle: -42)

let sheen = roundedRect(NSRect(x: 96, y: 600, width: 832, height: 300), 150)
NSColor(calibratedWhite: 1.0, alpha: 0.10).setFill()
sheen.fill()

let bodyShadow = NSShadow()
bodyShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
bodyShadow.shadowOffset = NSSize(width: 0, height: -24)
bodyShadow.shadowBlurRadius = 46
bodyShadow.set()

let monitorFrame = NSRect(x: 176, y: 318, width: 672, height: 434)
NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
roundedRect(monitorFrame, 62).fill()

NSShadow().set()

let screenRect = NSRect(x: 228, y: 382, width: 568, height: 296)
NSGradient(colors: [
    NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.18, alpha: 1.0),
    NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.24, alpha: 1.0),
])?.draw(in: roundedRect(screenRect, 34), angle: 90)

let screenHighlight = roundedRect(NSRect(x: 258, y: 612, width: 506, height: 38), 19)
NSColor.white.withAlphaComponent(0.09).setFill()
screenHighlight.fill()

let nodeA = NSPoint(x: 352, y: 502)
let nodeB = NSPoint(x: 488, y: 574)
let nodeC = NSPoint(x: 632, y: 494)
let nodeD = NSPoint(x: 718, y: 580)
drawLine(from: nodeA, to: nodeB)
drawLine(from: nodeB, to: nodeC)
drawLine(from: nodeC, to: nodeD)
drawDot(center: nodeA, radius: 20, color: NSColor(calibratedRed: 0.58, green: 0.95, blue: 0.91, alpha: 1.0))
drawDot(center: nodeB, radius: 24, color: NSColor(calibratedRed: 0.96, green: 0.80, blue: 0.34, alpha: 1.0))
drawDot(center: nodeC, radius: 20, color: NSColor(calibratedRed: 0.67, green: 0.83, blue: 1.0, alpha: 1.0))
drawDot(center: nodeD, radius: 17, color: NSColor.white.withAlphaComponent(0.95))

let promptAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 88, weight: .bold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.96),
]
(">" as NSString).draw(at: NSPoint(x: 282, y: 430), withAttributes: promptAttributes)

NSColor(calibratedRed: 0.53, green: 0.95, blue: 0.72, alpha: 1.0).setFill()
roundedRect(NSRect(x: 388, y: 458, width: 134, height: 18), 9).fill()

NSColor(calibratedWhite: 0.92, alpha: 1.0).setFill()
roundedRect(NSRect(x: 456, y: 214, width: 112, height: 126), 24).fill()
roundedRect(NSRect(x: 348, y: 168, width: 328, height: 62), 31).fill()

NSColor(calibratedWhite: 1.0, alpha: 0.42).setFill()
roundedRect(NSRect(x: 230, y: 704, width: 560, height: 30), 15).fill()

master.unlockFocus()

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in specs {
    try writePNG(resized(master, pixels: pixels), to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(domain: "IconGeneration", code: Int(process.terminationStatus))
}

try? fileManager.removeItem(at: tempURL)
print("Generated \(outputURL.path)")
