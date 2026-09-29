import AppKit

/// One photo frame: no rear outline crossing the mountain at menu-bar scale.
enum HarborMenuBarIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.white.setStroke()
            NSColor.white.setFill()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 18, height: 14), xRadius: 2, yRadius: 2)
            frame.lineWidth = 1.5
            frame.stroke()
            let mountain = NSBezierPath()
            mountain.move(to: NSPoint(x: 4.5, y: 5))
            mountain.line(to: NSPoint(x: 8.5, y: 9.5))
            mountain.line(to: NSPoint(x: 11.5, y: 6.5))
            mountain.line(to: NSPoint(x: 14, y: 9))
            mountain.line(to: NSPoint(x: 17.5, y: 5))
            mountain.lineWidth = 1.5
            mountain.lineJoinStyle = .round
            mountain.lineCapStyle = .round
            mountain.stroke()
            NSBezierPath(ovalIn: NSRect(x: 13.5, y: 11.5, width: 2, height: 2)).fill()
            return true
        }
        // Preserve white pixels instead of allowing AppKit to retint the icon black.
        image.isTemplate = false
        return image
    }
}
