---
blocked-by: [ISSUE-002]
---

# 沿用現有資料目錄，啟動 18.10.3 的 GitLab 容器

## Done when
`docker.sh` 的【GitLab 伺服器】選單新增「遷移到 Docker」，依序做到下列各點，任一步失敗即中止並說明：
- **前置檢查**（PR-DKR-10）：目前為 deb 安裝且版本等於要啟動的映像 tag、Docker 已安裝、映像已載入。
- **備份與機外確認**（PR-DKR-11）：呼叫現有 `backup_auto.sh` 產生資料備份與設定備份；列出兩個檔案的路徑與大小，要求輸入確認字串表示已複製到機外；備份失敗或未輸入確認字串即中止，且**不動 deb 版**。
- **改 `gitlab.rb`**（PR-DKR-12）：移除 `nginx.sh` 寫入的管理區塊，並在管理區塊設定 `gitlab_rails['gitlab_shell_ssh_port'] = 2222`；改前依 PR-COM-07 備份為 `gitlab.rb.bak-<時間戳>`。
- **停 deb 版**（PR-DKR-13）：`gitlab-ctl stop` 並停用其開機服務；確認 80、443、2222 未被占用才繼續。
- **對齊權限**（PR-DKR-14）：以暫時容器掛載三個**掛載目錄**，執行 `update-permissions`。
- **啟動容器**（PR-DKR-15）：容器名 `gitlab`，掛載 `/etc/gitlab`、`/var/opt/gitlab`、`/var/log/gitlab`（宿主機路徑相同），發佈 80、443 與 2222→22，`--restart always`，`--shm-size 256m`；**宿主機 sshd 設定不被修改**。`docker run` 的參數由純函式組裝。
- **等健康**（PR-DKR-16）：容器健康才算成功；逾時即停止並指向 `docker logs gitlab`。
- **驗證**（PR-DKR-17）：容器內 `gitlab-rake gitlab:check` 與 `curl -kI <external_url>` 都通過。
- 「`docker run` 參數組裝」「管理區塊移除」等純函式有 bash 測試，`bash scripts/test/run.sh` 全過（PR-DKR-31）。

## Context
Spec 見 `docs/issues/ISSUE-001-gitlab-docker-migration.md`；決策見 `docs/adr/0001-gitlab-moves-to-docker-with-in-place-data.md`（為何同機沿用目錄、不留退路）與 `docs/adr/0002-container-uses-built-in-nginx.md`（為何拿掉外部 Nginx 區塊）。詞彙見 `GLOSSARY.md` 的「GitLab 容器」「掛載目錄」「Git SSH 埠」。官方做法參考 GitLab 文件 `doc/install/docker/migrate.md` 的「Reuse existing data directories」。本票結束時 deb 套件**仍在**（purge 是 ISSUE-006），GitLab 已改由容器 18.10.3 服務。

## Blocked by
ISSUE-002 — 要有 `docker.sh` 與已載入的映像。

## Notes
- **不要改 `/etc/gitlab/ssl` 與 `external_url`**：Runner 與使用者都靠它，容器內建 Nginx 直接沿用。
- **不得把宿主機目錄 `chown` 成 `root:root`**，會讓容器起不來也救不回；權限只交給 `update-permissions`。
- 確認 `git-data/repositories` 存在且是真目錄（不是壞掉的 symlink），不然容器啟動會報 `stat: missing operand`。
- 管理區塊的標記與取代規則沿用 `common.sh` 既有的 `gitlab.rb` 管理區塊函式，不要另寫一套。
- 備份在 deb 還活著的時候呼叫（此時 `backup_auto.sh` 仍是 deb 模式）。
- 參數檔不存密碼（PR-COM-06）；確認字串不是密碼，不需隱藏。
- 真實動作（`docker run`、`apt`、停服務）要在 WSL Ubuntu-24.04 或 VM 試跑；Open question 3 的 UID 對齊細節要靠實測決定。
