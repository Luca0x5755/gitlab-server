---
blocked-by: [ISSUE-002]
---

# nginx.sh：離線套件打包與安裝

## Done when
- `bash scripts/nginx.sh` 有選單，項目標示機器分區（PR-COM-04）。
- 【有網路】加入 nginx 官方 mainline 來源（匯入簽名金鑰），下載含相依的 `.deb` 並打包成 `nginx-offline.tar.gz`（PR-NGX-01）。
- 【伺服器】顯示 GitLab 內建 Nginx 版本；解包並 `dpkg -i`；出現相依錯誤時列出有問題的套件；驗證 `nginx -v` 與 `systemctl status nginx`（PR-NGX-02）。
- 含「說明」與「常見問題排查」，涵蓋 `docs/04-nginx.md` 的前置條件與排查表（PR-COM-11）。

## Context
規格見 `docs/issues/ISSUE-001-interactive-ops-scripts.md`，詞彙見 `GLOSSARY.md`（外部 Nginx、有網路的電腦、GitLab 伺服器）。來源文件 `docs/04-nginx.md` 第 1 到 4 節。反向代理設定在 ISSUE-010，本票不做。

## Blocked by
ISSUE-002

## Notes
- 下載相依時 `apt-get download` 不受本機已安裝狀態影響，文件有註明可在已裝 Nginx 的電腦上執行。
- 排查表較長，整份帶入此腳本的「常見問題排查」，ISSUE-010 再補與設定相關的條目。
- 無法在 Windows 真跑；不得宣稱已驗證。
