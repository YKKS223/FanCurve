// Renders build/AppIcon.icns from an SF Symbol so the app has a real icon
// without shipping binary assets in the repo. Run: swift scripts/makeicon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                                                                : FileManager.default.currentDirectoryPath)
let buildDir = root.appendingPathComponent("build")
let iconset = buildDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.86, alpha: 1),
                        NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.48, alpha: 1)])?
        .draw(in: path, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.56, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let box = NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2,
                         width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    guard let data = render(size: size) else { continue }
    try? data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", buildDir.appendingPathComponent("AppIcon.icns").path]
try? task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "AppIcon.icns を作成しました" : "iconutil が失敗しました")
