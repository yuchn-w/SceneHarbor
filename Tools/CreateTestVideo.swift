import AVFoundation
import CoreVideo
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outputURL)

let width = 960
let height = 540
let framesPerSecond: Int32 = 30
let frameCount = 90

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_600_000,
            AVVideoExpectedSourceFrameRateKey: framesPerSecond
        ]
    ]
)
input.expectsMediaDataInRealTime = false

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ]
)

guard writer.canAdd(input) else { fatalError("無法加入影片軌") }
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.002)
    }

    var optionalBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &optionalBuffer
    )
    guard let buffer = optionalBuffer else { fatalError("無法取得像素緩衝區") }

    CVPixelBufferLockBaseAddress(buffer, [])
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let phase = Double(frame) / Double(frameCount)

    for y in 0..<height {
        let vertical = Double(y) / Double(height)
        for x in 0..<width {
            let horizontal = Double(x) / Double(width)
            let wave = (sin((horizontal + phase) * .pi * 2) + 1) * 0.5
            let offset = y * bytesPerRow + x * 4
            pointer[offset] = UInt8(48 + 72 * wave)
            pointer[offset + 1] = UInt8(52 + 92 * (1 - vertical))
            pointer[offset + 2] = UInt8(18 + 44 * vertical)
            pointer[offset + 3] = 255
        }
    }

    CVPixelBufferUnlockBaseAddress(buffer, [])
    let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
    adaptor.append(buffer, withPresentationTime: time)
}

input.markAsFinished()
await writer.finishWriting()

guard writer.status == .completed else {
    fatalError(writer.error?.localizedDescription ?? "測試影片建立失敗")
}

print(outputURL.path)
