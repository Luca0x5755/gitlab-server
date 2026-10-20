---
blocked-by: [ISSUE-004, ISSUE-009]
---

# nginx.sh：停用內建 Nginx、反向代理設定與回切

## Done when
- 偵測 `nginx.conf` 的 `user` 填入 `web_server['external_users']`；以管理區塊停用內建 Nginx（`nginx['enable'] = false`）並 `reconfigure`；確認 Workhorse socket 存在（PR-NGX-03）。
- 憑證用共用 `make_self_signed_cert` 產生，或複製 `/etc/gitlab/ssl` 已有的憑證（PR-NGX-04）。
- 產生 `/etc/nginx/conf.d/gitlab.conf`，HTTPS 或 HTTP 由使用者選；`server_name` 與憑證路徑來自參數（PR-NGX-05）。
- `nginx -t` 失敗時還原舊設定，不重啟 nginx（PR-NGX-06）。
- 確認 80 與 443 已釋放才啟動；移除 `default.conf`；`systemctl enable nginx`；`ufw allow 80/tcp`、`443/tcp`（PR-NGX-07）。
- 驗證：`systemctl status nginx`、`gitlab-ctl status`、`curl -kI https://<IP>`（PR-NGX-08）。
- 「切換回內建 Nginx」：移除管理區塊、停用並關閉外部 nginx、`reconfigure`（PR-NGX-09）。
- 範本渲染、worker 使用者偵測等純函式有 bash 測試（PR-COM-10）。
- 「常見問題排查」補上 502、Permission denied、413、WebSocket、push/pull 失敗等條目。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`。來源文件 `docs/04-nginx.md` 第 5 到 10 節與回切章節。原文件 `docs/01-install-and-config.md` 第三部分與 04 互相矛盾（`www-data` 對 `nginx`），本專案以偵測實際 worker 使用者解決，理由見 `docs/decision-log.md`。憑證函式由 ISSUE-004 提供，管理區塊函式由 ISSUE-003 提供，`nginx.sh` 骨架由 ISSUE-009 建立。

## Blocked by
ISSUE-004、ISSUE-009

## Notes
- nginx 設定範本含 `$http_upgrade` 等 nginx 變數，渲染時只替換自己的佔位符，避免被 shell 展開。
- 內建與外部 Nginx 的管理區塊要用不同區塊名稱，回切才能精準移除。
- 無法在 Windows 真跑；不得宣稱已驗證。
