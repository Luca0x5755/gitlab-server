---
blocked-by: [ISSUE-004, ISSUE-005, ISSUE-006, ISSUE-007]
---

# 補上 docker.sh 的說明與排查文字，並更新 README

## Done when
- `docker.sh` 選單含「說明」與「常見問題排查」，內容涵蓋（PR-DKR-30）：
  - 遷移與升級的整體順序，以及為何一定要經過 18.11（Upgrade Path Tool 的必停版本）。
  - **Git SSH 埠**改 2222（`git clone ssh://git@<主機>:2222/...`），宿主機 sshd 的 22 不動。
  - 權限錯誤時的 `update-permissions` 與 `docker restart gitlab`。
  - 容器起不來或一直重啟時怎麼查（`docker logs gitlab`、`stat: missing operand`、磁碟空間）。
  - purge 不可逆、只剩機外備份。
- `README.md` 腳本表新增 `docker.sh`，並標明 `install.sh`、`nginx.sh`、`upgrade.sh` 僅適用 deb 安裝（PR-DKR-32）。
- 內容只寫已實作且已試跑的行為；沒有試跑過的不要寫成已驗證。

## Context
Spec 見 `docs/issues/ISSUE-001-gitlab-docker-migration.md`。專案的慣例是「單一事實來源」：說明與排查放在腳本選單裡，不另立文件（見 `docs/decision-log.md` 2026-10-20「腳本完成後刪除 `docs/01`～`05`」）。可參考 `upgrade.sh`、`nginx.sh` 的「說明」「常見問題排查」項目寫法。

## Blocked by
ISSUE-004、ISSUE-005、ISSUE-006、ISSUE-007 — 說明要描述已存在的行為，必須等這些功能落地。

## Notes
- 這張票是最後收尾。順手檢查 `GLOSSARY.md` 的詞彙與腳本實際用詞一致（「GitLab 容器」「掛載目錄」「GitLab 映像包」「Git SSH 埠」）；不一致就改腳本文字，不要改成兩套說法。
- 若前面幾張票的試跑結論改變了 spec 的 Open questions 2、3，在這張票把 spec 對應段落更新為已解決，並在 `docs/adr/0001-...` 與 `0002-...` 把 `Status: Proposed` 改為 `Accepted`（`/implement` 的落地動作）。
- 全部票完成後，`docs/issues/` 下的檔案要刪光（`.github/workflows/issues-check.yml` 會擋合併）。
