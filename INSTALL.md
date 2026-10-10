# 安裝 SceneHarbor

1. 確認「關於這台 Mac」顯示 Apple M 系列晶片與 macOS 26 以上。
2. 從 [官方 Releases](https://github.com/yuchn-w/SceneHarbor/releases) 下載 DMG。ZIP 是替代格式；source/runtime 是開發者檔案。
3. 開啟 DMG，將 SceneHarbor.app 拖到 Applications；退出 DMG 後，從「應用程式」開啟。
4. 這個預覽版沒有 Apple 公證。若 macOS 擋下首次開啟，先核對來源，再到「系統設定 → 隱私權與安全性」選擇「強制打開」。請參閱 [Apple 官方步驟](https://support.apple.com/zh-tw/102445)。若系統明確指出惡意軟體或檔案遭竄改，請停止安裝並回報。
5. 匯入自己的影片，或使用免登入工坊瀏覽。Steam 登入只在需要下載或個人作品庫時使用。

無需執行終端機指令、停用 Gatekeeper 或安裝第三方解鎖工具。若你的 Mac 受學校或公司管理，請遵循管理政策。

## 更新

從 App 選單「檢查更新…」或「設定 → 一般 → 軟體更新」操作。預設每天檢查並通知，不會未經選擇就自動安裝。選用自動下載後，更新可在結束 App 時安裝。

0.13.x 尚未內建更新器，需要手動安裝一次 0.14.0。公開版可延續公開版的設定與媒體；私人開發版是不同 bundle ID，需先備份並遷移偏好，不能直接假設所有授權與帳號自動沿用。

更新 App 不會重新下載桌布。開發者仍需編譯每個版本一次；使用者不需要編譯。

## 實驗性鎖定桌布

在「設定 → 桌布與鎖定」啟用。首次使用或從私人版遷移時，需授權公開版延伸功能自己的 Documents 資料夾。若選取視窗沒有開到正確位置，按 Command–Shift–G，貼上 `~/Library/Containers/org.sceneharbor.SceneHarbor.WallpaperExtension/Data/Documents`，再選擇「授權」。請勿改選整個個人 Documents。

若顯示系統未能自動連接，按「系統設定…」，在背景圖片中選取 SceneHarbor，再回 App 按「重試連接」。此功能仍屬實驗性，系統版本、舊版提供者及多螢幕可能影響連線；桌面播放不需要這項授權。

## 檔案校驗

Release 附有 SHA256SUMS.txt，可用於檢查下載是否完整。SHA-256 不是 Apple 公證，也不代表程式沒有漏洞。

## English

Download the DMG from the official Releases page, drag SceneHarbor into Applications, eject the disk image, then launch the installed app. Apple Silicon and macOS 26+ are required.

The preview is not notarized. If macOS blocks the first launch, verify the source and follow [Apple's Open Anyway instructions](https://support.apple.com/102445). Do not disable system-wide security. Future updates are available in the app; installing 0.14.0 once is necessary for users on older releases.
