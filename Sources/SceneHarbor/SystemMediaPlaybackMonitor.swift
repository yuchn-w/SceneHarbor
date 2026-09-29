import Darwin
import Foundation

/// 讀取 macOS「播放中」中心的實際媒體狀態。
/// 這只取得播放／暫停布林值，不讀取曲名、歌詞或音訊內容。
@MainActor
final class SystemMediaPlaybackMonitor {
    private typealias Reply = @convention(block) (Bool) -> Void
    private typealias GetPlaying = @convention(c) (DispatchQueue, @escaping Reply) -> Void

    private let getPlaying: GetPlaying?

    init() {
        let framework = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(framework, RTLD_NOW),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            getPlaying = nil
            return
        }
        getPlaying = unsafeBitCast(symbol, to: GetPlaying.self)
    }

    func fetchIsPlaying(_ completion: @escaping (Bool) -> Void) {
        guard let getPlaying else {
            completion(false)
            return
        }
        getPlaying(.main) { playing in
            completion(playing)
        }
    }
}
