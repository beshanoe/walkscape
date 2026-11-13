// Draws the app icon: a person walking on a walking pad, the front half in the room, the back
// half in the forest. Vector drawing, redrawn at every size of a macOS .iconset.
//
//   build/tools/make-icon resources/AppIcon.iconset && iconutil -c icns resources/AppIcon.iconset
//   build/tools/make-icon --preview out.png        (one 1024 px PNG)

import AppKit
import SwiftUI

// Design space: 1024 × 1024, y down. The plate follows Apple's macOS grid (824 px, 100 px margin).
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let splitX: CGFloat = 512
let groundY: CGFloat = 752

func color(_ hex: UInt32) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
    alpha: 1)
}

let forestTop = color(0x2F7D52), forestBottom = color(0x1D5537)
let trees = [color(0x245F3D), color(0x3B8B5A), color(0x4CA36E)]
let forestFloor = color(0x1F4A31), dirtRoad = color(0xB0814F)
let wall = color(0xF1E7DA), floorColor = color(0xD9C4A6)
let glass = color(0xCFE4EF), frameColor = color(0xFFFFFF)
let padColor = color(0x2E3136), padTop = color(0x50555D)
let personInForest = color(0xF6EEE3), personInRoom = color(0x1F5E3B)

/// The walking figure facing right, feet on the ground, as one filled path.
func personPath() -> CGPath {
  let figure = CGMutablePath()
  figure.addEllipse(in: CGRect(x: 522 - 52, y: 244 - 52, width: 104, height: 104))
  func limb(_ points: [CGPoint], width: CGFloat) {
    let line = CGMutablePath()
    line.addLines(between: points)
    figure.addPath(line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
  }
  let shoulder = CGPoint(x: 516, y: 372), hip = CGPoint(x: 498, y: 512)
  limb([CGPoint(x: 518, y: 358), hip], width: 84)  // torso
  limb([shoulder, CGPoint(x: 476, y: 448), CGPoint(x: 438, y: 500)], width: 56)  // back arm
  limb([hip, CGPoint(x: 462, y: 604), CGPoint(x: 410, y: 672)], width: 64)  // back leg, heel lifting
  limb([hip, CGPoint(x: 556, y: 600), CGPoint(x: 590, y: 676)], width: 64)  // front leg
  limb([shoulder, CGPoint(x: 566, y: 446), CGPoint(x: 616, y: 476)], width: 56)  // front arm
  var down = CGAffineTransform(translationX: 0, y: groundY - 700)  // drawn for a ground line at 700
  return figure.copy(using: &down)!
}

func conifer(_ ctx: CGContext, x: CGFloat, width: CGFloat, height: CGFloat, color: CGColor) {
  ctx.setFillColor(color)
  ctx.move(to: CGPoint(x: x, y: groundY - height))
  ctx.addLine(to: CGPoint(x: x + width / 2, y: groundY))
  ctx.addLine(to: CGPoint(x: x - width / 2, y: groundY))
  ctx.closePath()
  ctx.fillPath()
}

func drawIcon(_ ctx: CGContext) {
  let squircle = Path(roundedRect: plate, cornerRadius: 185.4, style: .continuous).cgPath
  let left = CGRect(x: plate.minX, y: plate.minY, width: splitX - plate.minX, height: plate.height)
  let right = CGRect(x: splitX, y: plate.minY, width: plate.maxX - splitX, height: plate.height)

  // Plate and its shadow (as in Apple's template: soft, slightly below).
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
  ctx.addPath(squircle)
  ctx.setFillColor(wall)
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(squircle)
  ctx.clip()

  // Behind: the forest.
  ctx.saveGState()
  ctx.clip(to: left)
  let gradient = CGGradient(colorsSpace: nil, colors: [forestTop, forestBottom] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.minY), end: CGPoint(x: 0, y: groundY), options: [])
  conifer(ctx, x: 168, width: 176, height: 520, color: trees[0])
  conifer(ctx, x: 300, width: 220, height: 620, color: trees[1])
  conifer(ctx, x: 436, width: 186, height: 470, color: trees[2])
  ctx.setFillColor(forestFloor)
  ctx.fill(CGRect(x: plate.minX, y: groundY, width: splitX - plate.minX, height: plate.maxY - groundY))
  ctx.setFillColor(dirtRoad)  // the belt carries on as the forest road
  ctx.fill(CGRect(x: plate.minX, y: groundY, width: splitX - plate.minX, height: 46))
  ctx.restoreGState()

  // In front: the room.
  ctx.saveGState()
  ctx.clip(to: right)
  ctx.setFillColor(wall)
  ctx.fill(CGRect(x: splitX, y: plate.minY, width: plate.maxX - splitX, height: groundY - plate.minY))
  let window = CGRect(x: 664, y: 236, width: 172, height: 204)
  ctx.setFillColor(glass)
  ctx.fill(window)
  ctx.setStrokeColor(frameColor)
  ctx.setLineWidth(16)
  ctx.stroke(window)
  ctx.setLineWidth(10)
  ctx.strokeLineSegments(between: [
    CGPoint(x: window.midX, y: window.minY), CGPoint(x: window.midX, y: window.maxY),
    CGPoint(x: window.minX, y: window.midY), CGPoint(x: window.maxX, y: window.midY),
  ])
  ctx.setFillColor(floorColor)
  ctx.fill(CGRect(x: splitX, y: groundY, width: plate.maxX - splitX, height: plate.maxY - groundY))
  let pad = CGPath(roundedRect: CGRect(x: splitX - 60, y: groundY, width: 330, height: 46), cornerWidth: 23, cornerHeight: 23, transform: nil)
  ctx.addPath(pad)
  ctx.setFillColor(padColor)
  ctx.fillPath()
  ctx.setFillColor(padTop)
  ctx.fill(CGRect(x: splitX, y: groundY, width: 246, height: 9))
  ctx.restoreGState()

  // The person, in the colours of the other world on each side.
  let person = personPath()
  for (side, fill) in [(left, personInForest), (right, personInRoom)] {
    ctx.saveGState()
    ctx.clip(to: side)
    ctx.addPath(person)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
  }
  ctx.restoreGState()
}

func png(pixels: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: pixels, height: pixels)
  let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
  let scale = CGFloat(pixels) / 1024
  ctx.translateBy(x: 0, y: CGFloat(pixels))
  ctx.scaleBy(x: scale, y: -scale)
  drawIcon(ctx)
  return rep.representation(using: .png, properties: [:])!
}

let args = Array(CommandLine.arguments.dropFirst())
if args.count == 2, args[0] == "--preview" {
  try png(pixels: 1024).write(to: URL(fileURLWithPath: args[1]))
} else if args.count == 1 {
  let dir = URL(fileURLWithPath: args[0])
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: dir.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: dir.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
  }
} else {
  FileHandle.standardError.write("usage: make-icon <dir.iconset> | --preview <out.png>\n".data(using: .utf8)!)
  exit(2)
}
