import AppKit
// montage out.png a.png b.png … : places images side by side at half size.
let args = Array(CommandLine.arguments.dropFirst())
let imgs = args.dropFirst().compactMap { NSImage(contentsOfFile: $0) }
let w = imgs.map { $0.size.width / 2 }.reduce(0, +), h = (imgs.map { $0.size.height / 2 }.max() ?? 0)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
var x: CGFloat = 0
for i in imgs { i.draw(in: NSRect(x: x, y: 0, width: i.size.width / 2, height: i.size.height / 2)); x += i.size.width / 2 }
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[0]))
