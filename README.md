# SceneHarbor

**讓 Mac 桌布跟著你的螢幕、時段與播放清單切換。**

免費開源的 macOS 動態桌布 App，支援影片、Wallpaper Engine 格式的 Scene／Web 桌布、多螢幕獨立播放與週間排程。Steam 公開工坊可以先瀏覽、搜尋，再決定是否登入下載。

**[下載 SceneHarbor 0.14.0 安裝包](https://github.com/yuchn-w/SceneHarbor/releases/tag/v0.14.0-public.1)** · [安裝說明](INSTALL.md) · [問題回報](https://github.com/yuchn-w/SceneHarbor/issues) · [English](#english)

> 公開預覽版：需要 **Apple Silicon（M 系列）與 macOS 26 以上**。尚未經 Apple 公證；首次開啟可能需要在系統設定確認。Intel Mac 與較舊 macOS 目前不支援。

## 三步開始

1. 下載 `SceneHarbor-0.14.0-macOS-arm64.dmg`，將 App 拖到「Applications」。一般使用者不需要下載 source 或 runtime。
2. 從「應用程式」開啟 SceneHarbor。若被 macOS 擋下，依 [首次開啟說明](INSTALL.md) 確認來源後操作。
3. 匯入自己的 MP4／MOV，或按「免登入瀏覽工坊」。下載工坊內容才需要登入 Steam，以及該內容所要求的使用權。

## 可以做什麼

- **每個螢幕各播各的**：獨立選桌布、音量、清單與輪播進度。
- **依時間自動換桌布**：日夜、週間時段、日出日落與智慧清單，支援捷徑。
- **先看再登入**：公開工坊搜尋與封面不需要 Steam 帳號或共享 API Key；完整場景動態預覽可能仍需先下載素材。
- **自己決定效能與畫質**：極省資源 15 FPS／50%、省電 24 FPS／75%、平衡 30 FPS、高畫質 60 FPS。Scene 桌布的實際負載也取決於作者素材與螢幕數量。
- **減少背景負擔**：電池、全螢幕、睡眠與溫度策略；嚴重記憶體壓力時停止桌布，等待手動恢復。
- **App 內更新**：手動檢查、每日自動檢查，或選擇自動下載並在結束時安裝。更新資訊與套件使用 Ed25519 簽章。
- **實驗性鎖定畫面整合**：保留目前桌布與設定；依 macOS 授權與作品相容性而異。

## 安全與隱私

App 不內建使用者帳密，不回傳使用統計、桌布或播放清單。瀏覽與下載會連線 Steam；啟用更新檢查會連線 GitHub，其服務可見一般連線資訊（例如 IP）。Steam 密碼不寫入檔案；選用的工作階段保存使用 macOS 鑰匙圈。Web 桌布的外部網路預設封鎖。

更新簽章用來確認更新來自同一發行者且未被竄改，**不代表 Apple 公證、惡意軟體完整審查或零漏洞保證**。請從本儲存庫的 Releases 下載，勿使用來路不明的重包版本。檢查範圍與尚未完成項目見 [RELEASE_CHECKS.md](RELEASE_CHECKS.md)、[安全說明](SECURITY.md)。

代表性量測與限制見 [效能觀察](docs/PERFORMANCE.md)。

## 已知限制

- 未公證，因此首次安裝需要額外確認；不要求關閉 Gatekeeper 或執行解除安全防護的指令。
- 第三方 Scene／Web 作品不保證完全相容；高解析材質、粒子與多螢幕可能增加 RAM／GPU 用量。
- Steam 公開頁格式可能改變，服務或所在地網路限制可能影響瀏覽；不承諾永久可用的第三方鏡像。
- 目前仍是預覽版。請參考版本檢查紀錄，勿把某部 Mac 的測試當成所有機型保證。

## 建置與貢獻

需要 Apple Silicon、macOS 26 SDK／Swift 6、Python 3；重建 Steam helper 另需 .NET 10。

```sh
./script/fetch_public_runtime.sh
SCENE_HARBOR_PUBLIC_BUILD=1 ./build_app.sh
# 封裝同一份已測試 App，不再編譯或安裝
./script/package_release.sh --built
```

更新發佈流程見 [UPDATES.md](UPDATES.md)。第三方固定 runtime 與對應來源放在 Release 附件，下載時核對 SHA-256；SwiftPM 固定 Sparkle 版本並驗證二進位 checksum。

回報問題時請提供 App/macOS 版本、晶片、螢幕數量、桌布類型、重現步驟及是否持續增加資源用量。不要貼 Steam 密碼、token、個人路徑或完整設定檔。

## 授權與來源

各元件的授權以 [LICENSE.md](LICENSE.md)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 與 [RUNTIME_SOURCES.md](RUNTIME_SOURCES.md) 為準。保留第三方著作權、修改 patch 與相應來源。桌布作品、Steam 與 Wallpaper Engine 的名稱及素材權利屬其權利人；本專案不是 Valve 或 Wallpaper Engine 的官方產品。

## English

SceneHarbor is a free, open-source live wallpaper app for **Apple Silicon Macs running macOS 26 or newer**. Play local videos and compatible Scene/Web wallpapers, control each display independently, and schedule playlists by time or day.

**[Download the preview](https://github.com/yuchn-w/SceneHarbor/releases/tag/v0.14.0-public.1)**. Open the DMG and drag SceneHarbor to Applications. This preview is **not Apple-notarized**; see [installation instructions](INSTALL.md) before first launch. No developer tools are needed to use the packaged app.

Browse the public Steam Workshop without signing in or supplying an API key. Downloads and personal subscriptions require your own Steam account and the necessary content rights. Updates are verified with signed feeds and Ed25519 archive signatures. Telemetry is not collected by the app; Steam and GitHub still receive ordinary network requests.

Compatibility and performance depend on the wallpaper, display setup and system version. See [release checks](RELEASE_CHECKS.md) for what was actually tested. Contributions and reproducible bug reports are welcome.
