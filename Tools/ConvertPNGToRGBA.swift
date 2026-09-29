import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("用法：ConvertPNGToRGBA.swift <PNG 資料夾>\n", stderr)
    exit(1)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manager = FileManager.default
let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "png" }

for file in files {
    guard
        let sourceData = try? Data(contentsOf: file),
        let sourceRepresentation = NSBitmapImageRep(data: sourceData),
        let source = NSImage(data: sourceData),
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sourceRepresentation.pixelsWide,
            pixelsHigh: sourceRepresentation.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        throw CocoaError(.fileReadCorruptFile)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    source.draw(
        in: NSRect(x: 0, y: 0, width: representation.pixelsWide, height: representation.pixelsHigh),
        from: NSRect(x: 0, y: 0, width: source.size.width, height: source.size.height),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: file, options: .atomic)
}
