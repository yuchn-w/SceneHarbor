# SceneHarbor

原生 macOS 動態桌布播放器，支援本機影片、Steam 工坊桌布、Scene／Web 場景、多螢幕及播放清單。

## 功能

- 七大設定分類以大型按鈕呈現；主視窗在切換 App 時保持開啟。
- 動態桌布延伸至鎖定畫面，提供一次性資料夾授權與真實連線狀態。

- 本機匯入與工坊下載共用桌布預覽，支援搜尋及來源篩選。
- 影片與 Scene 桌布可調整播放速度；選單列提供速度、翻轉、聲音及套用快捷操作。
- 一般、隨機、定時與日夜播放清單，可依名稱及標籤協助分類。
- 個別顯示器控制，並有電池、休眠及其他媒體播放時的暫停規則。
- macOS 26 使用原生液態玻璃控制列。
- YouTube／IINA 的選用 HDR 整合及本機系統背景聲音整合。

## 下載與狀態

公開版本是 **預覽版**，面向 macOS 26 以上的 Apple Silicon Mac。請參閱 GitHub Releases 的系統需求與已知限制。

發佈檔使用匿名 ad-hoc 簽章，沒有包含開發者的個人憑證，也尚未經 Apple 公證。簽章完整性驗證不代表 Apple 的開發者身分驗證或公證；這不是正式 Developer ID 發行版本。

本機建置、靜態隱私掃描及 helper 協定檢查會記錄於 `RELEASE_CHECKS.md`。尚未執行全新 Mac 的完整播放／登入驗收，請勿將這些檢查視為所有機型或所有桌布的相容性保證。

## 隱私與帳號

- 此儲存庫及發佈包不包含開發者的 API Key、Steam 工作階段、個人桌布、播放清單、偏好或 Keychain 匯出。
- 公開原始碼延續已清理的公開 Git 歷史；本機工作紀錄、截圖、備份和建置快取不在公開範圍內。
- 工坊瀏覽使用 Steam 公開資料；下載需要使用者自行登入。帳密不會預先填入。
- 執行時的 Steam refresh token／Guard 資料由使用者自己的 macOS Keychain 管理，密碼不寫入檔案。
- 桌布與使用者設定保存在該使用者的 Mac；安裝包不會攜帶開發者資料。
- 公開版識別名稱為 `org.sceneharbor.SceneHarbor`，與原本的私人開發版本分開。

## 建置

需要 Apple Silicon Mac、支援 macOS 26 API 的 Swift 6／macOS SDK、Python 3，以及建置 renderer 時所需的相依工具。Steam helper 的來源建置需要 .NET 10 SDK。

```sh
# 取得 Releases 中對應版本的固定 runtime 與第三方原始碼
./script/fetch_public_runtime.sh
# 建置匿名簽章的公開版，不使用個人簽署憑證
SCENE_HARBOR_PUBLIC_BUILD=1 ./build_app.sh
# 打包（不安裝或改動目前執行中的 SceneHarbor）
SCENE_HARBOR_PUBLIC_BUILD=1 ./script/package_release.sh
```

完整 runtime 發佈附件較大，因此不直接放進 Git 歷史；下載腳本依 manifest 驗證 SHA-256。`Vendor/MirageBaseline/local.patch` 及鎖定資訊記錄本地修改；對應第三方原始碼與 notices 一併提供，詳見 [RUNTIME_SOURCES.md](RUNTIME_SOURCES.md)。

## 原始碼與授權

- 原生 Swift 核心：見 [LICENSE.md](LICENSE.md)。
- 第三方來源與授權：見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- Scene／Web renderer 及獨立 Steam helper 的 GPL／LGPL 條款仍適用；公開發佈不移除原作者聲明。
- 桌布、工坊作品與系統背景聲音不隨本專案提供；請自行取得使用權。

此公開副本只清理產品文案中的舊 app 品牌名稱，保留必要的技術整合名稱、來源註記及授權。
