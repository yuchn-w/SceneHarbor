import Foundation

enum HarborPerformanceProfile: String, CaseIterable, Identifiable, Sendable {
    case minimal
    case efficient
    case balanced
    case quality

    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: return "極省資源"
        case .efficient: return "省電／低記憶體"
        case .balanced: return "平衡"
        case .quality: return "高畫質"
        }
    }
    var detail: String {
        switch self {
        case .minimal: return "15 FPS · 50% 渲染比例 · 不預載；動態較不流暢，畫面較柔和"
        case .efficient: return "24 FPS · 75% 渲染比例 · 不預載"
        case .balanced: return "30 FPS · 100% 渲染比例"
        case .quality: return "60 FPS · 100% 渲染比例"
        }
    }
    var fps: Int {
        switch self {
        case .minimal: return 15
        case .efficient: return 24
        case .balanced: return 30
        case .quality: return 60
        }
    }
    var allowsPreloading: Bool { self == .balanced || self == .quality }
    var renderScale: Double { self == .minimal ? 0.5 : self == .efficient ? 0.75 : 1 }
}

enum HarborPlaybackPolicy: Equatable {
    case run(fps: Int, renderScale: Double)
    case throttle(fps: Int, renderScale: Double)
    case pause
    case stop
}

enum HarborFullscreenAction: String, CaseIterable, Identifiable, Sendable {
    case pause
    case stop
    var id: String { rawValue }
    var title: String { self == .pause ? "暫停播放" : "停止並釋放記憶體" }
}

struct HarborGovernorInput: Equatable, Sendable {
    var memoryPressureStopped = false
    var manualPause = false
    var sleeping = false
    var sessionInactive = false
    var fullscreen = false
    var onBattery = false
    var lowPower = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var profile: HarborPerformanceProfile
    var pauseOnBattery = true
    var pauseOnLowPower = false
    var pauseOnThermal = false
    var pauseOnFullscreen = true
    var fullscreenAction: HarborFullscreenAction = .pause
    var stopOnThermalCritical = true
}

struct HarborPerformanceGovernor: Sendable {
    func policy(for input: HarborGovernorInput) -> HarborPlaybackPolicy {
        if input.memoryPressureStopped { return .stop }
        if input.thermalState == .critical && input.stopOnThermalCritical { return .stop }
        if input.manualPause || input.sleeping || input.sessionInactive { return .pause }
        if input.fullscreen && input.pauseOnFullscreen && input.fullscreenAction == .stop { return .stop }
        if input.fullscreen && input.pauseOnFullscreen { return .pause }
        if input.pauseOnBattery && input.onBattery { return .pause }
        if input.pauseOnLowPower && input.lowPower { return .pause }
        if input.pauseOnThermal && input.thermalState == .serious { return .pause }
        if input.lowPower || input.thermalState == .serious {
            return .throttle(fps: min(input.profile.fps, HarborPerformanceProfile.efficient.fps), renderScale: min(input.profile.renderScale, HarborPerformanceProfile.efficient.renderScale))
        }
        return .run(fps: input.profile.fps, renderScale: input.profile.renderScale)
    }

    /// Recover each display independently; a fullscreen window on another
    /// display must not hold this display stopped. Defer relaunch while paused.
    func displaysReadyToRestore(stopped: Set<String>, policies: [String: HarborPlaybackPolicy]) -> Set<String> {
        Set(stopped.filter { id in
            guard let policy = policies[id] else { return false }
            switch policy {
            case .run, .throttle: return true
            case .pause, .stop: return false
            }
        })
    }
}
