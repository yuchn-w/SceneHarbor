# Runtime 來源與重建

公開附件 `SceneHarbor-runtime-0.13.6-public.1.tar.gz` 解壓到專案根目錄後，會補齊被 Git 忽略的大型 runtime 與對應來源。

## MirageWallpaper

- 固定來源與 commit：`runtime-lock.json`。
- 原始碼封存：`Vendor/MirageBaseline/source.tar.gz`。
- Scene／Web 修改：`Vendor/MirageBaseline/local.patch`。
- Screen saver 與多螢幕取景的累積修改：`Vendor/LockScreenRuntime/framing.patch`，已包含 first-presented.patch。

例如，在獨立工作目錄準備 Scene／Web 來源：

```sh
mkdir -p work/runtime-source
tar -xzf Vendor/MirageBaseline/source.tar.gz -C work/runtime-source
patch -p1 -d work/runtime-source < Vendor/MirageBaseline/local.patch
```

Screen saver 的固定來源與建置資訊另見 `Vendor/LockScreenRuntime/runtime.json` 與其 README。套用 patch 前應先確認工作目錄內容，避免重複套用。保留來源中的 CMake、Swift Package 與第三方建置設定；不需要開發者的 Steam Key 即可建置。

## 公開包的處理

公開 runtime 另外清除原始碼範例中的金鑰與個人路徑，並以 `script/sanitize_runtime.py` 清除 renderer 的 C 字串建置路徑。此步驟不變動字串長度或程式碼位移。處理後使用匿名 ad-hoc 簽章；manifest 的 SHA-256 對應公開版檔案。

App 組裝時會把動態函式庫的載入路徑改為 bundle 內的 `@rpath`，然後重新簽章。PortableRuntime 中保存套件配方、安裝收據、授權及來源資訊。

第三方來源中的著作權與合法署名保留。請勿將本專案的 MIT 授權誤套用到 GPL／LGPL runtime；各元件條款列於 `THIRD_PARTY_NOTICES.md`。
