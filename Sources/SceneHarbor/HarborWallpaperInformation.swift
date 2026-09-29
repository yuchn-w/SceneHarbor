import SwiftUI
import AVFoundation
import ImageIO

/// Source specifications never depend on the preview renderer or the display.
struct HarborWallpaperInformation: View {
    let item: SteamWorkshopItem
    let project: WallpaperEngineProject?
    @State private var resolution: String?
    @State private var fps: String?
    private func t(_ zh: String, _ en: String) -> String { HarborLanguage.text(zh, en) }
    private var kind: String { project?.kind.rawValue ?? item.type.lowercased() }
    private var sourceFPS: String {
        if kind == "scene" || kind == "web" { return t("無固定幀率", "Not fixed") }
        if kind == "image" { return t("靜態圖片", "Still image") }
        return fps ?? item.authorFPSLabel ?? t("未提供", "Not provided")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("桌布來源規格", "Wallpaper source specifications")).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                cell(resolution == nil ? t("作者標示解析度", "Author resolution") : t("原生解析度", "Native resolution"),
                     resolution ?? item.resolutionLabel ?? t("未提供", "Not provided"))
                cell(fps == nil && item.authorFPSLabel != nil && kind == "video" ? t("作者標示幀率", "Author frame rate") : t("來源幀率", "Source frame rate"), sourceFPS)
            }
            if resolution == nil && item.qualityLabel != "未標示" {
                Text(t("作者畫質標籤：", "Author quality tag: ") + item.qualityLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Text(kind == "scene" || kind == "web"
                 ? t("即時繪製桌布沒有固定來源 FPS；作者標示不等同原檔驗證。", "Live-rendered wallpapers have no fixed source FPS; author labels are not file verification.")
                 : resolution == nil
                    ? t("尚無原始檔案規格；作者未提供的數值無法在下載前確認。", "Source file specifications are unavailable; missing author values cannot be confirmed before download.")
                    : t("數值讀取自桌布原始檔案。", "Values read from the original wallpaper file."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("harbor-wallpaper-statistics")
        .task(id: "\(item.id)|\(project?.entrypoint?.path ?? "")") {
            resolution = nil; fps = nil
            guard let project, let url = project.entrypoint else { return }
            if project.kind == .video {
                do {
                    let asset = AVURLAsset(url: url)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let rate = try await track.load(.nominalFrameRate)
                    guard !Task.isCancelled else { return }
                    let rect = CGRect(origin: .zero, size: size).applying(transform)
                    if rect.width != 0 && rect.height != 0 {
                        resolution = "\(Int(abs(rect.width).rounded())) × \(Int(abs(rect.height).rounded()))"
                    }
                    if rate.isFinite && rate > 0 { fps = String(format: "%.2f FPS", rate) }
                } catch { /* Author metadata remains available when file probing fails. */ }
            } else if project.kind == .image {
                let size: String? = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = values[kCGImagePropertyPixelWidth] as? Int,
                          let h = values[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
                    return "\(w) × \(h)"
                }.value
                guard !Task.isCancelled else { return }
                resolution = size
            }
        }
    }
    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
