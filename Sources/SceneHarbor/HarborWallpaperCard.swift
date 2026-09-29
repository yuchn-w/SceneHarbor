import AppKit
import SwiftUI
import ImageIO

@MainActor
private enum HarborArtworkCache {
    static let images: HarborMemoryCache<NSURL, NSImage> = {
        let cache = HarborMemoryCache<NSURL, NSImage>(costLimit: 24 * 1024 * 1024, countLimit: 128)
        return cache
    }()
}

struct HarborArtwork: View {
    let url: URL?
    var fallbackID: String?
    var fallbackTitle: String = ""
    var fit = false
    var aspectChanged: ((Double) -> Void)? = nil
    @State private var loaded: NSImage?
    @State private var failed = false
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = loaded {
                    if fit { Image(nsImage: image).resizable().scaledToFit() }
                    else { HarborFilledPreviewImage(image: image) }
                } else {
                    Rectangle().fill(.quaternary).overlay {
                        if failed || url == nil { Image(systemName: "photo").foregroundStyle(.secondary).accessibilityLabel("無法載入預覽圖") }
                        else { ProgressView().controlSize(.small) }
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: "\(url?.absoluteString ?? "")|\(fallbackID ?? "")") {
            loaded = nil; failed = false
            let resolvedURL: URL?
            if url == nil, let fallbackID, !fallbackID.isEmpty, fallbackID.allSatisfy(\.isNumber) {
                resolvedURL = try? await SteamWorkshopAPI().query(searchText: fallbackID).items.first?.previewURL
            } else {
                resolvedURL = url
            }
            try? Task.checkCancellation()
            guard !Task.isCancelled else { return }
            guard let url = resolvedURL else { failed = true; return }
            let asset = await HarborPreviewAssetCache.shared.loadPoster(url)
            guard !Task.isCancelled else { return }
            loaded = asset?.poster; failed = asset == nil
            if let image = asset?.poster, let ratio = HarborPreviewGeometry.valid(image.size.width / max(1, image.size.height)) { aspectChanged?(ratio) }
        }
    }

    private func loadImage(from url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = HarborArtworkCache.images.object(forKey: url as NSURL) { return cached }
        guard let data = try? await Task.detached(priority: .utility, operation: { try Data(contentsOf: url) }).value,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        HarborArtworkCache.images.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        return image
    }
}

struct HarborWallpaperCard: View {
    let item: SteamWorkshopItem
    let selected: Bool
    let installed: Bool
    let progress: SteamDownloadProgress?
    let select: () -> Void
    let apply: () -> Void
    var cardAspect: Double = 16.0 / 10.0
    var hoverContent: (() -> AnyView)? = nil
    var hoverChanged: (Bool) -> Void = { _ in }
    var artworkContent: ((Bool) -> AnyView)? = nil
    @State private var hovered = false

    private var typeSymbol: String {
        switch item.type.lowercased() { case "video": return "play.rectangle"; case "scene": return "cube.transparent"; case "web": return "globe"; case "image": return "photo"; default: return "questionmark" }
    }
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let artworkContent { artworkContent(hovered) }
                else { HarborArtwork(url: item.previewURL, fallbackID: item.id, fallbackTitle: item.title, fit: false) }
            }.aspectRatio(cardAspect, contentMode: .fit)
                .overlay { if hovered, let hoverContent { hoverContent() } }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Label(item.displayType, systemImage: typeSymbol)
                        .font(.system(size: 9, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule()).foregroundStyle(.primary).padding(6)
                        .help(item.typeExplanation)
                }
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.title)
                if let progress, !progress.isFinished {
                    ProgressView(value: progress.progress).controlSize(.mini).frame(width: 42)
                    Text("\(Int(progress.progress * 100))%").monospacedDigit()
                } else {
                    Label(installed ? HarborLanguage.text("已安裝", "Installed") : item.available ? item.formattedSubscriptions : HarborLanguage.text("無法存取", "Unavailable"), systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    Text(item.qualityLabel)
                }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            .frame(height: 14)
            .padding(.horizontal, 3).padding(.bottom, 1)
        }.padding(4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.accentColor.opacity(0.08) : Color.clear).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovered ? 0.18 : 0.06), lineWidth: selected ? 2 : 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(hovered ? 0.10 : 0.04), radius: hovered ? 8 : 3, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    var body: some View {
        Button(action: select) { cardContent }
            .buttonStyle(.plain)
            .onHover { hovered = $0; hoverChanged($0) }
            .onDisappear { hovered = false; hoverChanged(false) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if installed { apply() } })
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button("選取作品", action: select)
                if installed { Button("套用桌布", action: apply) }
            }
    }
}
