---
blocked-by: [ISSUE-006]
---

# upgrade.sh：逐版升級並等背景遷移歸零

## Done when
- `bash scripts/upgrade.sh` 有選單，含「說明」與「常見問題排查」，涵蓋 `docs/03-upgrade.md` 的升級路徑警告（GitLab 不可跨大版本；中間版本須查 Upgrade Path Tool）（PR-COM-11）。
- 顯示目前版本（`gitlab-rake gitlab:env:info`）（PR-UPG-01）。
- 吃一個資料夾，依版本由小到大排序；已裝版本以下的檔案略過（PR-UPG-02）。
- 開跑前印出將安裝的版本順序並須輸入 `yes`（PR-UPG-03）；開跑前呼叫 `backup_auto.sh`，失敗即中止（PR-UPG-04）。
- 每一版：停 puma 與 sidekiq → `dpkg -i` → `reconfigure` → `start` → `status`（PR-UPG-05）。
- 輪詢 `BatchedMigration.queued.count`，為 0 才進下一版；逾時即停止並指向 sidekiq 日誌（PR-UPG-06）。
- 全部完成後 `restart`，並執行 `gitlab:check SANITIZE=true`（PR-UPG-07）。
- 中斷後重跑，從已裝版本之後接續。
- 版本比較與排序、`.deb` 檔名解析等純函式有 bash 測試（PR-COM-10）。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，詞彙見 `GLOSSARY.md`（中間版本、背景遷移）。來源文件 `docs/03-upgrade.md`。備份由 ISSUE-006 的 `backup_auto.sh` 提供。「該停在哪些中間版本」由人查 Upgrade Path Tool，腳本不猜。

## Blocked by
ISSUE-006

## Notes
- 背景遷移未完成就裝下一版是此流程最大的風險，輪詢邏輯不可省。
- 版本比較要處理 `18.7.6-ce.0` 這類格式，不能用字串排序。
- 無法在 Windows 真跑；不得宣稱已驗證。
