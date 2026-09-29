import Foundation
import AppKit

@main struct AudioExperienceTests {
    static func main() throws {
        precondition(HarborAudioPolicy.volume([:]) == 0.5)
        precondition(HarborAudioPolicy.volume(["__volume": 0.0]) == 0)
        precondition(HarborAudioPolicy.volume(["__volume": 9.0]) == 1)
        precondition(HarborAudioPolicy.volume(["__volume": Double.nan]) == 0)
        precondition(HarborAudioPolicy.audibleDisplays(projects: ["external": "rain", "builtin": "rain"], preferred: "builtin") == ["builtin"])
        precondition(HarborAudioPolicy.audibleDisplays(projects: ["external": "rain", "builtin": "cozy"], preferred: "builtin") == ["external", "builtin"])
        precondition(HarborAudioPolicy.audibleDisplays(projects: ["external": "rain"], preferred: "builtin") == ["external"])
        print("PASS: audible defaults, preserve explicit mute, clamp invalid volume, mirrored audio dedup and fallback")
        var ducking = HarborAudioDuckingPolicy()
        ducking.receive(peak: 0, at: 0); precondition(!ducking.paused)
        ducking.receive(peak: 0.001, at: 1); precondition(ducking.paused)
        ducking.tick(at: 2.9); precondition(ducking.paused)
        ducking.receive(peak: 0.1, at: 2.9); ducking.tick(at: 4.8); precondition(ducking.paused)
        ducking.tick(at: 4.91); precondition(!ducking.paused)
        ducking.receive(peak: .nan, at: 5); precondition(!ducking.paused)
        ducking.receive(peak: 1, at: 6); ducking.reset(); precondition(!ducking.paused)
        for name in ["heard", "SceneHarborSceneRenderer", "SceneHarborWebRenderer"] {
            precondition(HarborAudioDuckingPolicy.isBackgroundSource(bundleID: nil, executable: name, ownProcess: false))
        }
        precondition(HarborAudioDuckingPolicy.isBackgroundSource(bundleID: nil, executable: "child", ownProcess: true))
        precondition(!HarborAudioDuckingPolicy.isBackgroundSource(bundleID: "com.google.Chrome.helper", executable: "Chrome", ownProcess: false))
        let saved: [String: Any] = ["__volume": 0.7]
        precondition(HarborAudioPolicy.effectiveVolume(saved, enabled: true, pausedForOtherAudio: true) == 0)
        precondition(HarborAudioPolicy.effectiveVolume(saved, enabled: true, pausedForOtherAudio: false) == 0.7)
        precondition(HarborAudioPolicy.effectiveVolume(["__volume": 0.7, "__audioMuted": true], enabled: true, pausedForOtherAudio: false) == 0)
        precondition(HarborAudioPolicy.effectiveVolume(saved, enabled: false, pausedForOtherAudio: false) == 0)
        print("PASS: external-audio hold/recovery, silence and NaN, self/ambient exclusions, preserve independent volume and manual mute")
        let analyzer = HarborAudioSpectrum()
        let n = HarborAudioSpectrum.size
        let left = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        let right = (0..<n).map { Float(0.25 * sin(2 * Double.pi * 2000 * Double($0) / 48000)) }
        let spectrum = analyzer.append(left: left, right: right, sampleRate: 48000)!
        precondition(spectrum.count == 128 && spectrum.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        let lPeak = spectrum.prefix(64).enumerated().max { $0.element < $1.element }!
        let rPeak = spectrum.suffix(64).enumerated().max { $0.element < $1.element }!
        precondition(abs(lPeak.offset - 28) <= 2 && abs(rPeak.offset - 42) <= 2)
        precondition(lPeak.element > rPeak.element && lPeak.element > 0.3)
        let silence = analyzer.append(left: Array(repeating: 0, count: n), right: Array(repeating: 0, count: n), sampleRate: 48000)!
        precondition(silence.allSatisfy { $0 == 0 })
        precondition(analyzer.append(left: [1], right: [], sampleRate: 48000) == nil)
        print("PASS: real PCM stereo FFT, frequency separation, normalized 128 bins, silence and malformed input")
        let icon = HarborMenuBarIcon.image()
        precondition(!icon.isTemplate && icon.size == NSSize(width: 22, height: 18))
        let canvas = NSImage(size: NSSize(width: 220, height: 90))
        canvas.lockFocus()
        NSColor(white: 0.45, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 110, height: 90).fill()
        NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 110, y: 0, width: 110, height: 90).fill()
        icon.draw(in: NSRect(x: 11, y: 9, width: 88, height: 72))
        icon.draw(in: NSRect(x: 121, y: 9, width: 88, height: 72))
        canvas.unlockFocus()
        let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "evidence/status-icon-094.png"))
        print("PASS: single-frame white icon rendered without template recoloring")
    }
}
