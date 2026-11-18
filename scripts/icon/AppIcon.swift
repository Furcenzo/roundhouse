// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo
//
// Draws the Roundhouse app icon as a 1024 × 1024 PNG: a railway turntable seen from above, its tracks fanning out to
// the stalls of the roundhouse – one hub, many connections; the stall lights are the reachability dots.
// Run via scripts/make-icon.sh (`swift scripts/icon/AppIcon.swift <output.png>`), which also builds the .icns.

import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

extension NSPoint {
    func offset(_ direction: NSPoint, by distance: CGFloat) -> NSPoint {
        NSPoint(x: x + direction.x * distance, y: y + direction.y * distance)
    }
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: macOS icon shape (824 pt body on a 1024 canvas) with a soft shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.shadowColor = color(0x000000, 0.3)
shadow.set()
color(0x2F6FE0).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x24466F), ending: color(0x0E1C30))!.draw(in: shape, angle: -90)
shape.addClip()

// The turntable sits low in the middle; tracks fan out over the upper half to the stalls.
let hub = NSPoint(x: 512, y: 285)
let angles: [CGFloat] = [36, 63, 90, 117, 144].map { $0 * .pi / 180 }
func point(_ angle: CGFloat, _ radius: CGFloat) -> NSPoint {
    NSPoint(x: hub.x + cos(angle) * radius, y: hub.y + sin(angle) * radius)
}

// The roundhouse: a ring segment behind the ends of the tracks.
let building = NSBezierPath()
building.appendArc(withCenter: hub, radius: 480, startAngle: 20, endAngle: 160)
building.appendArc(withCenter: hub, radius: 375, startAngle: 160, endAngle: 20, clockwise: true)
building.close()
color(0xFFFFFF, 0.08).setFill()
building.fill()

// Tracks: two rails with sleepers.
for angle in angles {
    let normal = NSPoint(x: -sin(angle), y: cos(angle))
    for side: CGFloat in [-1, 1] {
        let rail = NSBezierPath()
        rail.move(to: point(angle, 165).offset(normal, by: 22 * side))
        rail.line(to: point(angle, 385).offset(normal, by: 22 * side))
        rail.lineWidth = 14
        rail.lineCapStyle = .round
        color(0xD8E4F2).setStroke()
        rail.stroke()
    }
    for step in stride(from: CGFloat(200), through: 360, by: 55) {
        let sleeper = NSBezierPath()
        sleeper.move(to: point(angle, step).offset(normal, by: -34))
        sleeper.line(to: point(angle, step).offset(normal, by: 34))
        sleeper.lineWidth = 9
        sleeper.lineCapStyle = .round
        color(0x8FA6C2, 0.7).setStroke()
        sleeper.stroke()
    }
}

// Stall lights at the end of each track: mostly green, one red.
for (index, angle) in angles.enumerated() {
    let light = point(angle, 430)
    let dot = NSBezierPath(ovalIn: NSRect(x: light.x - 32, y: light.y - 32, width: 64, height: 64))
    (index == 3 ? color(0xFF5A52) : color(0x4CD964)).setFill()
    dot.fill()
}

// The turntable: a pit with a ring and the bridge across it, turned toward one track.
let pit = NSBezierPath(ovalIn: NSRect(x: hub.x - 150, y: hub.y - 150, width: 300, height: 300))
color(0x0A1626).setFill()
pit.fill()
pit.lineWidth = 16
color(0xD8E4F2).setStroke()
pit.stroke()
let bridgeAngle = angles[1]
let along = NSPoint(x: cos(bridgeAngle), y: sin(bridgeAngle))
let across = NSPoint(x: -sin(bridgeAngle), y: cos(bridgeAngle))
let bridge = NSBezierPath()
bridge.move(to: hub.offset(along, by: -132).offset(across, by: -44))
bridge.line(to: hub.offset(along, by: 132).offset(across, by: -44))
bridge.line(to: hub.offset(along, by: 132).offset(across, by: 44))
bridge.line(to: hub.offset(along, by: -132).offset(across, by: 44))
bridge.close()
color(0x4C8DF6).setFill()
bridge.fill()
for side: CGFloat in [-1, 1] {
    let rail = NSBezierPath()
    rail.move(to: hub.offset(along, by: -122).offset(across, by: 20 * side))
    rail.line(to: hub.offset(along, by: 122).offset(across, by: 20 * side))
    rail.lineWidth = 12
    rail.lineCapStyle = .round
    color(0xFFFFFF).setStroke()
    rail.stroke()
}
let pivot = NSBezierPath(ovalIn: NSRect(x: hub.x - 30, y: hub.y - 30, width: 60, height: 60))
color(0xFFFFFF).setFill()
pivot.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
