// Genera assets/NeonSweep.icns: escoba ASCII estilo retro-neón.
// Uso: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Fondo: cuadrado redondeado casi negro con borde verde tenue
let inset: CGFloat = 60
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
NSColor(red: 0.043, green: 0.051, blue: 0.043, alpha: 1).setFill()
path.fill()
NSColor(red: 0.16, green: 0.30, blue: 0.16, alpha: 1).setStroke()
path.lineWidth = 8
path.stroke()

// Scanlines sutiles tipo CRT
NSColor(red: 0.224, green: 1.0, blue: 0.078, alpha: 0.04).setFill()
var y: CGFloat = inset + 20
while y < size - inset - 20 {
    NSRect(x: inset + 20, y: y, width: size - (inset + 20) * 2, height: 5).fill()
    y += 22
}

// "clean_" en letras de terminal con cursor
let neon = NSColor(red: 0.224, green: 1.0, blue: 0.078, alpha: 1)
let shadow = NSShadow()
shadow.shadowColor = neon.withAlphaComponent(0.85)
shadow.shadowBlurRadius = 46

let font = NSFont(name: "Menlo-Bold", size: 210) ?? NSFont.monospacedSystemFont(ofSize: 210, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: neon,
    .shadow: shadow,
]
let text = "clean_" as NSString
let bounds = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2 + 20),
          withAttributes: attrs)

img.unlockFocus()

// PNG 1024
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("no se pudo renderizar el icono")
}
let fm = FileManager.default
try? fm.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: "assets/icon_1024.png"))
print("OK assets/icon_1024.png")
