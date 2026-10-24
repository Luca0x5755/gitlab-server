Status: Proposed

# GitLab 改以 Docker 部署，沿用 deb 的資料目錄並 purge 舊套件

## 決定

在同一台【GitLab 伺服器】上，把 deb 安裝的 GitLab 18.10.3 改成 GitLab 容器：

1. 先做資料備份與設定備份，並由使用者確認已複製到機外。
2. 停掉 deb 版，以**掛載目錄**（`/etc/gitlab`、`/var/opt/gitlab`、`/var/log/gitlab`，路徑不變）啟動 `gitlab/gitlab-ce:18.10.3-ce.0`。啟動前用暫時容器跑 `update-permissions` 對齊 UID。
3. `gitlab-rake gitlab:check` 通過後，`apt purge` 舊的 `gitlab-ce`。**不保留退路**；purge 前須使用者輸入確認字串。
4. 之後逐站升級，只換映像 tag，不再用 `.deb`：18.10.3 → 18.11.13 → 19.2.9 → 19.5.1（各站為該 minor 的最新 patch；停靠站依 Upgrade Path Tool，即 `gitlab-org/gitlab` 的 `config/upgrade_path.yml`）。每站升級前先備份，並等**背景遷移**歸零。

## 為什麼

- GitLab 官方 Docker 遷移文件允許同機沿用既有資料目錄：不需要備份再還原，不必另搬 `gitlab-secrets.json`，磁碟也不用多放一份資料。前提是 deb 與映像版本一致（18.10.3 對 18.10.3）。
- 使用者明確要求不留後路，所以 purge；排在「容器驗證通過後、第一次升級前」，避免容器起不來時無法回頭。
- 18.11 起會自動升 PostgreSQL 17.7（單機 Linux package 與 Docker），19.0 起 PostgreSQL 17 為最低版本；因此 18.11 是必經站，且該站啟動耗時與資料庫大小有關。

## 否決的做法

- **備份再還原到新容器**：可保留舊 deb 當退路，但同機需要兩份資料的磁碟，且要另外搬金鑰；與「不留後路」衝突。
- **先在 deb 上升到 19.5 再遷移**：三站都在舊環境跑，最後才第一次碰 Docker，風險集中在最後；也要維護 `upgrade.sh` 的 `.deb` 流程。
- **直接 18.10.3 → 19.2**：Upgrade Path Tool 要求 18.11，不支援。

## 後果

- 現有 `upgrade.sh`（吃 `.deb` 資料夾）與 `backup_auto.sh`（宿主機直接跑 `gitlab-backup`）要改成 `docker exec` 或退場。
- 遷移前須移除 `gitlab.rb` 中 `nginx.sh` 寫入的管理區塊（見 0002）。
