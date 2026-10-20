---
blocked-by: [ISSUE-006]
---

# backup.sh：還原端

## Done when
- `backup.sh` 選單新增「還原」。還原前檢查已裝版本與備份檔名中的版本一致，不符即中止（PR-BAK-05）。
- 還原前須輸入 `yes`（PR-BAK-07）。
- 依序執行：還原設定備份並 `reconfigure` → 備份檔放入 `/var/opt/gitlab/backups/` 並 `chown git:git` → 停 puma 與 sidekiq → `gitlab-backup restore BACKUP=<備份 ID>` → `reconfigure` 與 `start`；備份 ID 由檔名自動取出，不含路徑與 `_gitlab_backup.tar` 後綴（PR-BAK-06）。
- 還原後依序執行 `gitlab:check SANITIZE=true`、`gitlab:doctor:secrets`、`gitlab:artifacts:check`、`gitlab:lfs:check`、`gitlab:uploads:check`，彙總成功與失敗（PR-BAK-08）。
- 「說明」補上還原前置條件（版本與 CE/EE 一致、目標已 `reconfigure` 過、目標無正式資料）與驗證項目（Web 登入、clone、CI/CD 變數與 Runner）。
- 備份 ID 擷取、版本比對等純函式有 bash 測試（PR-COM-10）。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，詞彙見 `GLOSSARY.md`（備份 ID、資料備份、設定備份）。來源文件為 `docs/02-backup-and-restore.md` 後半（還原流程）。備份端與 `backup.sh` 骨架由 ISSUE-006 建立。

## Blocked by
ISSUE-006

## Notes
- 還原會覆蓋既有資料，這是本專案最危險的動作之一；確認提示要寫清楚將覆蓋什麼。
- 備份 ID 擷取是常見出錯點（文件特別強調），務必有測試涵蓋「含路徑」「含後綴」「含版本號」輸入。
- 無法在 Windows 真跑；不得宣稱已驗證。
