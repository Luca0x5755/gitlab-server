---
blocked-by: [ISSUE-003]
---

# backup_auto.sh 與 backup.sh 的備份端

## Done when
- `scripts/gitlab_backup.sh` 改名並改寫為 `scripts/backup_auto.sh`：先資料備份（失敗即非 0 結束），再 `gitlab-ctl backup-etc`；cron、升級前、選單共用這一份（PR-BAK-01、PR-BAK-02、PR-DOC-03）。
- 資料備份保留 7 天，由管理區塊 `backup_keep_time = 604800` 設定；`backup_auto.sh` 清理超過 7 天的設定備份（PR-BAK-03、PR-BAK-12）。
- `bash scripts/backup.sh` 有選單：立即備份、列出現有資料備份與設定備份（PR-BAK-04）、註冊／移除 crontab（重複註冊不產生重複項目）（PR-BAK-10）、複製設定備份到指定目錄並記入參數檔（PR-BAK-11）。
- 「說明」列出備份不含的項目：Object Storage、Mattermost、Redis、server hooks，並強調設定備份須與資料備份放不同位置（PR-BAK-09）；含「常見問題排查」（PR-COM-11）。
- crontab 重複偵測等純函式有 bash 測試（PR-COM-10）。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，詞彙見 `GLOSSARY.md`（資料備份、設定備份）。原腳本只 `tar` 三個檔案會漏掉 `trusted-certs`，故改用 `gitlab-ctl backup-etc`，理由見 `docs/decision-log.md`。來源文件為 `docs/02-backup-and-restore.md` 前半（建立與清理）。參考專案 `D:\automated_trading\scripts\backup.sh` 與 `backup_auto.sh` 的分工即是目標形狀。

## Blocked by
ISSUE-003

## Notes
- `backup_auto.sh` 要能被 cron 非互動呼叫；互動只在 `backup.sh`。
- 還原端屬 ISSUE-007，本票不做。
- 設定備份只有 root 可讀，複製離機時保留權限。
