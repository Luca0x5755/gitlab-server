---
blocked-by: [ISSUE-003, ISSUE-004, ISSUE-005, ISSUE-006, ISSUE-007, ISSUE-008, ISSUE-009, ISSUE-010]
---

# 刪除舊文件 docs/01~05 並更新 README

## Done when
- 逐章節對照 `docs/01`~`05`，每個章節（指令、前置條件、注意事項、不含項目、排查表、回切）都在對應腳本找到去處；對照結果列在提交說明或 PR 描述（PR-DOC-01）。
- 五支腳本都已在 Ubuntu VM 或目標伺服器試跑通過（由使用者確認）之後，才刪除 `docs/01-install-and-config.md`、`02-backup-and-restore.md`、`03-upgrade.md`、`04-nginx.md`、`05-network.md`。
- `README.md`：文件表改指向腳本、移除已不存在的 `tutorials/` 段落與結構圖中的 `tutorials/`、腳本表列出五支選單腳本與 `backup_auto.sh`（PR-DOC-02、PR-DOC-03）。
- 全專案搜尋不再有指向已刪除文件的連結。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，決策見 `docs/decision-log.md`（文件整份刪除、事實只放腳本）。本票是收尾，所有腳本票完成後才做。

## Blocked by
ISSUE-003 到 ISSUE-010

## Notes
- **前置條件**：規格的開放問題「是否有 Ubuntu 24.04 VM」尚未回答。沒有試跑環境就不得刪文件；此時停下並回報，由使用者決定是在目標伺服器手動試跑，或延後本票。
- 刪除前先確認 `docs/04-nginx.md` 的排查表與 `docs/01` 第五部分的 LDAP 排查表已進腳本；這兩份篇幅最大、最容易遺漏。
- 本專案的本地議題檔隨分支存活，合併前需全部刪除（`.github/workflows/issues-check.yml`）；本票完成時一併確認 `docs/issues/` 已清空。
