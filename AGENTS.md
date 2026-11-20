# Bass Harmony Workbench 維護說明

- 程式在 `source/`。若有本機內部文件，先讀 `docs/documents/` 下的 SOURCE_GUIDE.md、PROJECT_CONTEXT.md 與 CHATGPT_SOURCE_REVIEW.txt。
- 本機 DSP、Human-in-the-loop、MuseScore 編輯優先。首音／Root 分離，和弦初版為大、小方向。
- `HarmonyEvidence` 是可重算資料；`HumanAnnotation` 是人工資料，鎖定空白也必須保留。
- 不重建或覆寫完整原譜；原音／原譜在 `.basswork/originals/` 保存。
- 不把模板分數當正確機率，不把 CQT 當 F0，不聲稱未實測模型或分軌已可用。
- 修改需求範圍內的功能並執行適當測試。
- 不將 `projects/`、`.app`、快取、虛擬環境或私人歌曲放入公開原始碼。
- 文件歸檔：`docs/` 僅放使用者手冊及 GitHub Pages 所需入口／資產；測試紀錄、驗收報告、規劃文件與其他內部文件一律放在已忽略的 `docs/documents/`，不要放在 `docs/` 根目錄。
- 測試維護：正式測試程式、可重現的 runner、必要依賴清單與小型共用 fixtures 要納入 Git；覆蓋率／測試結果、快取、臨時除錯腳本、本機資料庫與私人媒體不要提交。測試範例不得包含私人歌曲名稱或購買素材資訊。
- 開發版本先輸出到 `source/build/`。任務經使用者驗收後，可將已由驗收版涵蓋的同任務舊試用包移到垃圾桶。依使用者指定保留對照版本，正在執行的版本等關閉後再處理。
- 正式圖示放在 `source/resources/`，網站圖片放在 `docs/assets/`，設計草稿放在 `docs/documents/design/`。
