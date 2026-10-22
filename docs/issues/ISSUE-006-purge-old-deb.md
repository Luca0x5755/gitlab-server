---
blocked-by: [ISSUE-004]
---

# 驗證通過後 purge 舊的 deb 套件

## Done when
`docker.sh` 的【GitLab 伺服器】選單新增「移除舊 deb 套件」：
- 只有在 ISSUE-004 的驗證（`gitlab:check` 與 `curl -kI`）剛通過時才可執行；容器不健康即拒絕並說明。
- 說明這一步**不可逆**、之後只剩機外備份；須輸入 `yes` 與確認字串；stdin 讀到 EOF 視為否（PR-DKR-18、PR-COM-03）。
- 執行 `apt purge gitlab-ce` 後，**掛載目錄**（`/etc/gitlab`、`/var/opt/gitlab`、`/var/log/gitlab`）內容仍在，並重跑 ISSUE-004 的驗證；通過才算遷移完成，否則明確報錯而不是默默繼續（PR-DKR-18）。
- 判斷「驗證剛通過」「掛載目錄仍在」的純函式有 bash 測試。

## Context
Spec 見 `docs/issues/ISSUE-001-gitlab-docker-migration.md`；ADR 見 `docs/adr/0001-gitlab-moves-to-docker-with-in-place-data.md`（使用者明確要求不留後路，purge 排在容器驗證通過之後、第一次升級之前）。Spec 的 Open question 2：`apt purge` 的 prerm／postrm 是否會動到容器正在用的檔案，尚未實測。

## Blocked by
ISSUE-004 — 要有可驗證的容器。

## Notes
- **先在 WSL Ubuntu-24.04 或 VM 用相同流程試跑，確認 purge 對掛載目錄的影響**，再決定要不要改成「停容器 → purge → 啟容器」。這個結論要寫回 spec 的 Open question 2（改為已解決），並在腳本註解說明為什麼這樣排。
- purge 前先把容器的重啟政策與目前狀態記下，purge 失敗時至少能讓容器回到原樣。
- 不要加 `gitlab-ctl cleanse`：它會刪資料目錄，絕對不能碰。
- 不要因為 `apt purge` 回非 0 就把整個遷移判為失敗；以掛載目錄與容器健康為準，並把實際輸出貼給使用者。
