# SceneHarbor 公開發布流程

這份流程用來檢查交付給 GitHub 的新鮮公開副本。公開副本應從 allowlist 內的專案檔案建立，保留產品所需的第三方著作權、授權條款與來源說明；不要把個人資料、帳號狀態、建置快取或舊版發行資料帶入副本。

## 發布前檢查

1. **freshcopy**：從乾淨來源產生新的 staging 目錄，只複製核准的 `Sources/`、資源、`Package.swift`、必要腳本與授權文件。刪除建置輸出、快取、下載內容、使用者設定與本機媒體索引。不要用目前工作目錄直接當成公開副本。
2. **nohistory**：公開副本不應包含舊的 `.git` 歷史、未預期的本機 branch metadata 或暫存檔。若要建立 Git repository，先在新副本中建立乾淨的初始狀態，再檢查 `git status` 與 `git ls-files`。
3. **cleancommitidentity**：提交前使用核准的公開提交者名稱與信箱。檢查 `git log --format='%an <%ae>'`、`.mailmap` 與 repository 設定，確認沒有本機作者資料；第三方作者名稱與授權文件中的聯絡資訊應依授權要求保留。
4. **privacy scan**：真實的本機使用者名稱、顯示器／裝置識別碼、簽章指紋與服務金鑰只放在公開樹外的私有 JSON，供掃描器比對；不要把這些值寫入掃描器、範例檔或文件。

私有 pattern 檔案可採用下列欄位名稱，值只存在本機：

```json
{
  "username": "<local-value>",
  "codesign_fingerprint": "<local-value>",
  "actualSteamKey": "<local-value>"
}
```

## 掃描指令

在新副本的根目錄執行。`PRIVATE_PATTERNS` 必須指向公開樹外、未加入 Git 的私有檔案：

```sh
PRIVATE_PATTERNS=/private/tmp/sceneharbor-release-tools/private-patterns.json

# 以 Git 可見檔案清單檢查來源；此模式會略過常見的建置目錄。
python3 script/verify_public_privacy.py \
  --private-patterns "$PRIVATE_PATTERNS"

# 檢查打包的 app 或整個新鮮 export；明確指定的路徑會完整掃描。
python3 script/verify_public_privacy.py \
  --private-patterns "$PRIVATE_PATTERNS" \
  --archives /path/to/SceneHarbor.app
```

若要檢查整個公開 export，可將最後一個參數換成 export 根目錄。`--archives` 會以有限的檔案大小、成員數與巢狀深度檢查 zip/tar 內容，也會檢查 plist 內的 API key/token 欄位；一般 token 格式、Mach-O bytes、使用者家目錄路徑與私有檔名也會檢查。GPL、Mirage 與其他第三方授權中的作者名稱不會被當成本機個資。

輸出只包含 `filename/category/count`，不會列出命中的值。退出碼為 `0` 才表示掃描通過；命中、掃描限制、設定錯誤或來源沒有 Git 可見清單時會回傳非零值，這些狀況都要先處理再發布。

## 上游公開測試資料

對應來源保留 OpenSSL 測試私鑰、PKCS#12 fixture、yt-dlp 的虛構網域 cookie 測試，以及上游已發布的服務常數與 CI 路徑。`upstream-privacy-fixtures.json` 以精確檔案 SHA-256 記錄經檢視的項目；修改過的檔案不適用，開發者個人值的比對永遠不會被豁免。

```sh
python3 script/verify_public_privacy.py \
  --private-patterns "$PRIVATE_PATTERNS" \
  --upstream-fixtures upstream-privacy-fixtures.json \
  --archives --max-archive-bytes 1073741824 --max-archive-members 100000 \
  Vendor
```

發布包還必須執行 `script/verify_portable_closure.py`；它會拒絕遺失的 runtime 函式庫與失效 symlink。GPU、.NET helper 的實際啟動檢查需使用能存取正常系統服務的測試環境。沙箱內失敗不能直接當成 App 失效，系統重測通過也不等於完成新 Mac 的端到端驗收。
