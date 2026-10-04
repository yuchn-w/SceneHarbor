# 0.13.5 公開預覽版檢查

檢查日期：2026-10-04。

| 檢查 | 結果 |
| --- | --- |
| 公開 Swift Release 編譯、arm64、最低 macOS 26 | PASS |
| 主 App、鎖定延伸功能、螢幕保護程式的 deep strict 簽章完整性 | PASS；匿名 ad-hoc 簽章 |
| 可攜式 Mach-O 相依函式庫 | PASS |
| Steam helper 離線 hello/ping，不登入帳號 | PASS；一般 macOS 程序環境 |
| 鎖定／閒置播放判斷與不同顯示器模式 | PASS |
| 系統桌布連動、條件式回復與保留使用者後續選擇 | PASS |
| 隱私掃描的 UTF-8、UTF-16、跳脫字串跨區段回歸 | PASS |
| 原始碼與新 App ZIP 隱私掃描 | PASS；未發現私人比對值或未審核項目 |
| App ZIP 完整性及額外 macOS 資源分支排除 | PASS |
| Apple Developer ID 簽署與公證 | NOT RUN |
| 全新 Mac 上的公開版首次授權、Steam 登入、長時間／跨機型播放 | NOT RUN |

runtime 與上一公開版位元組一致，已重新核對 SHA-256，沿用該附件先前 51,165 個檢查項目及零私人比對值的結果；本次未重複完整掃描未變更的第三方原始碼。附件亦重新檢查 archive 路徑與 owner metadata，並附於本次發行，由 public-runtime.json 固定 SHA-256。第三方公開測試金鑰、假資料與 CI 範例僅依 upstream-privacy-fixtures.json 的確切檔案雜湊審核，不豁免任何私人比對值。

相同功能的本機版本已驗證七個設定分類，使用者亦確認鎖定畫面可顯示目前桌布並播放。公開版使用獨立識別名稱，因此不將本機驗證擴張為公開版首次安裝或所有機型的保證。
