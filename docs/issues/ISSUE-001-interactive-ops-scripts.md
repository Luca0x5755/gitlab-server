# 將五份運維文件轉成互動式選單腳本

## Why
GitLab 離線安裝、備份還原、升級、外部 Nginx、固定 IP 目前是五份要人照著複製貼上的文件。文件之間有矛盾：`external_users` 一處寫 `www-data`，一處寫 `nginx`；設定備份的做法也和 `gitlab_backup.sh` 不一致。要把每一步改成腳本代跑，並讓事實只存放在腳本裡。

## Scope
五支選單腳本 `scripts/install.sh`、`backup.sh`、`upgrade.sh`、`nginx.sh`、`network.sh`，加共用的 `scripts/lib/common.sh`。`gitlab_backup.sh` 改寫並改名為 `backup_auto.sh`。五份文件的內容全部併入腳本後，`docs/01`~`05` 刪除。詞彙見 `GLOSSARY.md`。

## Promises

**共用（COM）**
- PR-COM-01 — 腳本只有互動選單，帶任何參數即拒絕並以非 0 結束。
- PR-COM-02 — `source lib/common.sh` 不產生副作用（不 `cd`、不改 shell 選項）。
- PR-COM-03 — 破壞性操作須輸入 `yes`；stdin 讀到 EOF 視為否。
- PR-COM-04 — 選單項目標示「【有網路的電腦】」或「【GitLab 伺服器】」；環境不符（無 `apt`、無 `/opt/gitlab`）時中止，並說明應在哪台執行。
- PR-COM-05 — 參數詢問帶預設值，Enter 沿用上次答案；答案存入 `scripts/gitlab-ops.env`，該檔列入 `.gitignore`。
- PR-COM-06 — 任何密碼不寫入 `gitlab-ops.env`，也不印到終端（唯一例外：PR-INS-05 顯示的 `initial_root_password` 那一行，見 `docs/decision-log.md`）。
- PR-COM-07 — 改 `gitlab.rb` 前先備份為 `gitlab.rb.bak-<時間戳>`；管理區塊重跑時整段取代，區塊外內容不變。
- PR-COM-08 — `reconfigure` 失敗時詢問是否還原備份。
- PR-COM-09 — `make_self_signed_cert` 不互動、含 SAN；參數是 IP 用 `IP:`，是網域用 `DNS:`。
- PR-COM-10 — 純函式（版本比較、IP 驗證、nginx worker 使用者偵測、範本渲染）有 bash 測試且通過。
- PR-COM-11 — 每支腳本選單含「說明」與「常見問題排查」，涵蓋原文件的前置條件、注意事項與排查表。
- PR-COM-12 — 測試放在 `scripts/test/`，以 `bash scripts/test/run.sh` 一次執行全部，任一失敗即非 0。

**安裝（INS）**
- PR-INS-01 — 【有網路】加入 GitLab 套件來源、列出可用版本、下載指定版本 `.deb`。
- PR-INS-02 — 【有網路】以 `scp` 把檔案傳到伺服器。
- PR-INS-03 — 【伺服器】用 `dpkg -i` 安裝指定 `.deb`；檔案不存在即中止。
- PR-INS-04 — 以管理區塊設定 `external_url` 並 `reconfigure`。
- PR-INS-05 — 顯示 `initial_root_password`，提醒 24 小時內修改；檔案已不存在時說明原因。
- PR-INS-06 — 啟用內建 Nginx 的 HTTPS：產生憑證、`external_url` 改 https、開啟導向、`ufw allow 443/tcp`。
- PR-INS-07 — LDAP：詢問 AD 參數，先測連線，寫入管理區塊（加密模式 `plain`／`start_tls`／`simple_tls` 對應正確 port），`reconfigure` 後執行 `gitlab:ldap:check`。

**備份還原（BAK）**
- PR-BAK-01 — 「立即備份」呼叫 `backup_auto.sh`：先資料備份，再 `gitlab-ctl backup-etc`。
- PR-BAK-02 — `backup_auto.sh` 在資料備份失敗時以非 0 結束；cron、升級前、選單共用同一份。
- PR-BAK-03 — 資料備份保留 7 天，由管理區塊的 `backup_keep_time = 604800` 設定。
- PR-BAK-04 — 列出現有的資料備份與設定備份。
- PR-BAK-05 — 還原前檢查已裝版本與備份檔名中的版本一致，不符即中止。
- PR-BAK-06 — 還原依序：設定備份 → 放入備份目錄並 `chown git:git` → 停 puma 與 sidekiq → `restore BACKUP=<備份 ID>` → `reconfigure` 與 `start`；備份 ID 由檔名自動取出，不含路徑與後綴。
- PR-BAK-07 — 還原前須輸入 `yes`。
- PR-BAK-08 — 還原後依序執行五項驗證 rake，並彙總成功與失敗。
- PR-BAK-09 — 「說明」列出備份不含的項目：Object Storage、Mattermost、Redis、server hooks。
- PR-BAK-10 — 提供「註冊／移除 crontab」項目，排程呼叫 `backup_auto.sh`；重複註冊不產生重複項目。
- PR-BAK-11 — 提供「複製設定備份到指定目錄」，目錄記入參數檔。
- PR-BAK-12 — `backup_auto.sh` 清理超過 7 天的設定備份。

