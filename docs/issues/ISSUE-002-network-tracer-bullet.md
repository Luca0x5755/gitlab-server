---
blocked-by: []
---

# 以 network.sh 打通選單腳本的整條路（追蹤彈）

## Done when
- `bash scripts/network.sh` 顯示選單（互動、不收參數；帶任何參數即拒絕並以非 0 結束）（PR-COM-01）。
- 選單含「說明」與「常見問題排查」，內容取自 `docs/05-network.md`（PR-COM-11）。
- 列出網卡與目前 IP，使用者選介面；輸入 IP/CIDR、閘道、DNS 並驗證格式（PR-NET-01、PR-NET-02）。
- 寫入前備份既有 netplan yaml；新 yaml 只用空白縮排；`netplan generate` 失敗則不套用（PR-NET-03、PR-NET-04）。
- 偵測到 `SSH_CONNECTION` 時警告斷線與回滾風險（PR-NET-05）；套用後顯示 `ip addr` 並 `ping`（PR-NET-06）。
- 套用後若 `/etc/gitlab/gitlab.rb` 的 `external_url` 主機與新 IP 不一致，列出需重跑的項目，不自動修改（PR-NET-07）。
- `scripts/lib/common.sh` 提供：選單迴圈、`die`、`confirm`（輸入 `yes`，stdin EOF 視為否）、參數詢問（有預設、Enter 沿用）並存入 `scripts/gitlab-ops.env`、機器檢查（缺 `apt` 或 `/opt/gitlab` 時說明該在哪台執行）；`source` 時無副作用（PR-COM-02、03、04、05）。
- `scripts/gitlab-ops.env` 列入 `.gitignore`。
- IP 驗證等純函式有 bash 測試；`bash scripts/test/run.sh` 一次跑全部，任一失敗即非 0（PR-COM-10、PR-COM-12）。
- `bash -n` 與 `shellcheck` 通過。

## Context
把五份運維文件轉成互動式選單腳本，規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，詞彙見 `GLOSSARY.md`，決策見 `docs/decision-log.md`。本票是追蹤彈：用最不依賴 GitLab 的 `network.sh` 驗證共用接縫。風格參考專案在 `D:\automated_trading\scripts`（`deploy.sh`、`container.sh`、`lib/common.sh`）：`menu_loop`／`show_menu`／`dispatch`、`die`、`confirm`。程式註解一律繁體中文。

## Blocked by
nothing

## Notes
- 腳本只在 Ubuntu 24.04 執行；本機是 Windows，只能做 `bash -n`、`shellcheck` 與純函式測試，真實 `netplan` 動作需 Ubuntu 試跑，不得宣稱已驗證。
- 不做 `gitlab.rb` 管理區塊（留給 ISSUE-003）；本票只「讀」`external_url`。
- 參數檔不得存密碼。
- 不用線性 wizard 風格（不清畫面、不分 stage）。
