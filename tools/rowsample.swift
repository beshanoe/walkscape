import AppKit
// Prints the colour of a row of pixels (x = 0,40,…) at y for each PNG given.
let y = Int(CommandLine.arguments[1])!
for path in CommandLine.arguments.dropFirst(2) {
  guard let rep = NSImage(contentsOfFile: path)?.representations.first as? NSBitmapImageRep else { continue }
  let cols = stride(from: 0, to: 480, by: 40).map { x -> String in
    let c = rep.colorAt(x: x, y: y)!
    return String(format: "%02x%02x%02x", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))
  }
  print((path as NSString).lastPathComponent, cols.joined(separator: " "))
}
