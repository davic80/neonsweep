// Genera el icono "clean_" estilo retro-neón.
// Uso: swift scripts/make-icon.swift [top|center|bottom] [ruta_salida.png]
import AppKit

let position = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "center"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "assets/icon_1024.png"

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

let font = NSFont(name: "Menlo-Bold", size: 170) ?? NSFont.monospacedSystemFont(ofSize: 170, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: neon,
    .shadow: shadow,
]
let text = "neon\nsweep_" as NSString
let bounds = text.size(withAttributes: attrs)
let tx: CGFloat, ty: CGFloat
switch position {
case "center":  // centrado clásico
    tx = (size - bounds.width) / 2
    ty = (size - bounds.height) / 2 + 20
case "bottom":  // comando esperando intro: abajo a la izquierda
    tx = inset + 90
    ty = inset + 80
default:        // "top*": prompt arriba a la izquierda (elegido), con aire
    tx = inset + 110
    ty = size - inset - bounds.height - 110
}
text.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)

// Decoración opcional en la zona baja, como "salida" del comando
let dim = NSColor(red: 0.15, green: 0.55, blue: 0.12, alpha: 1)   // verde apagado
let dimShadow = NSShadow()
dimShadow.shadowColor = dim.withAlphaComponent(0.5)
dimShadow.shadowBlurRadius = 18
let smallFont = NSFont(name: "Menlo-Bold", size: 88) ?? NSFont.monospacedSystemFont(ofSize: 88, weight: .bold)
let dimAttrs: [NSAttributedString.Key: Any] = [
    .font: smallFont, .foregroundColor: dim, .shadow: dimShadow,
]
switch position {
case "top-bar":   // barra de progreso tenue, como si el barrido estuviera en marcha
    ("[██████████░░░░]" as NSString)
        .draw(at: NSPoint(x: inset + 90, y: inset + 90), withAttributes: dimAttrs)
case "top-ok":    // resultado del comando
    ("ok · 47 GB" as NSString)
        .draw(at: NSPoint(x: inset + 90, y: inset + 90), withAttributes: dimAttrs)
default:
    break
}

img.unlockFocus()

// PNG 1024
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("no se pudo renderizar el icono")
}
let fm = FileManager.default
try? fm.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: outPath))
print("OK \(outPath)")
