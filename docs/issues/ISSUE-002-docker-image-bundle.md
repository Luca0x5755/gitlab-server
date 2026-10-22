---
blocked-by: []
---

# 建立 docker.sh：打包與載入 GitLab 映像包

## Done when
- `scripts/docker.sh` 是**選單腳本**（`menu_loop`／`show_menu`／`dispatch`，同 `upgrade.sh`、`runner.sh`），帶任何參數即拒絕並以非 0 結束（PR-COM-01）。頂層只定義函式、不執行動作，測試可 `source` 取得純函式。
- 【有網路的電腦】選單項目「打包 GitLab 映像包」：依版本清單逐一 `docker pull gitlab/gitlab-ce:<版本>-ce.0`，再 `docker save` 成單一 tar；任一 pull 失敗即不產生 tar（PR-DKR-01）。
- 版本清單預設 `18.10.3 18.11.13 19.2.9 19.5.1`，可由 `ask_param` 修改並存入參數檔（PR-DKR-02、PR-COM-05）。
- 【GitLab 伺服器】選單項目「載入 GitLab 映像包」：`docker load -i <tar>`；檔案不存在即中止；載入後列出已有的 `gitlab/gitlab-ce` tag（PR-DKR-03）。
- 每個項目依 PR-COM-04 標示機器角色，環境不符即中止並說明。
- 純函式（版本清單驗證與排序、映像 tag 組合）有 bash 測試，`bash scripts/test/run.sh` 全過（PR-DKR-31）。

## Context
Spec 見 `docs/issues/ISSUE-001-gitlab-docker-migration.md`（本票是它的 tracer bullet：先把「打包、傳送、載入」這條線打通）。詞彙見 `GLOSSARY.md` 的「GitLab 映像包」。做法與 `runner.sh` 的「映像包」（`docker pull`＋`docker save`／`docker load`）相同，直接參考該檔的 pull／save／load 函式與失敗時不留半成品 tar 的處理。腳本結構、`ask_param`、`require_machine`、`die` 等共用函式在 `scripts/lib/common.sh`。程式註解一律繁體中文。

## Blocked by
nothing

## Notes
- 版本字串驗證沿用 `common.sh` 的 `valid_gitlab_version`（它要求 `18.10.3-ce.0` 這種含 `-ce.N` 的形式），所以使用者輸入 `18.10.3` 時先補成 `18.10.3-ce.0` 再驗證；tag 後綴固定 `-ce.0`。
- 版本排序用 `common.sh` 的數值比較（18.7 < 18.10），不要用字串排序。
- 本票**不含**「安裝 Docker」項目（ISSUE-003）、說明與排查文字（ISSUE-008）。選單先放佔位項目即可，不要寫假內容。
- 本機是 Windows：`bash -n`、`shellcheck`、純函式測試可在本機做；真實 `docker` 動作要在 WSL Ubuntu-24.04 試跑，不要宣稱已驗證。Git Bash 的 `openssl` 會壞，不要用它。
- 測試註冊：新增 `scripts/test/test_docker.sh`，並確認 `run.sh` 會跑到它。
