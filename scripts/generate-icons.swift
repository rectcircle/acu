import AppKit
import Foundation

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func fourPointStar(
    center: NSPoint,
    outerRadius: CGFloat,
    innerRadius: CGFloat
) -> NSBezierPath {
    let path = NSBezierPath()
    for index in 0..<8 {
        let angle = CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 4
        let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
        let point = NSPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
        index == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

private func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to create bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        fatalError("Unable to create graphics context")
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return representation
}

private func shieldPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 512, y: 788))
    path.curve(
        to: NSPoint(x: 716, y: 708),
        controlPoint1: NSPoint(x: 598, y: 735),
        controlPoint2: NSPoint(x: 662, y: 730)
    )
    path.line(to: NSPoint(x: 716, y: 516))
    path.curve(
        to: NSPoint(x: 512, y: 260),
        controlPoint1: NSPoint(x: 716, y: 390),
        controlPoint2: NSPoint(x: 632, y: 304)
    )
    path.curve(
        to: NSPoint(x: 308, y: 516),
        controlPoint1: NSPoint(x: 392, y: 304),
        controlPoint2: NSPoint(x: 308, y: 390)
    )
    path.line(to: NSPoint(x: 308, y: 708))
    path.curve(
        to: NSPoint(x: 512, y: 788),
        controlPoint1: NSPoint(x: 362, y: 730),
        controlPoint2: NSPoint(x: 426, y: 735)
    )
    path.close()
    return path
}

private func renderAppIcon() -> NSBitmapImageRep {
    bitmap(width: 1024, height: 1024) {
        let tileRect = NSRect(x: 82, y: 88, width: 860, height: 860)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 196, yRadius: 196)

        NSGraphicsContext.saveGraphicsState()
        let tileShadow = NSShadow()
        tileShadow.shadowColor = color(0x000000, alpha: 0.30)
        tileShadow.shadowBlurRadius = 24
        tileShadow.shadowOffset = NSSize(width: 0, height: -12)
        tileShadow.set()
        color(0x12181A).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        let background = NSGradient(colors: [
            color(0x242D30),
            color(0x101517),
        ])!
        background.draw(in: tile, angle: 90)
        color(0xFFFFFF, alpha: 0.10).setStroke()
        tile.lineWidth = 2
        tile.stroke()

        let shield = shieldPath()
        color(0xFFFFFF, alpha: 0.035).setFill()
        shield.fill()
        color(0xF1F5F4, alpha: 0.92).setStroke()
        shield.lineJoinStyle = .round
        shield.lineWidth = 34
        shield.stroke()

        let track = NSBezierPath()
        track.appendArc(
            withCenter: NSPoint(x: 512, y: 508),
            radius: 122,
            startAngle: 96,
            endAngle: 340,
            clockwise: false
        )
        track.lineCapStyle = .round
        color(0x35D1C5).setStroke()
        track.lineWidth = 38
        track.stroke()

        let starAngle = CGFloat(55 * Double.pi / 180)
        let starCenter = NSPoint(
            x: 512 + cos(starAngle) * 122,
            y: 508 + sin(starAngle) * 122
        )
        color(0xF7A43B).setFill()
        fourPointStar(
            center: starCenter,
            outerRadius: 30,
            innerRadius: 11
        ).fill()
    }
}

private func drawStatusIcon() {
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 9, y: 16.2))
    shield.curve(
        to: NSPoint(x: 14.8, y: 13.9),
        controlPoint1: NSPoint(x: 11.5, y: 14.7),
        controlPoint2: NSPoint(x: 13.3, y: 14.7)
    )
    shield.line(to: NSPoint(x: 14.8, y: 8.8))
    shield.curve(
        to: NSPoint(x: 9, y: 2.1),
        controlPoint1: NSPoint(x: 14.8, y: 5.5),
        controlPoint2: NSPoint(x: 12.4, y: 3.2)
    )
    shield.curve(
        to: NSPoint(x: 3.2, y: 8.8),
        controlPoint1: NSPoint(x: 5.6, y: 3.2),
        controlPoint2: NSPoint(x: 3.2, y: 5.5)
    )
    shield.line(to: NSPoint(x: 3.2, y: 13.9))
    shield.curve(
        to: NSPoint(x: 9, y: 16.2),
        controlPoint1: NSPoint(x: 4.7, y: 14.7),
        controlPoint2: NSPoint(x: 6.5, y: 14.7)
    )
    shield.close()
    shield.lineJoinStyle = .round
    shield.lineWidth = 1.45
    NSColor.black.setStroke()
    shield.stroke()

    let track = NSBezierPath()
    track.appendArc(
        withCenter: NSPoint(x: 9, y: 9.1),
        radius: 3.25,
        startAngle: 103,
        endAngle: 338,
        clockwise: false
    )
    track.lineCapStyle = .round
    track.lineWidth = 1.55
    track.stroke()

    let angle = CGFloat(57 * Double.pi / 180)
    let starCenter = NSPoint(
        x: 9 + cos(angle) * 3.25,
        y: 9.1 + sin(angle) * 3.25
    )
    NSColor.black.setFill()
    fourPointStar(
        center: starCenter,
        outerRadius: 1.35,
        innerRadius: 0.50
    ).fill()
}

private func writePNG(_ image: NSBitmapImageRep, to path: String) throws {
    guard let data = image.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode PNG")
    }
    try data.write(to: URL(fileURLWithPath: path))
}

private func writeStatusPDF(to path: String) {
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard
        let consumer = CGDataConsumer(
            url: URL(fileURLWithPath: path) as CFURL
        ),
        let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        )
    else {
        fatalError("Unable to create PDF context")
    }

    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(
        cgContext: context,
        flipped: false
    )
    drawStatusIcon()
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate-icons.swift APP_ICON_PATH STATUS_PDF_PATH\n", stderr)
    exit(2)
}

try writePNG(renderAppIcon(), to: CommandLine.arguments[1])
writeStatusPDF(to: CommandLine.arguments[2])
