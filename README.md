# GitLab Server 運維手冊

自架（Self-Hosted）**GitLab CE** 伺服器的離線安裝、備份還原、版本升級與日常維運腳本。
內容以 Ubuntu Server 24.04 + GitLab CE 為主，適用於**無外網、內部網段**的部署情境。

所有維運步驟都做成**互動式選單腳本**：直接執行即可，不帶參數；每支腳本的選單內有「說明」與「常見問題排查」。

## 📁 專案結構

```
gitlab-server/
├── README.md          # 本文件（總覽 + 目錄）
├── GLOSSARY.md        # 專案詞彙
├── .gitignore
├── docs/              # 決策紀錄與協作慣例
└── scripts/           # 運維腳本
    ├── lib/common.sh  # 共用函式
    └── test/          # 測試（bash scripts/test/run.sh）
```

## 🔧 腳本（scripts/）

選單項目會標示在哪台機器執行：【有網路的電腦】或【GitLab 伺服器】。

| 腳本 | 說明 |
| --- | --- |
| [install.sh](scripts/install.sh) | 離線安裝：加入套件來源、下載 `.deb`、`scp` 傳送、`dpkg -i` 安裝、`external_url`、初始密碼、HTTPS、LDAP（AD） |
| [backup.sh](scripts/backup.sh) | 備份選單：立即備份、列出、保留期限、crontab、複製設定備份、還原與還原後驗證 |
| [backup_auto.sh](scripts/backup_auto.sh) | 自動備份（資料備份＋設定備份），供 cron、升級前、選單共用 |
| [upgrade.sh](scripts/upgrade.sh) | 版本升級：吃一個 `.deb` 資料夾，逐版升級並等背景遷移歸零 |
| [nginx.sh](scripts/nginx.sh) | 外部 Nginx：離線打包與安裝、停用內建 Nginx、反向代理設定、切回內建 |
| [network.sh](scripts/network.sh) | 以 Netplan 設定固定 IP |

## ⚠️ 注意事項

- 大型安裝檔（`*.deb`、`*.iso`）**不納入版控**，已於 `.gitignore` 排除，請自行至官方來源下載。
- 範例中的 IP（如 `192.168.9.129`）、網域與帳號僅為範例，腳本會詢問實際值，答案存在 `scripts/gitlab-ops.env`（已列入 `.gitignore`，不含密碼）。

## 🗂️ 命名規則

- 資料夾／檔名一律使用**英文 kebab-case**（小寫、以 `-` 連接），避免空格與特殊字元。
- 程式註解使用繁體中文。
