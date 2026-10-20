---
blocked-by: [ISSUE-003]
---

# install.sh：啟用內建 Nginx 的 HTTPS

## Done when
- `lib/common.sh` 的 `make_self_signed_cert`：不互動（用 `-subj`），含 `subjectAltName`；參數是 IP 用 `IP:`，是網域用 `DNS:`（PR-COM-09）。
- `install.sh` 選單新增 HTTPS 項目：產生憑證、`external_url` 改 `https`、開啟 HTTP 導向 HTTPS、`ufw allow 443/tcp`，並 `reconfigure`（PR-INS-06）。
- 「常見問題排查」補上 `docs/01-install-and-config.md` 第二部分的注意事項。
- IP／網域判斷的純函式有 bash 測試（PR-COM-10）。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`。自簽憑證刻意偏離原文件（加 SAN、免互動），理由在 `docs/decision-log.md`。此函式之後也由 `nginx.sh`（ISSUE-010）共用，請放在 `lib/common.sh`。管理區塊函式由 ISSUE-003 提供。

## Blocked by
ISSUE-003

## Notes
- 憑證檔名沿用 `<IP或網域>.crt`／`.key`，放 `/etc/gitlab/ssl/`。
- `nginx['redirect_http_to_https']` 只在內建 Nginx 模式使用，勿與 `nginx.sh` 的外部 Nginx 設定混在同一個區塊。
