import AppKit
// crop in.png x y w h [scale] out.png : a w × h region from (x, y) (pixels, top-left origin),
// scaled by `scale` (default 2, nearest neighbour), to look at details closely.
let a = Array(CommandLine.arguments.dropFirst())
guard a.count >= 6, let img = NSImage(contentsOfFile: a[0]), let rep0 = img.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: img.tiffRepresentation!) else {
  print("usage: crop in.png x y w h [scale] out.png"); exit(1)
}
let x = Int(a[1])!, y = Int(a[2])!, w = Int(a[3])!, h = Int(a[4])!
let scale = a.count >= 7 ? Int(a[5])! : 2
let out = a.last!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
for j in 0..<(h * scale) {
  for i in 0..<(w * scale) {
    let c = rep0.colorAt(x: min(max(x + i / scale, 0), rep0.pixelsWide - 1), y: min(max(y + j / scale, 0), rep0.pixelsHigh - 1)) ?? .black
    rep.setColor(c, atX: i, y: j)
  }
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
