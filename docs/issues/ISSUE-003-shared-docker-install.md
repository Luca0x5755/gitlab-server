---
blocked-by: [ISSUE-002]
---

# 抽出共用的 Docker 離線安裝，docker.sh 與 runner.sh 共用

## Done when
- `docker.io` 與相依的**離線打包／安裝**邏輯成為共用函式（放 `scripts/lib/common.sh` 或新的 lib 檔），`runner.sh` 與 `docker.sh` 呼叫同一份，不複製兩份相依解析（PR-DKR-04）。
- `docker.sh` 新增兩個選單項目：【有網路的電腦】打包 Docker 離線包、【GitLab 伺服器】安裝 Docker（含啟用服務）。
- `runner.sh` 的既有行為不變：`bash scripts/test/run.sh` 中 `test_runner.sh`、`test_ci_runner.sh` 抽出前後都全過，抽出後沒有刪掉或放寬任何既有斷言。
- 共用函式的純邏輯部分（例如 `parse_dep_pkgs`）有 bash 測試。

## Context
Spec 見 `docs/issues/ISSUE-001-gitlab-docker-migration.md`。GitLab 容器要靠宿主機的 Docker，而 Docker 的離線安裝目前只在 `scripts/runner.sh`（約 235–275 行：`docker.io` 與相依解析、`gitlab-runner` 與 helper images 打包）。這台斷網，所以 `docker.sh` 必須能用同一套離線流程裝 Docker。決策記在 `docs/decision-log.md`（2026-10-22「Docker 的離線安裝從 `runner.sh` 抽成共用函式」）。

## Blocked by
ISSUE-002 — `docker.sh` 檔案與選單骨架由它建立。

## Notes
- 只抽 Docker 的部分；`gitlab-runner` 套件與 helper images 的打包仍留在 `runner.sh`。
- 這是重構，不是改行為：先確認 `runner.sh` 抽出前的測試是綠的，再動手。
- 機器角色沿用現有命名（`online`／`server`／`ubuntu`），不新增角色。
- 離線包檔名與 `runner.sh` 現有的不要衝突；若共用同一個 tar，請在 `runner.sh` 的說明裡同步註明。
- 試跑要在 WSL Ubuntu-24.04；本機 Windows 只做 `bash -n`、`shellcheck` 與純函式測試。
