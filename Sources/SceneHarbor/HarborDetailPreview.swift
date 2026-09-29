import SwiftUI
import AppKit

struct HarborDetailPreview: View {
    let item: SteamWorkshopItem
    let project: WallpaperEngineProject?
    let settings: [String: Any]
    var steam: SteamServiceBridge? = nil
    var login: (() -> Void)? = nil
    @ObservedObject var session: HarborHoverPreview
    var enabled = true
    var expanded = false
    @AppStorage("HarborSelectedPreview") private var autoplay = true
    @AppStorage("HarborPreviewQuality") private var quality = "balanced"
    @State private var active = NSApplication.shared.isActive
    @State private var paused = false
    @State private var retry = 0
    @State private var manuallyStartedID: String?
    @State private var posterAspect: (id: String, ratio: Double)?
    @State private var nativeAspect: (id: String, ratio: Double)?
    private var resolved: WallpaperEngineProject? { project ?? (session.itemID == item.id ? session.resolvedProject : nil) }
    private var mediaIdentity: String {
        "\(item.id)|\(item.previewURL?.absoluteString ?? "")|\(item.updatedAt.timeIntervalSince1970)|\(resolved?.entrypoint?.path ?? "")|\(retry)"
    }
    private var displayAspect: Double {
        let source: Double
        if session.itemID == item.id, let image = session.image ?? session.animatedImage {
            source = image.size.width / max(1, image.size.height)
        } else if nativeAspect?.id == mediaIdentity { source = nativeAspect!.ratio }
        else if posterAspect?.id == mediaIdentity { source = posterAspect!.ratio }
        else { source = HarborPreviewGeometry.aspect(item) }
        // The inspector follows the displayed media, not the author's resolution
        // tag (which describes the wallpaper, not necessarily its square cover).
        return expanded ? (HarborPreviewGeometry.valid(source) ?? 16.0 / 9.0) : HarborPreviewGeometry.inspectorAspect(source)
    }
    private var wantsPlayback: Bool { autoplay || expanded || manuallyStartedID == item.id }
    private var previewSettings: [String: Any] { HarborPreviewGeometry.settings(settings, item: item) }
    private var hasPreviewMedia: Bool {
        session.player != nil || session.image != nil || session.animatedImage != nil
    }
    private var showingAuthorPreviewWhilePreparing: Bool {
        session.preparing && project == nil && session.resolvedProject == nil && hasPreviewMedia
    }
    private var previewSpeed: Double {
        let value = (previewSettings["__speed"] as? Double) ?? 1
        return value.isFinite ? min(4, max(0.1, value)) : 1
    }

    private var identity: String {
        var restartSettings = previewSettings
        // A speed change is applied to the current player/renderer. Keeping it
        // out of this task identity prevents a full preview reload.
        restartSettings["__speed"] = nil
        let data = (try? JSONSerialization.data(withJSONObject: restartSettings, options: [.sortedKeys])) ?? Data()
        return "\(item.id)|\(project?.entrypoint?.path ?? "")|\(data.base64EncodedString())|\(enabled && active && wantsPlayback)|\(quality)|\(retry)|\(steam?.isLoggedIn == true)"
    }
    var body: some View {
        let mediaKey = mediaIdentity
        return VStack(alignment: .leading, spacing: 8) {
            HarborInspectorPreviewViewport(ratio: displayAspect) {
                HarborWallpaperPoster(item: item, project: resolved, settings: previewSettings, fit: false,
                                      aspectChanged: { posterAspect = (mediaKey, $0) })
                    .overlay { HarborHoverLayer(preview: session, id: item.id, fit: false) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            .accessibilityIdentifier("harbor-detail-preview")
            HStack(spacing: 8) {
                if !enabled || !active {
                    Text("預覽已暫停")
                    Spacer(minLength: 0)
                } else if !wantsPlayback {
                    Text("自動預覽已關閉")
                    Spacer(minLength: 0)
                    Button("播放預覽") { manuallyStartedID = item.id }.buttonStyle(.borderless)
                } else if session.preparing && !hasPreviewMedia {
                    ProgressView().controlSize(.small)
                    Text(session.progress > 0 ? "載入預覽 \(Int(session.progress * 100))%" : "準備動態預覽…")
                    Spacer(minLength: 0)
                } else if session.resolvedProject?.kind == .image || project?.kind == .image {
                    Text("靜態圖片"); Spacer()
                } else if hasPreviewMedia {
                    Button {
                        paused.toggle(); session.setPaused(paused)
                    } label: {
                        Label(paused ? "繼續預覽" : "暫停預覽", systemImage: paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(.plain)
                    Spacer(minLength: 4)
                    Text(showingAuthorPreviewWhilePreparing ? "工坊預覽" : (resolved == nil ? "工坊動態預覽" : "實際桌布"))
                        .font(.caption2).lineLimit(1)
                    Image(systemName: "speaker.slash").help("預覽不播放聲音")
                } else if steam?.isLoggedIn != true && project == nil {
                    Button("登入 Steam 預覽", action: login ?? {}).buttonStyle(.borderless)
                    Spacer()
                } else {
                    Text(session.message.isEmpty ? "準備預覽…" : session.message).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("重試") { retry += 1 }.buttonStyle(.borderless)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if showingAuthorPreviewWhilePreparing {
                HStack(spacing: 6) {
                    if session.progress > 0 {
                        ProgressView(value: session.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 88)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(session.progress > 0
                         ? "實際桌布下載中 \(Int(session.progress * 100))%"
                         : "實際桌布準備中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: identity) {
            session.stop(); paused = false
            guard enabled, active, wantsPlayback else { return }
            session.begin(item: item, project: project, settings: previewSettings, delay: .zero, steam: steam)
        }
        .task(id: previewSpeed) {
            session.updateSpeed(previewSpeed)
        }
        .task(id: mediaIdentity) {
            let key = mediaIdentity
            guard let project = resolved, let ratio = await HarborPreviewGeometry.nativeAspect(project),
                  !Task.isCancelled, mediaIdentity == key else { return }
            nativeAspect = (key, ratio)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onChange(of: item.id) { _, _ in manuallyStartedID = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
        .onDisappear { session.stop() }
    }
}

/// Reserve the exact preview height before offering space to image/player views.
/// Their intrinsic sizes must never enlarge a ScrollView row or center a shorter
/// image in a taller invisible slot.
struct HarborInspectorPreviewViewport<Content: View>: View {
    let ratio: Double
    @ViewBuilder var content: () -> Content

    var body: some View {
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    content().frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipped()
    }
}
