# SceneHarbor lock rendering runtime

MirageWallpaper GPL-3.0 source is pinned by runtime.json and included in
Vendor/MirageBaseline/source.tar.gz. Extract that archive, then apply
framing.patch at its root before building the MirageSceneSaver target.
This cumulative patch includes first-presented.patch; do not apply both.
The patch exposes actual CAMetalDrawable presentation readiness; it does not
change wallpaper rendering or scheduling. Both the source patch and frozen
binaries are included in SHA256SUMS. MoltenVK is licensed separately.

This local runtime links dependencies requiring macOS 26.0 or later. The saver
and wallpaper extension, as well as this public main app, declare that minimum.

## 0.13.6 鎖定畫面修正

framing.patch 是從固定來源封存重建所需的累積修補，已包含 first-presented.patch，不要重複套用。每個畫面各自持有場景、相機尺寸與 Metal 回呼；遠端圖層保留系統傳入的 bounds，冷啟動及首幀等待延長至 30 秒。

## 0.14 納入的生命週期修正

累積 framing.patch 納入 0.13.7 的影格生命週期修正：非同步 Metal 工作保留必要物件、合併待呈現影格，並在停止後拒絕新影格。對應 AddressSanitizer 測試位於 `Tools/VerifyLockFrameLifetime.mm`，由 `script/test_lock_frame_lifetime.py` 執行。這不代表所有機型的真實鎖定／解鎖畫面已驗收。
