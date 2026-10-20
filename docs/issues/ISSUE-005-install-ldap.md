---
blocked-by: [ISSUE-003]
---

# install.sh：Active Directory (LDAP) 整合

## Done when
- `install.sh` 選單新增 LDAP 項目，詢問 AD IP、port、bind DN、base DN、加密模式（`plain`／`start_tls`／`simple_tls`），模式與 port 對應正確（`simple_tls` 預設 636）（PR-INS-07）。
- 寫入設定前先測連線（`nc -zv`，有 `ldapsearch` 時再試 bind）。
- 以管理區塊寫入 `gitlab.rb`，`reconfigure` 後自動執行 `gitlab-rake gitlab:ldap:check` 並顯示結果。
- bind 密碼以隱藏輸入取得，不寫入 `scripts/gitlab-ops.env`、不印到終端（PR-COM-06）。
- 「常見問題排查」收錄 `docs/01-install-and-config.md` 第五部分的症狀表（連線逾時、bind 失敗、找不到使用者、自簽憑證放 `trusted-certs`）。
- 加密模式對應 port 等純函式有 bash 測試（PR-COM-10）。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，管理區塊函式與備份還原機制由 ISSUE-003 提供。密碼只能寫進 `gitlab.rb`，這是 GitLab 設定格式的限制。

## Blocked by
ISSUE-003

## Notes
- 管理區塊內含密碼，寫入後確認 `gitlab.rb` 權限仍為 root 專用（600）。
- `gitlab.rb.bak-<時間戳>` 備份檔也含密碼，權限須同樣收緊。
