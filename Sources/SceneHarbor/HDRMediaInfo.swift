import Foundation

enum HDRType: String {
    case sdr = "SDR", hdr10 = "HDR10", hlg = "HLG", dolbyVision = "Dolby Vision"
    case hdr10Plus = "HDR10+", unknownHDR = "HDR", gainMap = "HDR Gain Map", unknown = "判定中"
}

struct HDRMediaInfo: Equatable {
    let isHDR: Bool?
    let type: HDRType
    let transfer: String?
    let primaries: String?
    let peak: Double?

    static func video(transfer: String?, primaries: String? = nil, peak: Double? = nil,
                      dolbyVisionProfile: Int? = nil) -> HDRMediaInfo {
        let normalized = transfer?.lowercased().replacingOccurrences(of: "_", with: "-")
        let type: HDRType
        if let profile = dolbyVisionProfile, (1...10).contains(profile) { type = .dolbyVision }
        else {
            switch normalized {
            case "pq", "smpte2084", "smpte-st-2084": type = .hdr10
            case "hlg", "arib-std-b67": type = .hlg
            case "srgb", "bt.1886", "bt.709", "bt709", "gamma1.8", "gamma2.0", "gamma2.2", "gamma2.4", "gamma2.6", "gamma2.8": type = .sdr
            default: type = .unknown
            }
        }
        // Wide gamut, bit depth or sig-peak alone are not sufficient evidence of HDR.
        return HDRMediaInfo(isHDR: type == .unknown ? nil : type != .sdr,
                            type: type, transfer: transfer, primaries: primaries, peak: peak)
    }
}
