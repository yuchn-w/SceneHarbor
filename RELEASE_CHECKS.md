# 0.12.8 public.1 發布檢核

驗證範圍：獨立的匿名簽章公開副本；原本安裝的 SceneHarbor 與私人資料沒有變更。

| 項目 | 結果 | 證據與限制 |
| --- | --- | --- |
| 原始專案、Git 歷史、App、偏好與資料的私有備份 | PASS | 本機保存可還原 checkpoint；不列入公開附件 |
| 個人 API／Steam Key、私有信箱、裝置識別碼、使用者名稱及簽章指紋比對 | PASS | 原始碼、App、runtime／對應來源均掃描；比對值保存在公開樹外 |
| 產品中的舊 app 名稱 | PASS | 清理使用者可見文案；保留外部整合名稱、ABI 與授權署名 |
| 公開 App 建置 | PASS | Swift release；Apple Silicon；macOS 26 以上 |
| 匿名簽章完整性 | PASS | `codesign --verify --deep --strict`；不使用個人憑證 |
| 動態函式庫 | PASS | helper、saver、extension 本地依賴完整；無依賴本機 Homebrew 的載入路徑 |
| Steam helper | PASS | 系統環境 hello／ping；未登入、未讀帳密、未下載作品 |
| Vulkan／MoltenVK | PASS | hardened ad-hoc 煙測載入 bundle provider，成功建立 instance 並列出 1 個 GPU；未開視窗或更換桌布 |
| Scene／Web IPC | PASS | fake renderer fixture：啟動、預覽、翻轉、暫停／恢復與舊子程序回呼隔離 |
| App 隱私掃描 | PASS | 8,983 個檔案，沒有命中 |
| Runtime／第三方來源掃描 | PASS | 51,165 個檔案；公開上游測試資料依精確檔案雜湊審核，個人值仍全面檢查 |
| Runtime 附件解壓與內容比對 | PASS | 4,637 個項目逐一比對；含 SHA-256 與 symlink，下載腳本已用本機附件測試 |
| Apple Developer ID／公證 | NOT RUN | 僅 ad-hoc 簽章，並非 Apple 公證發行版 |
| 全新 Mac、實際 Steam 登入與下載、全部桌布效果 | NOT RUN | 本次沒有改動目前播放內容或私人 Steam 工作階段 |
| 公開版畫面與全部互動回歸 | NOT RUN | 本次未啟動主 App；建置／協定測試不能代替畫面驗收 |

## 驗證過程修正

公開組裝原本遺漏 brotli 的 `@rpath` 傳遞依賴，已補齊並增加完整性檢查。測試程序曾因缺少 runtime 載入路徑、GPU 沙箱限制及 .NET 沙箱限制失敗；使用與成品相同的載入路徑，並於系統環境重測後通過。沒有為此放寬 App 的安全 entitlement。

## 上游資料例外

上游來源中的測試憑證與假 cookie、公開服務常數不屬於開發者的帳號資料。保留其來源、授權與精確雜湊，避免破壞相應原始碼；真正的個人值永遠不適用例外。

公開前的第二輪審查另外移除了 HDR 控制器的開發機顯示器 UUID。新版改為從本機即時解析唯一的外接 HDR 顯示器；多個候選時不任意切換，並把實際裝置 UUID 納入公開樹外的私有比對清單。

另已移除固定的本機媒體 UUID／名稱對照表，保留一般關鍵字命名功能。裝置 UUID 指派新增通用掃描規則，私有媒體 UUID 也納入公開樹外比對清單。
