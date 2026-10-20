# Issue tracker：本地 markdown

議題以 markdown 檔存放在 repo 內，不使用 GitHub Issues。

- **檔名**：`docs/issues/ISSUE-NNN-<slug>.md`，`NNN` 三位數
- **下一個編號**：`docs/issues/` 現有最大 `NNN` + 1；目錄無議題時從 `001` 起
- **建立議題**：新增上述檔案，本文寫在檔內
- **列出未結議題**：`ls docs/issues/`（檔案存在即未結；`.gitkeep` 不算）
- **阻擋關係**：議題檔開頭 frontmatter 寫 `blocked-by: [ISSUE-NNN, ...]`
- **本文位置**：就是該議題檔本身
- **生命週期**：完成後刪除該檔（`/implement` 負責）。議題只活在一條分支上；`.github/workflows/issues-check.yml` 會讓「淨新增 `docs/issues/` 檔案」的 PR 失敗，確保合併前清空。需跨分支存活的工作請改用真正的 tracker。
