import Foundation
import Accelerate

/// PCM stays in memory. Produces WE's 64 left + 64 right normalized bins.
final class HarborAudioSpectrum {
    static let size = 2048
    private let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    private let window: [Float] = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size - 1)) }
    private var left: [Float] = []
    private var right: [Float] = []
    deinit { vDSP_DFT_DestroySetup(setup) }

    func append(left l: [Float], right r: [Float], sampleRate: Double) -> [Float]? {
        guard l.count == r.count, sampleRate > 0 else { return nil }
        left += l; right += r
        guard left.count >= Self.size else { return nil }
        let result = bins(Array(left.suffix(Self.size)), rate: sampleRate) + bins(Array(right.suffix(Self.size)), rate: sampleRate)
        left.removeAll(keepingCapacity: true); right.removeAll(keepingCapacity: true)
        return result
    }
    private func bins(_ samples: [Float], rate: Double) -> [Float] {
        let real = zip(samples, window).map { ($0.isFinite ? $0 : 0) * $1 }
        let zero = [Float](repeating: 0, count: Self.size)
        var outReal = zero, outImag = zero
        vDSP_DFT_Execute(setup, real, zero, &outReal, &outImag)
        let upper = min(rate / 2, 20_000)
        return (0..<64).map { bin in
            let low = 20 * pow(upper / 20, Double(bin) / 64)
            let high = 20 * pow(upper / 20, Double(bin + 1) / 64)
            let first = max(1, min(Self.size / 2 - 1, Int(low * Double(Self.size) / rate)))
            let last = max(first, min(Self.size / 2 - 1, Int(high * Double(Self.size) / rate)))
            let amplitude = (first...last).map { hypot(outReal[$0], outImag[$0]) * 4 / Float(Self.size) }.max() ?? 0
            return min(1, max(0, amplitude))
        }
    }
}
