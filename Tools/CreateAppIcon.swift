import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon-1024.png")
let canvasSize = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("無法建立圖示畫布")
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("無法建立繪圖環境")
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

let tileRect = NSRect(x: 66, y: 66, width: 892, height: 892)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 214, yRadius: 214)

// 柔和陰影只增加與 Dock 的分離感，不形成方形底色。
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
tile.fill()
NSShadow().set()

NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.035, green: 0.042, blue: 0.052, alpha: 1)
])?.draw(in: tile, angle: -90)

// 液態玻璃感：上緣柔光、外框冷色折射與細微內框。
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let gloss = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.13),
    NSColor.white.withAlphaComponent(0.025),
    NSColor.clear
])
gloss?.draw(
    in: NSRect(x: tileRect.minX, y: tileRect.midY, width: tileRect.width, height: tileRect.height / 2),
    angle: -90
)
NSGraphicsContext.restoreGraphicsState()

NSColor(calibratedRed: 0.48, green: 0.52, blue: 0.60, alpha: 0.42).setStroke()
tile.lineWidth = 7
tile.stroke()

let innerEdge = NSBezierPath(
    roundedRect: tileRect.insetBy(dx: 9, dy: 9),
    xRadius: 205,
    yRadius: 205
)
NSColor.white.withAlphaComponent(0.10).setStroke()
innerEdge.lineWidth = 3
innerEdge.stroke()

// 與狀態列相同的 photo.on.rectangle 標誌：兩張重疊相片、山形與太陽。
// 保留深色玻璃底，讓白色線稿在 Dock、Finder 與小尺寸列表都清楚。
func photoCard(_ rect: NSRect, radius: CGFloat, lineWidth: CGFloat) -> NSBezierPath {
    let card = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    card.lineWidth = lineWidth
    card.lineCapStyle = .round
    card.lineJoinStyle = .round
    return card
}

// 後方相框右上移，與前框同尺寸並約 65% 重疊；整組外框仍以畫布中心對齊。
let backCard = photoCard(NSRect(x: 350, y: 405, width: 500, height: 330), radius: 42, lineWidth: 32)
NSColor.white.withAlphaComponent(0.88).setStroke()
backCard.stroke()

let frontCard = photoCard(NSRect(x: 175, y: 290, width: 500, height: 330), radius: 42, lineWidth: 32)
NSColor.white.setStroke()
frontCard.stroke()

NSGraphicsContext.saveGraphicsState()
frontCard.addClip()
let sun = NSBezierPath(ovalIn: NSRect(x: 245, y: 481, width: 58, height: 58))
NSColor.white.setFill()
sun.fill()

let mountain = NSBezierPath()
// 兩座山峰：左側較低、右側較高，中間保留清楚的山谷。
mountain.move(to: NSPoint(x: 209, y: 287))
mountain.line(to: NSPoint(x: 300, y: 385))
mountain.line(to: NSPoint(x: 350, y: 340))
mountain.line(to: NSPoint(x: 455, y: 465))
mountain.line(to: NSPoint(x: 625, y: 319))
mountain.line(to: NSPoint(x: 625, y: 287))
mountain.line(to: NSPoint(x: 209, y: 287))
mountain.close()
NSColor.white.setFill()
mountain.fill()
NSGraphicsContext.restoreGraphicsState()

// 內框的微弱高光，模仿截圖中圖示在深色選單列上的柔和反射。
NSColor.white.withAlphaComponent(0.18).setStroke()
let highlight = photoCard(NSRect(x: 187, y: 302, width: 476, height: 306), radius: 34, lineWidth: 4)
highlight.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("無法輸出 PNG")
}
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
