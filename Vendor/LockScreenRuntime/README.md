# SceneHarbor lock rendering runtime

MirageWallpaper GPL-3.0 source is pinned by runtime.json and included in
Vendor/MirageBaseline/source.tar.gz. Extract that archive, then apply
first-presented.patch at its root before building the MirageSceneSaver target.
The patch exposes actual CAMetalDrawable presentation readiness; it does not
change wallpaper rendering or scheduling. Both the source patch and frozen
binaries are included in SHA256SUMS. MoltenVK is licensed separately.

This local runtime links dependencies requiring macOS 26.0 or later. The saver
and wallpaper extension declare that minimum even though the main app can run
on older macOS releases.

## 0.13.6 鎖定畫面修正

framing.patch 是從固定來源封存重建所需的累積修補，已包含 first-presented.patch，不要重複套用。每個畫面各自持有場景、相機尺寸與 Metal 回呼；遠端圖層保留系統傳入的 bounds，冷啟動及首幀等待延長至 30 秒。
