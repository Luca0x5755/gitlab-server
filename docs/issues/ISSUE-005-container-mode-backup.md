---
blocked-by: [ISSUE-004]
---

# backup_auto.sh 支援 GitLab 容器模式（docker exec）

## Done when
- 在 GitLab 容器模式下，`backup_auto.sh` 以 `docker exec gitlab gitlab-backup create` 產生資料備份，以 `docker exec gitlab gitlab-ctl backup-etc` 產生設定備份；產物仍落在宿主機的 `/var/opt/gitlab/backups` 與 `/etc/gitlab/config_backup/`（PR-DKR-40）。
- deb 模式的行為**完全不變**，既有 `test_backup.sh` 全過且沒有被放寬（PR-DKR-40）。
- 容器模式下資料備份失敗仍以非 0 結束；資料備份與設定備份同樣保留 7 天（PR-DKR-41，同 PR-BAK-02、03、12）。
- 容器模式下，`backup.sh` 的「立即備份」與「註冊／移除 crontab」可用，重複註冊不產生重複項目（PR-DKR-42，同 PR-BAK-01、10）。
- 模式判斷、`docker exec` 指令組裝等純函式有 bash 測試。

## Context
Spec 見 `docs/issues/ISSUE-001-gitlab-docker-migration.md`。purge 舊 deb 之後，宿主機沒有 `gitlab-backup` 與 `gitlab-ctl`，現有 cron 備份會悄悄失敗，變成沒人備份，所以容器版的日常備份必須在 purge 之前就位。逐站升級前的備份（ISSUE-007）也直接呼叫它。詞彙見 `GLOSSARY.md` 的「資料備份」「設定備份」。

## Blocked by
ISSUE-004 — 容器名稱、掛載目錄與啟動方式由它定下，這裡才有東西可 `docker exec`。

## Notes
- 模式判斷建議以「名為 `gitlab` 的容器存在且執行中」為準；容器不在時照舊走 deb 模式，不要猜。
- `backup_keep_time = 604800` 是寫在 `gitlab.rb` 管理區塊（PR-BAK-03），遷移時 `/etc/gitlab` 原樣保留，所以資料備份保留期限自然延續；設定備份的 7 天清理則由腳本做。
- `backup.sh` 的**還原**項目在容器模式下不處理（spec 的 Out of scope），不要順手改。
- 資料備份檔名格式、`備份 ID` 規則（見 `GLOSSARY.md`）不變。
- 測試用既有的 stub 風格：在 `test_backup.sh` 旁蓋掉 `docker`，不要真的呼叫 docker。
