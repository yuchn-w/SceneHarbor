import Foundation
import CoreAudio
import Combine
import OSLog

/// Uses an audio-only Core Audio tap. No microphone, screen frames, recordings or network.
@MainActor
final class HarborSystemAudio: ObservableObject {
    @Published private(set) var status = "系統音訊反應已關閉"
    @Published private(set) var running = false
    var spectrum: (([Float]) -> Void)?
    var level: ((Float) -> Void)?
    private let meterOnly: Bool
    private var includedProcesses: [AudioObjectID]?
    init(meterOnly: Bool = false) { self.meterOnly = meterOnly }
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var generation = UUID()
    private var failed = false
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "system-audio")
    private var lastSignal: Bool?
    private var lastLevelUpdate = Date.distantPast
    private let queue = DispatchQueue(label: "org.sceneharbor.SceneHarbor.spectrum", qos: .userInitiated)

    func resetFailure() { failed = false }
    func update(enabled: Bool, needed: Bool, processesToInclude: [AudioObjectID]? = nil) {
        if includedProcesses != processesToInclude {
            stop(); includedProcesses = processesToInclude
        }
        guard enabled, needed else {
            stop(); status = enabled ? "等待支援音訊反應的桌布播放" : "系統音訊反應已關閉"
            return
        }
        guard !running, !failed else { return }
        guard #available(macOS 14.2, *) else { status = "系統音訊反應需要 macOS 14.2 以上"; return }
        do { try start() }
        catch { stop(); failed = true; status = "無法取得系統音訊：\(error.localizedDescription)；請檢查系統音訊錄製權限後重開此開關。" }
    }

    @available(macOS 14.2, *)
    private func start() throws {
        let description = includedProcesses.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SceneHarbor 音訊反應"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "建立音訊來源")
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "讀取音訊格式")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
            throw NSError(domain: "SceneHarbor.Audio", code: -1, userInfo: [NSLocalizedDescriptionKey: "音訊裝置不是支援的 Float32 PCM 格式"])
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SceneHarbor Spectrum",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), "建立音訊分析管線")
        let analyzer = HarborAudioSpectrum()
        let token = generation
        let sampleRate = format.mSampleRate
        let meterOnly = self.meterOnly
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { [weak self] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            guard frames > 0 else { return }
            let raw = data.assumingMemoryBound(to: Float.self)
            var left = [Float](repeating: 0, count: frames), right = left
            if channels >= 2 {
                for index in 0..<frames { left[index] = raw[index * channels]; right[index] = raw[index * channels + 1] }
            } else {
                for index in 0..<frames { left[index] = raw[index] }
                if buffers.count > 1, let rightData = buffers[1].mData,
                   Int(buffers[1].mDataByteSize) >= frames * MemoryLayout<Float>.size {
                    let rawRight = rightData.assumingMemoryBound(to: Float.self)
                    for index in 0..<frames { right[index] = rawRight[index] }
                } else { right = left }
            }
            if meterOnly {
                let peak = max(left.lazy.map { abs($0) }.max() ?? 0, right.lazy.map { abs($0) }.max() ?? 0)
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.running else { return }
                    self.level?(peak)
                }
                return
            }
            guard let bins = analyzer.append(left: left, right: right, sampleRate: sampleRate) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.running else { return }
                self.spectrum?(bins)
                if Date().timeIntervalSince(self.lastLevelUpdate) >= 1 {
                    let hasSignal = (bins.max() ?? 0) > 0.002
                    if self.lastSignal != hasSignal {
                        self.lastSignal = hasSignal
                        self.status = hasSignal ? "正在接收系統音訊，驅動音波效果" : "音訊管線已啟用，等待音樂訊號"
                        self.logger.notice("system audio signal present=\(hasSignal)")
                    }
                    self.lastLevelUpdate = Date()
                }
            }
        }, "連接頻譜分析")
        try check(AudioDeviceStart(device, io), "開始音訊反應")
        running = true
        logger.notice("system audio capture started; meterOnly=\(self.meterOnly)")
        status = "系統音訊反應已啟用（只在本機分析，不錄音）"
    }
    func stop() {
        let wasRunning = running
        generation = UUID()
        if device != 0 {
            if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        io = nil; device = 0
        if tap != 0, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        tap = 0; running = false; lastSignal = nil; lastLevelUpdate = .distantPast
        if wasRunning { logger.notice("system audio capture stopped; meterOnly=\(self.meterOnly)") }
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation)失敗（\(status)）"])
    }
}
