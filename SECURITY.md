# 安全與隱私

SceneHarbor 是免費開源的公開預覽版，尚未經 Apple Developer ID 簽署或公證。套件使用 ad-hoc 簽章檢查內容完整性，無法提供 Apple 認證的開發者身分。開源與校驗值也不能保證軟體沒有漏洞。

## 網路與帳號

- 公開 Steam 工坊搜尋不需要登入、Cookie 或 API Key。Steam 改版或地區連線限制可能影響結果。
- 下載需要相應的 Steam 登入及作品存取權；公開搜尋不等於取得付費內容授權。
- 軟體更新從 GitHub 取得，使用 Sparkle 驗證簽章後才解壓縮安裝。關閉系統使用統計傳送。
- 不要在 Issues 貼 Steam 密碼、驗證碼、登入權杖、完整偏好設定或未清理的系統日誌。分享截圖前請遮住帳號與私人素材。

## 執行與權限

桌布可能包含網頁或複雜場景，第三方內容具有自己的網路與資源需求。只使用信任的來源，發現異常時停止該桌布。

目前公開版為載入隨附 Sparkle 使用 `disable-library-validation` entitlement。它放寬程序的動態函式庫身分檢查，是尚未使用 Developer ID 的發行限制；不表示關閉 Gatekeeper，也不代表 App 已有完整沙盒隔離。

資源保護包含有限額的預覽快取、省資源模式及嚴重記憶體壓力時停止播放。這些防護無法保證每個第三方作品在所有 Mac 上具有固定 CPU、GPU 或 RAM 用量。請參考 [RELEASE_CHECKS.md](RELEASE_CHECKS.md) 區分測試通過與尚未驗收項目。

## 回報

一般問題請使用 [GitHub Issues](https://github.com/yuchn-w/SceneHarbor/issues)，提供版本、macOS 版本、晶片、重現步驟與經清理的錯誤資訊。若涉及未公開漏洞或憑證，請先使用 GitHub 的私密漏洞回報功能（若倉庫提供）；若未提供，僅開立不含敏感細節的聯絡請求，等待私下回報管道。
