import AppKit

/// Original vector mark shared by the app icon, menu bar and notch.
/// A small note with a new leaf: something saved, encountered again.
enum RemeetArtwork {
    static func drawMark(in rect: NSRect, happy: Bool = false, muted: Bool = false,
                         template: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 100, yBy: rect.height / 100)
        transform.concat()

        let ink = NSColor(srgbRed: 0.12, green: 0.34, blue: 0.30, alpha: 1)
        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 49, y: 73))
        leaf.curve(to: NSPoint(x: 76, y: 97), controlPoint1: NSPoint(x: 46, y: 92), controlPoint2: NSPoint(x: 62, y: 99))
        leaf.curve(to: NSPoint(x: 49, y: 73), controlPoint1: NSPoint(x: 80, y: 80), controlPoint2: NSPoint(x: 63, y: 73))
        leaf.close()
        (template ? NSColor.black : muted ? .gray : NSColor(srgbRed: 0.36, green: 0.72, blue: 0.52, alpha: 1)).setFill()
        leaf.fill()

        let note = NSBezierPath()
        note.move(to: NSPoint(x: 25, y: 13))
        note.curve(to: NSPoint(x: 10, y: 35), controlPoint1: NSPoint(x: 13, y: 13), controlPoint2: NSPoint(x: 10, y: 23))
        note.line(to: NSPoint(x: 10, y: 55))
        note.curve(to: NSPoint(x: 35, y: 80), controlPoint1: NSPoint(x: 10, y: 72), controlPoint2: NSPoint(x: 19, y: 80))
        note.line(to: NSPoint(x: 65, y: 80))
        note.curve(to: NSPoint(x: 90, y: 55), controlPoint1: NSPoint(x: 82, y: 80), controlPoint2: NSPoint(x: 90, y: 70))
        note.line(to: NSPoint(x: 90, y: 35))
        note.curve(to: NSPoint(x: 65, y: 13), controlPoint1: NSPoint(x: 90, y: 20), controlPoint2: NSPoint(x: 79, y: 13))
        note.line(to: NSPoint(x: 43, y: 13))
        note.curve(to: NSPoint(x: 24, y: 3), controlPoint1: NSPoint(x: 36, y: 6), controlPoint2: NSPoint(x: 25, y: 0))
        note.close()
        if template {
            NSColor.black.setFill()
            note.fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
        } else {
            let top = muted ? NSColor(white: 0.73, alpha: 1) : NSColor(srgbRed: 0.76, green: 0.96, blue: 0.83, alpha: 1)
            let bottom = muted ? NSColor(white: 0.55, alpha: 1) : NSColor(srgbRed: 0.40, green: 0.79, blue: 0.67, alpha: 1)
            NSGradient(starting: bottom, ending: top)!.draw(in: note, angle: 90)
        }
        (template ? NSColor.black : ink).setFill()
        for x: CGFloat in [34, 61] {
            NSBezierPath(roundedRect: NSRect(x: x, y: happy ? 43 : 39, width: 6, height: happy ? 4 : 12),
                         xRadius: 3, yRadius: 3).fill()
        }
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 44, y: 31))
        smile.curve(to: NSPoint(x: 57, y: 31), controlPoint1: NSPoint(x: 47, y: 26), controlPoint2: NSPoint(x: 54, y: 26))
        (template ? NSColor.black : ink).setStroke()
        smile.lineWidth = 3
        smile.lineCapStyle = .round
        smile.stroke()
    }

    static func image(size: CGFloat, happy: Bool = false, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawMark(in: rect, happy: happy, template: template)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "回见 · 小芽"
        return image
    }

    static func drawAppIcon() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.84, green: 0.94, blue: 0.93, alpha: 1),
                   ending: NSColor(srgbRed: 0.98, green: 0.99, blue: 0.91, alpha: 1))!.draw(in: tile, angle: 80)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        tile.lineWidth = 3
        tile.stroke()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.18, green: 0.51, blue: 0.40, alpha: 0.18)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        drawMark(in: NSRect(x: 200, y: 195, width: 624, height: 624))
        NSGraphicsContext.restoreGraphicsState()
    }
}
