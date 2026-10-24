# 詞彙表

**資料備份**:
`gitlab-backup create` 產出的 `<時間戳>_<日期>_<版本>_gitlab_backup.tar`，含儲存庫、資料庫、附件、Wiki。不含設定與金鑰。
_Avoid_: 完整備份（「完整」會讓人以為連設定都在裡面）、備份檔（沒指明是哪一種）

**設定備份**:
`gitlab-ctl backup-etc` 產出、放在 `/etc/gitlab/config_backup/` 的 tar，含 `gitlab.rb`、`gitlab-secrets.json`、`ssl`、`trusted-certs` 等整個 `/etc/gitlab`。沒有它，資料備份無法還原；應與資料備份存放在不同位置。
_Avoid_: 金鑰備份、config 備份

**備份 ID**:
還原時 `BACKUP=` 後面接的字串，只取資料備份檔名中 `_gitlab_backup.tar` 之前的部分（例：`1776235587_2026_04_15_18.7.6`）。不含路徑、不含後綴。
_Avoid_: 時間戳（備份 ID 除了時間戳，還包含日期與版本）

**中間版本**:
升級路徑上必須停留並完整升級的版本，由 Upgrade Path Tool 查得，GitLab 不可跳過。
_Avoid_: 過渡版本、跳板版本

**背景遷移**:
升級後由 Sidekiq 處理的 batched background migration。`BatchedMigration.queued.count` 為 0 才算完成；未完成不得安裝下一個中間版本。
_Avoid_: 資料庫遷移（`reconfigure` 跑的同步遷移是另一件事）

**內建 Nginx**:
GitLab Omnibus 自帶的 Nginx，由 `nginx['enable']` 控制。
**外部 Nginx**:
獨立安裝的 Nginx 套件（官方 mainline 來源），`gitlab.rb` 設 `nginx['enable'] = false` 後取代內建；透過 Workhorse socket 反向代理。
_Avoid_: 自訂 Nginx、獨立 Nginx

**Workhorse socket**:
`/var/opt/gitlab/gitlab-workhorse/sockets/socket`，外部 Nginx 的 upstream。其 worker 使用者須列入 `web_server['external_users']`。

**有網路的電腦**:
可連外、用來下載 `.deb` 與 Nginx 離線套件的機器。選單腳本中以「【有網路的電腦】」標示。
**GitLab 伺服器**:
斷網、實際執行 GitLab 的機器。選單腳本中以「【GitLab 伺服器】」標示。
_Avoid_: 內網機、離線機（兩者都沒說清楚是哪一台）

**選單腳本**:
`scripts/` 下以 `menu_loop`／`show_menu`／`dispatch` 組成、只有互動選單、不收參數的 bash 腳本（`install.sh`、`backup.sh`、`upgrade.sh`、`nginx.sh`、`network.sh`）。
_Avoid_: wizard、精靈（本專案不用線性 stage 風格）

**管理區塊**:
腳本寫入 `gitlab.rb` 的一段以標記行包夾的設定。重跑時整段取代，不碰標記以外的手寫內容。
_Avoid_: 附加設定（附加會讓人以為是追加）

**參數檔**:
`scripts/gitlab-ops.env`，由腳本維護、列入 `.gitignore`，存 IP、路徑、版本等詢問過的答案。不存任何密碼。
_Avoid_: 設定檔（容易與 `gitlab.rb`、設定備份混淆）

**Runner**:
GitLab Runner，領取並執行 CI job 的程序；GitLab 本體不跑 CI。本專案的 Runner 與 GitLab 裝在同一台（機器角色 `server`），用 Docker executor、註冊為 instance runner。
_Avoid_: CI 環境（沒說清楚是 Runner 還是 job 用的映像檔）、Agent

**Runner token**:
在後台建立 Runner 後取得、`glrt-` 開頭的 authentication token，`gitlab-runner register` 用它註冊。只存在 Runner 的 `config.toml`，不寫參數檔、日誌、命令列。
_Avoid_: 註冊 token（舊版 registration token 流程已不用）

**映像包**:
【有網路的電腦】以 `docker pull`＋`docker save` 打成的單一 tar，內含 CI job 會用到的 image，在【GitLab 伺服器】以 `docker load` 載入，供 `pull_policy = if-not-present` 使用。
_Avoid_: 映像檔（單指一個 image，而映像包是一整批）

**GitLab 容器**:
在【GitLab 伺服器】上以 `gitlab/gitlab-ce:<版本>-ce.0` 映像執行、名為 `gitlab` 的單一容器，取代 deb 安裝的 GitLab。內建 Nginx 與 PostgreSQL 都在容器內。
_Avoid_: Docker 版本（會被讀成 Docker Engine 的版本）、GitLab 映像（那是映像，不是正在跑的容器）

**掛載目錄**:
GitLab 容器以 bind mount 掛入的三個宿主機目錄：`/etc/gitlab`、`/var/opt/gitlab`、`/var/log/gitlab`。路徑與 deb 安裝時相同，所以遷移時資料不搬動。
_Avoid_: volume（易被讀成 Docker named volume）、資料目錄（只指 `/var/opt/gitlab`，漏了設定與日誌）

**GitLab 映像包**:
【有網路的電腦】以 `docker pull`＋`docker save` 打成的 tar，內含升級路徑上各中間版本的 `gitlab/gitlab-ce` 映像，在【GitLab 伺服器】以 `docker load` 載入。與「映像包」做法相同、內容不同（後者是 CI job 用的 image）。
_Avoid_: 升級包（沒說明是映像）

**Git SSH 埠**:
GitLab 容器發佈到宿主機、供 `git clone ssh://` 使用的埠，固定 2222；宿主機 sshd 的 22 不動，仍供管理員 `ssh`／`scp`。
_Avoid_: SSH 埠（沒說明是 Git 用還是管理用）
