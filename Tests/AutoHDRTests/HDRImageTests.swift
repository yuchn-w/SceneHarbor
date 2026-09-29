import Foundation
import CoreImage
import ImageIO

@MainActor
enum HDRImageTests {
    static func run() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/auto-hdr-tests/images")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = CIContext()
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let jpeg = root.appendingPathComponent("sdr-with-HDR-name.bin")
        try context.writeJPEGRepresentation(of: image, to: jpeg, colorSpace: srgb)
        precondition(HDRImageInspector.inspect(jpeg)?.isHDR == false, "L: actual SDR JPEG, misleading filename")
        let png = root.appendingPathComponent("sdr.png")
        try context.writePNGRepresentation(of: image, to: png, format: .RGBA8, colorSpace: srgb)
        precondition(HDRImageInspector.inspect(png)?.isHDR == false, "SDR PNG")
        let heic = root.appendingPathComponent("sdr.heic")
        try context.writeHEIFRepresentation(of: image, to: heic, format: .RGBA8, colorSpace: srgb)
        precondition(HDRImageInspector.inspect(heic)?.isHDR == false, "SDR HEIC")
        let pq = root.appendingPathComponent("pq.heic")
        try context.writeHEIF10Representation(of: image, to: pq, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!)
        precondition(HDRImageInspector.inspect(pq)?.isHDR == true, "M: actual HDR HEIC")
        if #available(macOS 15.0, *) {
            var hdr = CIImage(color: CIColor(red: 4, green: 3, blue: 2, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: image.extent)
            if #available(macOS 26.0, *) { hdr = hdr.settingContentHeadroom(4) }
            let gain = root.appendingPathComponent("gain-map.jpg")
            try context.writeJPEGRepresentation(of: image, to: gain, colorSpace: srgb, options: [.hdrImage: hdr])
            precondition(HDRImageInspector.inspect(gain)?.type == .gainMap, "N: actual gain map image")
        }
        let corrupt = root.appendingPathComponent("broken.heic")
        try Data("not an image".utf8).write(to: corrupt)
        precondition(HDRImageInspector.inspect(corrupt) == nil)
        print("PASS real image fixtures: SDR JPEG/PNG/HEIC, HDR PQ HEIC, HDR gain map JPEG, invalid file")
    }
}
