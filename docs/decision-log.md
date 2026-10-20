# 決策紀錄

- 2026-10-20 運維流程轉成五支選單腳本（`install.sh`、`backup.sh`、`upgrade.sh`、`nginx.sh`、`network.sh`），不用線性 wizard — 這些是會重複執行的維運動作，選單可隨時挑任一項。
- 2026-10-20 腳本全自動執行並冪等寫入 `gitlab.rb` 管理區塊，不再開 `nano` — 要的是互動式腳本，不是講義。
- 2026-10-20 每次改 `gitlab.rb` 前備份為 `gitlab.rb.bak-<時間戳>`，`reconfigure` 失敗時詢問是否還原 — 改壞設定後 GitLab 無法重新配置。
- 2026-10-20 參數以詢問取得、答案存入 `scripts/gitlab-ops.env`；LDAP bind 密碼只隱藏輸入、不落檔 — 重跑省重打，但密碼不外洩到參數檔。
- 2026-10-20 設定備份以 `gitlab-ctl backup-etc` 為準，改寫並改名 `gitlab_backup.sh` 為 `backup_auto.sh`（cron、升級前、選單「立即備份」共用）— 原腳本只 tar 三個檔案，漏掉 `trusted-certs` 等。
- 2026-10-20 外部 Nginx 全流程歸 `nginx.sh`，`install.sh` 不再重複；`external_users` 讀 `nginx.conf` 的 `user` 偵測 — 01 寫 `www-data`、04 寫 `nginx`，兩份文件互相矛盾。
- 2026-10-20 自簽憑證共用 `common.sh` 的 `make_self_signed_cert`，加 `subjectAltName` 並用 `-subj` — 只有 CN 的憑證現代瀏覽器會報錯；偏離原文件。
- 2026-10-20 `upgrade.sh` 吃一個依序放 `.deb` 的資料夾，逐版升級並輪詢背景遷移歸零，已裝版本以下的檔案略過 — 允許中斷後接續；「該停哪些版本」仍由人查 Upgrade Path Tool。
- 2026-10-20 `network.sh` 只提醒 IP 變更後 `external_url`、憑證、`server_name` 需同步，不自動連動修改 — 改 IP 罕見，自動連動牽涉過廣。
- 2026-10-20 腳本完成後刪除 `docs/01`～`05`，全部內容（前置條件、注意事項、故障排查表、切換回內建 Nginx 等）併入對應腳本，各腳本以選單項目「說明」「常見問題排查」呈現；README 改指向腳本 — 單一事實來源，文件與腳本不再漂移（取代先前「文件縮成說明」的決定）。刪除須在腳本實作並試跑通過之後。
- 2026-10-20 驗證採 `bash -n`、`shellcheck`、純函式的 bash 測試；`dpkg`／`netplan` 等真實動作靠 Ubuntu VM 試跑，不宣稱已驗證 — 本機為 Windows。
