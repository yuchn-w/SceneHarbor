import CoreImage
import ImageIO
import Foundation

enum HDRImageInspector {
    /// Decode metadata off the main actor; neither filename nor extension participates in HDR classification.
    static func inspect(_ url: URL) -> HDRMediaInfo? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= 256 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let appleGain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        var isoGain = false
        if #available(macOS 15.0, *) {
            isoGain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        let image = CIImage(contentsOf: url, options: [.expandToHDR: true, .toneMapHDRtoSDR: false])
        var headroom: Float?
        if #available(macOS 15.0, *), let image { headroom = image.contentHeadroom }
        let transfer: String?
        if let space = image?.colorSpace, CGColorSpaceIsPQBased(space) { transfer = "pq" }
        else if let space = image?.colorSpace, CGColorSpaceIsHLGBased(space) { transfer = "hlg" }
        else { transfer = nil }
        if appleGain || isoGain { return info(.gainMap, hdr: true, headroom: headroom, transfer: transfer) }
        if let headroom, headroom > 1 { return info(.unknownHDR, hdr: true, headroom: headroom, transfer: transfer) }
        if transfer != nil { return HDRMediaInfo.video(transfer: transfer) }
        if headroom == 1 { return info(.sdr, hdr: false, headroom: headroom, transfer: nil) }
        // Older systems: only a known conventional RGB color space is evidence for SDR.
        if let name = image?.colorSpace?.name,
           [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.itur_709, CGColorSpace.itur_2020,
            CGColorSpace.adobeRGB1998].contains(name) {
            return info(.sdr, hdr: false, headroom: headroom, transfer: nil)
        }
        return info(.unknown, hdr: nil, headroom: headroom, transfer: nil)
    }

    private static func info(_ type: HDRType, hdr: Bool?, headroom: Float?, transfer: String?) -> HDRMediaInfo {
        HDRMediaInfo(isHDR: hdr, type: type, transfer: transfer, primaries: nil, peak: headroom.map(Double.init))
    }
}
