---
blocked-by: [ISSUE-004, ISSUE-005]
---

# 逐站升級 GitLab 容器到 19.5.1

## Done when
`docker.sh` 的【GitLab 伺服器】選單新增「逐站升級」，依序做到下列各點：
- 開跑前印出將升級的版本順序並須輸入 `yes`；只升比目前容器版本**高**的映像（數值比較），已載入但不高於目前版本者略過並說明（PR-DKR-20）。
- 進入 18.11 之前提示：啟動時會自動升級 PostgreSQL 到 17.7，耗時隨資料庫大小增加；顯示 `/var/opt/gitlab` 所在磁碟的剩餘空間，須 `yes`（PR-DKR-23）。
- **每一站升級前**呼叫容器模式的 `backup_auto.sh` 產生資料備份與設定備份；失敗即中止（PR-DKR-21）。
- 每一站：停止並移除舊容器（**不動掛載目錄**），以新 tag 與**同一組參數**重建容器（沿用 ISSUE-004 的 `docker run` 參數組裝），等健康；失敗即停止並指向 `docker logs gitlab`（PR-DKR-22）。
- 每一站要等**背景遷移**歸零（容器內 `BatchedMigration.queued.count` 為 0）才進下一站；逾時即停止並指向 sidekiq 日誌（PR-DKR-24）。
- 全部完成後執行 `gitlab-rake gitlab:check SANITIZE=true`，並顯示最終版本（PR-DKR-25）。
- 版本順序與篩選、tag 組合、背景遷移輸出解析等純函式有 bash 測試，`bash scripts/test/run.sh` 全過。

## Context
Spec 見 `docs/issues/ISSUE-001-gitlab-docker-migration.md`；決策與停靠站依據見 `docs/adr/0001-gitlab-moves-to-docker-with-in-place-data.md`（18.10.3 → 18.11.13 → 19.2.9 → 19.5.1，來源是 Upgrade Path Tool，即 `gitlab-org/gitlab` 的 `config/upgrade_path.yml`）。詞彙見 `GLOSSARY.md` 的「中間版本」「背景遷移」「GitLab 容器」。流程與既有 `scripts/upgrade.sh`（deb 版逐版升級）同構：逐版、輪詢背景遷移歸零，可參考它的輪詢函式與環境變數覆寫方式（`UPG_POLL_INTERVAL`、`UPG_POLL_MAX`）。

## Blocked by
- ISSUE-004 — `docker run` 參數組裝與容器名、掛載目錄。
- ISSUE-005 — 升級前備份要呼叫容器模式的 `backup_auto.sh`。

## Notes
- 腳本**不猜**停靠站：依映像包裡有哪些版本與數值大小排序，哪些版本該放進去由人查 Upgrade Path Tool（承接 `PR-UPG` 的既有決定）。
- 中斷後重跑：以目前容器版本為準，自然略過已完成的站。
- 18.11 站的 PostgreSQL 自動升級耗時與磁碟需求要靠實測決定警告門檻（spec Open question 3）；沒有實測前，警告只顯示剩餘空間，不要編數字。
- 輪詢 `gitlab-rails runner` 輸出時，前面可能混有警告訊息，只取最後一個純數字行（可重用 `upgrade.sh` 的 `parse_queued_count` 概念）。
- 不要在這張票處理 Runner；Runner 版本警告在 GitLab 穩定後由 `runner.sh` 自己處理。