**升級（UPG）**
- PR-UPG-01 — 顯示目前版本（`gitlab:env:info`）。
- PR-UPG-02 — 吃一個資料夾，依版本由小到大排序；已裝版本以下的檔案略過。
- PR-UPG-03 — 開跑前印出將安裝的版本順序並須輸入 `yes`。
- PR-UPG-04 — 開跑前呼叫備份；失敗即中止。
- PR-UPG-05 — 每一版：停 puma 與 sidekiq → `dpkg -i` → `reconfigure` → `start` → `status`。
- PR-UPG-06 — `BatchedMigration.queued.count` 為 0 才進下一版；逾時即停止，並指向 sidekiq 日誌。
- PR-UPG-07 — 全部完成後 `restart`，並執行 `gitlab:check SANITIZE=true`。

**外部 Nginx（NGX）**
- PR-NGX-01 — 【有網路】加入 nginx 官方 mainline 來源，下載含相依的 `.deb` 並打包成 `nginx-offline.tar.gz`。
- PR-NGX-02 — 【伺服器】顯示內建 Nginx 版本；解包並 `dpkg -i`；相依錯誤時列出有問題的套件。
- PR-NGX-03 — 偵測 `nginx.conf` 的 `user` 填入 `external_users`；停用內建 Nginx；確認 Workhorse socket 存在。
- PR-NGX-04 — 憑證用共用函式產生，或複製 `/etc/gitlab/ssl` 已有的憑證。
- PR-NGX-05 — 產生 `conf.d/gitlab.conf`，HTTPS 或 HTTP 由使用者選；`server_name` 與憑證路徑來自參數。
- PR-NGX-06 — `nginx -t` 失敗時還原舊設定，不重啟 nginx。
- PR-NGX-07 — 確認 80 與 443 已釋放才啟動；移除 `default.conf`；開 `ufw` 80 與 443。
- PR-NGX-08 — 驗證：`systemctl status nginx`、`gitlab-ctl status`、`curl -kI`。
- PR-NGX-09 — 「切換回內建 Nginx」：移除管理區塊、停用外部 nginx、`reconfigure`。

**網路（NET）**
- PR-NET-01 — 列出網卡與目前 IP，讓使用者選介面。
- PR-NET-02 — 輸入 IP/CIDR、閘道、DNS，並驗證格式。
- PR-NET-03 — 寫入前備份既有 yaml；產生的 yaml 只用空白縮排。
- PR-NET-04 — `netplan generate` 驗證失敗時不套用。
- PR-NET-05 — 偵測到 `SSH_CONNECTION` 時警告斷線與回滾風險。
- PR-NET-06 — 套用後顯示 `ip addr` 並 `ping`。
- PR-NET-07 — 套用後若 `external_url` 的主機與新 IP 不一致，列出需重跑的項目，不自動修改。

**收尾（DOC）**
- PR-DOC-01 — `docs/01`~`05` 的每個章節都能在腳本找到去處；五支腳本實作並在 Ubuntu VM 試跑通過後才刪除這五份文件。
- PR-DOC-02 — `README.md` 的文件表改指向腳本，移除 `tutorials/`。
- PR-DOC-03 — `gitlab_backup.sh` 改名為 `backup_auto.sh`，README 同步。

## Out of scope
- **自動連動改 IP**：改 IP 後 `external_url`、憑證、`server_name` 只提醒，不代改。改 IP 罕見，連動牽涉過廣。
- **判斷升級路徑**：該停在哪些中間版本由人查 Upgrade Path Tool。
- **備份不含的項目**：Object Storage、Mattermost、Redis、server hooks 另外處理。
- **GitLab EE**，以及多節點或高可用部署。
- **線性 wizard 風格**：本專案不用。
- **在 Windows 執行**：腳本只在 Ubuntu 24.04 跑。

## Decisions
全部決策見 `docs/decision-log.md`，沒有 ADR。被否決的方案：
- **線性 wizard**：否決，維運動作會重複執行，選單才能隨時挑任一項。
- **開 `nano` 手改 `gitlab.rb`、或只顯示指令**：否決，要的是腳本代跑。
- **以現有 `gitlab_backup.sh` 的 tar 三個檔案為準**：否決，會漏掉 `trusted-certs`，改用 `backup-etc`。
- **文件縮成說明**：否決，改為整份刪除，避免文件與腳本漂移。
- **改 IP 後自動連動修改**：否決，見 Out of scope。

訪談後補定的預設值（未逐題討論）：備份排程由 `backup.sh` 提供、設定備份可複製離機、設定備份同樣保留 7 天、測試放 `scripts/test/`。若不合意，改對應 promise 即可。

## Open questions
1. **試跑環境**：有沒有 Ubuntu 24.04 的 VM 或 WSL？沒有的話 PR-DOC-01 的刪除門檻無法達成，需要先取得環境，或改由你在目標伺服器上手動試跑。
