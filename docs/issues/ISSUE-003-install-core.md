---
blocked-by: [ISSUE-002]
---

# install.sh：下載、安裝、設定 external_url

## Done when
- `bash scripts/install.sh` 有選單，項目標示「【有網路的電腦】」或「【GitLab 伺服器】」（PR-COM-04）；含「說明」與「常見問題排查」，涵蓋 `docs/01-install-and-config.md` 的前置條件與注意事項（PR-COM-11）。
- 【有網路】加入 GitLab 套件來源、列出可用版本、下載指定版本 `.deb`（PR-INS-01）；以 `scp` 傳到伺服器（PR-INS-02）。
- 【伺服器】`dpkg -i` 安裝指定 `.deb`，檔案不存在即中止（PR-INS-03）。
- 以管理區塊設定 `external_url` 並 `reconfigure`（PR-INS-04）。
- 顯示 `initial_root_password` 並提醒 24 小時內修改；檔案已不存在時說明原因（PR-INS-05）。
- 共用函式：改 `gitlab.rb` 前備份為 `gitlab.rb.bak-<時間戳>`；管理區塊重跑整段取代、區塊外內容不變；`reconfigure` 失敗時詢問是否還原備份（PR-COM-07、PR-COM-08）。
- 管理區塊的取代／追加邏輯、版本字串處理等純函式有 bash 測試，掛進 `scripts/test/run.sh`（PR-COM-10）。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，詞彙見 `GLOSSARY.md`（管理區塊、有網路的電腦、GitLab 伺服器）。`lib/common.sh` 與測試執行器由 ISSUE-002 建立，本票在其上加 `gitlab.rb` 管理區塊函式。`install.sh` 不包含外部 Nginx（交給 `nginx.sh`）。

## Blocked by
ISSUE-002

## Notes
- 管理區塊以標記行包夾；「重跑不重複追加」要有測試。
- 管理區塊函式要設計成後續票（HTTPS、LDAP、備份保留、Nginx）都能用不同的區塊名稱。
- 無法在 Windows 真跑 `dpkg`／`reconfigure`；不得宣稱已驗證。
- 註解繁體中文。
