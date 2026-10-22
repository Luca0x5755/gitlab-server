# 將 deb 安裝的 GitLab 遷移到 Docker 並升級到 19.5.1

## Why
【GitLab 伺服器】目前是 deb 安裝的 GitLab CE 18.10.3，要改成 Docker 部署並升到最新。升級路徑必須經過**中間版本**：依 Upgrade Path Tool（`gitlab-org/gitlab` 的 `config/upgrade_path.yml`），18.10.3 要走 18.11 → 19.2 → 19.5，不能直接跳。這台機器斷網、不留退路，一旦做錯只剩機外備份，所以要把每一步做成選單腳本代跑，並在不可逆的步驟前擋住。

## Scope
新增選單腳本 `scripts/docker.sh`，涵蓋：打包與載入 **GitLab 映像包**、遷移（deb → **GitLab 容器**，沿用**掛載目錄**）、purge 舊套件、逐站升級。Docker 的離線安裝從 `runner.sh` 抽成共用函式。詞彙見 `GLOSSARY.md`；架構性決策見 ADR 0001、0002。

目標版本：18.10.3 → 18.11.13 → 19.2.9 → 19.5.1（各停靠站取該 minor 的最新 patch，Docker Hub 上已有這些 tag）。

## Promises

沿用 `PR-COM-01`（只有互動選單、帶參數即拒絕）、`PR-COM-03`（破壞性操作須輸入 `yes`，EOF 視為否）、`PR-COM-04`（標示【有網路的電腦】／【GitLab 伺服器】，環境不符即中止）、`PR-COM-05`（參數存 `gitlab-ops.env`）、`PR-COM-06`（密碼不落檔、不印出）、`PR-COM-07`（改 `gitlab.rb` 前備份）。

**映像包（DKR）**
- PR-DKR-01 — 【有網路的電腦】依版本清單 `docker pull gitlab/gitlab-ce:<版本>-ce.0`，再 `docker save` 成單一 **GitLab 映像包**；任一版本 pull 失敗即不產生 tar。
- PR-DKR-02 — 版本清單預設 18.10.3、18.11.13、19.2.9、19.5.1，可由 `ask_param` 修改。
- PR-DKR-03 — 【GitLab 伺服器】`docker load` 載入映像包；檔案不存在即中止；載入後列出已有的 `gitlab/gitlab-ce` tag。
- PR-DKR-04 — Docker 的離線安裝（`docker.io` 與相依）為共用函式，`docker.sh` 與 `runner.sh` 呼叫同一份；`runner.sh` 的既有行為與測試不變。

**遷移（DKR）**
- PR-DKR-10 — 遷移前檢查：目前為 deb 安裝且版本等於要啟動的映像 tag、Docker 已安裝、映像已載入；任一不符即中止並說明。
- PR-DKR-11 — 先呼叫備份產生資料備份與設定備份，列出兩個檔案的路徑與大小，要求輸入確認字串表示已複製到機外；備份失敗或未輸入確認字串即中止，且不動 deb 版。
- PR-DKR-12 — 移除 `gitlab.rb` 中 `nginx.sh` 寫入的**管理區塊**，並於管理區塊設定 `gitlab_rails['gitlab_shell_ssh_port'] = 2222`；改前依 PR-COM-07 備份。
- PR-DKR-13 — 停止 deb 版（`gitlab-ctl stop` 並停用其開機服務），確認 80、443、2222 未被占用，才繼續。
- PR-DKR-14 — 啟動 GitLab 容器前，以暫時容器對**掛載目錄**執行 `update-permissions`。
- PR-DKR-15 — **GitLab 容器**名稱為 `gitlab`，掛載 `/etc/gitlab`、`/var/opt/gitlab`、`/var/log/gitlab`（宿主機路徑相同），發佈 80、443 與 2222→22（**Git SSH 埠**），`--restart always`，`--shm-size 256m`；宿主機 sshd 設定不被修改。
- PR-DKR-16 — 啟動後等容器健康才算成功；逾時即停止並指向 `docker logs gitlab`。
- PR-DKR-17 — 驗證：容器內 `gitlab-rake gitlab:check` 與 `curl -kI <external_url>`；兩者通過才提供 purge。
- PR-DKR-18 — purge 須輸入 `yes` 與確認字串，說明不可逆；執行 `apt purge gitlab-ce` 後，**掛載目錄**內容仍在，並重跑 PR-DKR-17 的驗證，通過才算遷移完成。

