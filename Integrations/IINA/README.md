# SceneHarbor IINA Auto HDR

目前外掛版本 1.0.1：修正 IINA 退出時讀取已釋放 mpv handle 的崩潰。end-file 僅傳送不含播放器讀取的 inactive 事件；shutdown 停止心跳／重試、丟棄待送資料，不再讀取 mpv 或啟動網路工作。退出後由 SceneHarbor 原有的程序偵測／心跳期限清除需求。使用開發連結者下次啟動 IINA 即載入修正；套件安裝者請重新安裝新版套件。

## 安裝

1. 先啟動包含此整合的 SceneHarbor，選擇 HDR `AUTO`。保留原本 DynamicWallpaper 互斥接管機制。
2. 在 IINA「設定 → 外掛」啟用外掛系統，安裝本專案產生的 `SceneHarborHDR.iinaplgz`。
3. IINA 會顯示 `network-request` 和 `file-system` 權限：外掛只讀取 SceneHarbor 的配對設定，不讀取影片內容；網路僅允許 `127.0.0.1`。
4. 開啟本機媒體。SceneHarbor 原 HDR 狀態列可顯示 `IINA · HDR10`、`IINA · HLG`、`本機圖片 · HDR Gain Map`；HDR 選單顯示整合已連線。暫停仍保持 HDR。

打包（產生 IINA 官方 ZIP 格式；避開本機 1.4.4 CLI 對空白路徑的 URL／shell 問題）：

```sh
./script/package_iina_hdr.sh
```

開發連結（IINA 的官方方式；完成後重開 IINA）：

```sh
python3 - <<'PY'
from pathlib import Path
import subprocess
plugin = Path('Integrations/IINA/SceneHarborHDR').resolve().as_uri()
subprocess.run(['/Applications/IINA.app/Contents/MacOS/iina-plugin', 'link', plugin], check=True)
PY
```

以上在 SceneHarbor 子目錄執行。IINA 1.4.4 CLI 以 URL 解析路徑，請保留 `as_uri()`，避免空白與中文路徑失敗。

更新：重新打包後於 IINA 移除舊外掛並安裝新版；或更新開發目錄後重開 IINA。移除：IINA 外掛設定中移除；開發連結也可將上述程式的 `link` 改為 `unlink` 執行，再重開 IINA。不影響 SceneHarbor 的 YouTube 偵測。

本機驗證：已在使用者授權下用上述官方開發連結安裝、於 IINA 啟用並確認實際連線。IINA 1.4.4 原生套件選取器曾讓「打開」保持停用，因此此機採已驗證的開發連結；`.iinaplgz` 已完成格式／解壓完整性驗證，尚未通過該選取器安裝。開發連結依賴此專案目錄，搬移專案後需重新建立。

## 通訊與診斷

固定 `127.0.0.1:48743`，`POST /auto-hdr/iina`。SceneHarbor 啟動後建立 `~/Library/Application Support/SceneHarbor/AutoHDR/iina.json`（0600；資料夾0700），其中含隨機 shared token。不要分享該檔案。外掛每次傳送前讀取設定，SceneHarbor 沒開或傳送失敗不會干預播放。

IINA 1.4.4 的 `http.post(..., { data })` 使用 form encoding，因此以 `payload=<JSON>` 傳送；接收端也支援 JSON。來源逐播放視窗獨立 session、遞增 sequence、每2秒心跳。接收端8秒未收到該視窗心跳就清除需求，並以 IINA process 不存在加速清除。這也處理關閉單一視窗或移除外掛但 IINA 仍執行的情況。OFF 延遲1.5秒；YouTube 保留原5秒緩衝，之後交給中央仲裁。

首次 file-loaded 延後100ms讀取；metadata不全時以150/350/700ms再試3次；video-reconfig和心跳也更新。未知metadata最多保留舊需求3秒，仍未識別會清除舊需求並顯示判定中，不將未知標成SDR。

「複製 Auto HDR 診斷」包含連線、來源、ownership 與切換事件，不包含 token 或本機檔案路徑。統一日誌 category 為 `AutoHDR`。

## 判定與限制

影片：PQ → HDR10；HLG → HLG；有 `track-list` Dolby Vision profile → Dolby Vision。BT.2020／sig-peak 本身不代表 HDR。mpv沒有提供可確認HDR10+的獨立屬性時，以PQ/HDR10需求處理，不猜測subtype。IINA仍負責解碼與tone mapping。

圖片：以ImageIO讀取實際檔案；Apple/ISO gain map、Core Image expanded HDR contentHeadroom、PQ/HLG色彩空間判定。副檔名與檔名不參與HDR判斷。只處理本機一般檔案，單張上限256MiB。headroom與ISO gain map需要macOS15+；macOS14以Apple gain map和色彩空間降級。IINA/mpv不支援或無法開啟的圖片格式不會產生有效播放來源；這個外掛不增加IINA解碼器。

控制：AUTO 僅回復自己從OFF切ON的HDR；原本ON不取得ownership。ON/OFF手動選擇優先；多來源取OR。正常結束SceneHarbor會等待自有HDR還原；異常終止時程序無法繼續控制硬體，下次啟動用記錄及同一螢幕實際狀態復原。無額外常駐daemon。使用者在系統設定做出與現有HDR狀態相同的操作無法被私有API區分；如要明確接管請用SceneHarbor ON或暫停HDR控制。

## API 依據

- [IINA 1.4.4 原始碼](https://github.com/iina/iina/tree/v1.4.4/iina)：JavascriptAPIHttp.swift、JavascriptAPIMpv.swift、JavascriptAPIEvent.swift、JavascriptAPIFile.swift。
- [IINA events](https://docs.iina.io/interfaces/IINA.API.Event)、[HTTP API](https://docs.iina.io/interfaces/IINA.API.HTTP.html)、[外掛開發指南](https://docs.iina.io/pages/dev-guide.html)。
- [mpv 0.40 properties](https://github.com/mpv-player/mpv/blob/v0.40.0/DOCS/man/input.rst)：video-params/gamma、track-list/image、dolby-vision-profile。
- 本機 macOS26.5 SDK：CIImage.h、CGImageProperties.h、CGColorSpace.h。MonitorPanel維持既有實作，仍屬macOS私有API。
