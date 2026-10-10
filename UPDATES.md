# App 內更新

0.14 起的公開版使用 Sparkle 2.10.0。第一次安裝仍需下載 DMG；之後可從 SceneHarbor 選單或設定的「軟體更新」檢查新版本。0.13 系列沒有這個更新器，需手動安裝一次。

- 預設每日檢查更新並通知；自動下載與安裝預設關閉。
- 可選擇「自動下載，並在結束 App 時安裝」。需要重新啟動才能使用新版。
- 更新資訊及安裝包均須通過 Ed25519 簽章驗證，安裝包在解壓縮前驗證。私鑰不隨原始碼或 App 發送。
- 更新替換 App；桌布媒體與偏好設定保留在原位置。磁碟仍須留有下載及暫存替換空間。
- 不上傳 Sparkle 系統使用統計。連線 GitHub 仍會讓服務端得知 IP 等一般連線資訊。
- 此機制不是 Apple 公證；初次安裝請見 [INSTALL.md](INSTALL.md)。
- 未使用 Developer ID 的版本更新後，macOS 可能重新判定部分權限或鑰匙圈存取，Steam 工作階段可能需要重新登入。App 不會透過放寬鑰匙圈保護來略過這些限制。

## 維護者發布流程

一般使用者不用編譯。維護者每次發布程式變更仍須編譯一次，再讓使用者透過更新器接收成品。

1. 增加 `CFBundleVersion`，同步版本及發布紀錄，完成回歸、隱私與封裝檢查。
2. `SCENE_HARBOR_PUBLIC_BUILD=1 ./build_app.sh` 建置公開 App。
3. `./script/package_release.sh --built` 封裝同一份已測試的 App，產出 ZIP、DMG 及校驗值。
4. 使用專用鑰匙圈帳號 `org.sceneharbor.updates` 執行 `./script/generate_update_feed.sh vVERSION-public.N`。macOS 可能要求維護者允許簽章工具存取金鑰。不要匯出金鑰到 Git、日誌或發布附件。
5. 先發布 GitHub Release 安裝檔與對應來源，匿名下載並核對校驗值。
6. 最後提交已簽章的 `appcast.xml` 至 `main`，讓已安裝的 App 能找到可下載的更新。不得發布指向尚未存在附件的 feed。

更新位址固定為本專案 GitHub `main/appcast.xml`，接受 `preview` 通道。GitHub 本身不會直接向 App 推播；App 定期檢查，或使用者按「檢查更新」。

本機私用識別名稱與公開版不同，第一次遷移必須保留還原點並核對設定，不能直接把兩者視為相同的更新目標。今後維持公開版識別名稱及更新公鑰，避免反覆遷移。