**逐站升級（DKR）**
- PR-DKR-20 — 開跑前印出將升級的版本順序並須 `yes`；只升比目前容器版本高的映像，已載入但不高於目前版本者略過。
- PR-DKR-21 — 每一站升級前，以 `docker exec` 產生資料備份與設定備份；失敗即中止。
- PR-DKR-22 — 每一站：停止並移除舊容器（不動**掛載目錄**），以新 tag 與同一組參數重建容器，等健康。
- PR-DKR-23 — 進入 18.11 之前提示：啟動時會自動升級 PostgreSQL 到 17.7，耗時隨資料庫大小增加；顯示 `/var/opt/gitlab` 所在磁碟剩餘空間，須 `yes`。
- PR-DKR-24 — 每一站要等**背景遷移**歸零（容器內 `BatchedMigration.queued.count` 為 0）才進下一站；逾時即停止並指向 sidekiq 日誌。
- PR-DKR-25 — 全部完成後執行 `gitlab-rake gitlab:check SANITIZE=true`，並顯示最終版本。

**說明與測試（DKR）**
- PR-DKR-30 — 選單含「說明」與「常見問題排查」（遷移順序、為何要經 18.11、Git SSH 埠改 2222、權限錯誤時的 `update-permissions`、容器起不來時的檢查）。
- PR-DKR-31 — 純函式（版本排序、映像 tag 組合、`docker run` 參數組裝、管理區塊移除）有 bash 測試且通過；`docker`、`apt` 等真實動作在 Ubuntu 24.04 試跑，不宣稱已驗證。
- PR-DKR-32 — `README.md` 腳本表新增 `docker.sh`。

## Out of scope
- **Runner 的安裝與註冊**：沿用 `runner.sh`，在遷移與升級完成、GitLab 穩定在 19.5.1 之後才執行；本案只動它的 Docker 安裝部分（PR-DKR-04）。
- **外部 Nginx 搭配容器**、**把 Workhorse socket 掛到宿主機**：見 ADR 0002。
- **在宿主機 22 轉發 Git SSH 的 shim、停用或改埠宿主機 sshd**：無人使用 SSH clone，用 2222 即可。
- **保留 deb 當退路、備份再還原的遷移方式**：見 ADR 0001。
- **自動判斷升級路徑**：停靠站清單由人查 Upgrade Path Tool，腳本只依映像包內容與版本大小排序（承接 `PR-UPG` 的既有決定）。
- **機外備份的自動複製**：由使用者手動複製並輸入確認字串。
- **19.8 及之後的停靠站**、GitLab EE、多節點、Geo。
- **備份不含的項目**（Object Storage、Mattermost、Redis、server hooks）：另外處理，承接 `PR-BAK-09`。

## Decisions
- 沿用掛載目錄、遷移後 purge 舊 deb、停靠站與 patch 版本：見 `docs/adr/0001-gitlab-moves-to-docker-with-in-place-data.md`。被否決：備份再還原、先在 deb 上升到 19.5 再遷移、18.10.3 直接到 19.2。
- 容器使用內建 Nginx：見 `docs/adr/0002-container-uses-built-in-nginx.md`。被否決：宿主機 Nginx 反向代理、掛載 Workhorse socket。
- 以下為 `docs/decision-log.md` 已有的紀錄，這裡不重述：Git SSH 埠 2222、用 `docker run` 不用 compose、Docker 安裝抽成共用函式、Runner 排在升級之後、機外備份由使用者手動複製。

訪談後補定的預設值（未逐題討論）：逐站升級只處理比目前高的映像（類比 `PR-UPG-02`）；背景遷移逾時行為類比 `PR-UPG-06`；遷移與升級的確認字串形式由實作時定。若不合意，改對應 promise 即可。

## Open questions
1. **既有 deb 腳本的去向**：`upgrade.sh`（吃 `.deb`）、`nginx.sh`（外部 Nginx）、`install.sh`（deb 安裝）、`backup.sh`／`backup_auto.sh`（宿主機直接跑 `gitlab-ctl`）在容器版之後是改寫、刪除，還是標示為僅適用 deb 安裝？決定後，對應的 `PR-UPG-*`、`PR-NGX-*`、`PR-INS-*`、`PR-BAK-*` 要逐條改寫或標為 retired。由使用者在 `/to-tickets` 拆票前決定。
2. **`apt purge gitlab-ce` 對掛載目錄與運行中容器的影響**：預期不刪 `/var/opt/gitlab` 與 `/etc/gitlab`，但套件的 prerm／postrm 是否會動到容器正在用的檔案，需在 Ubuntu 24.04 試跑。若有影響，purge 改為「停容器 → purge → 啟容器」。PR-DKR-18 的驗證步驟就是為此留的。
3. **UID 對齊、容器內 `gitlab-ctl backup-etc`、18.11 的 PostgreSQL 升級耗時與磁碟需求**：都要在實際資料上實測，才能決定 PR-DKR-14、21、23 的細節與警告門檻。由使用者在目標機器或相同大小的資料副本上試跑。
4. **`ufw` 與 Docker 發佈埠**：Docker 直接寫 iptables，`ufw` 規則擋不住它發佈的 80／443／2222。是否要額外限制來源網段？由使用者決定；不決定則維持現狀。
