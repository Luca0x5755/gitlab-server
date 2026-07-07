# GitLab Server 運維手冊

自架（Self-Hosted）**GitLab CE** 伺服器的離線安裝、備份還原、版本升級與日常使用文件集。
內容以 Ubuntu Server 24.04 + GitLab CE 為主，適用於**無外網、內部網段**的部署情境。

## 📁 專案結構

```
gitlab-server/
├── README.md          # 本文件（總覽 + 目錄）
├── .gitignore
├── docs/              # 運維文件（安裝／備份／升級／網路）
├── tutorials/         # 圖文教學（含操作截圖）
└── scripts/           # 運維腳本
```

## 📚 運維文件（docs/）

| # | 文件 | 說明 |
| --- | --- | --- |
| 01 | [安裝與設定](docs/01-install-and-config.md) | 離線下載 `.deb`、安裝並初次設定 GitLab CE |
| 02 | [備份與還原](docs/02-backup-and-restore.md) | 資料備份、設定與金鑰備份、定期清理與還原 |
| 03 | [版本升級](docs/03-upgrade.md) | 確認升級路徑、循序安裝中間版本 |
| 04 | [安裝 Nginx](docs/04-nginx.md) | 離線安裝外部 Nginx 取代 GitLab 內建 |
| 05 | [網路設定](docs/05-network.md) | 使用 Netplan 設定固定 IP |

## 🖥️ 圖文教學（tutorials/）

| # | 教學 | 說明 |
| --- | --- | --- |
| 01 | [語言設定](tutorials/01-language-setting/) | 將介面語言切換為繁體中文 |
| 02 | [SSH 設定](tutorials/02-ssh-setup/) | 產生 SSH 金鑰並加入 GitLab |
| 03 | [建立專案](tutorials/03-create-project/) | 建立儲存庫並推送程式碼 |

## 🔧 腳本（scripts/）

| 腳本 | 說明 |
| --- | --- |
| [gitlab_backup.sh](scripts/gitlab_backup.sh) | GitLab 自動備份腳本 |

## ⚠️ 注意事項

- 大型安裝檔（`*.deb`、`*.iso`）**不納入版控**，已於 `.gitignore` 排除，請自行至官方來源下載。
- 文件中的 IP（如 `192.168.9.129`）、網域與帳號為範例，請依實際環境替換。

## 🗂️ 命名規則

新增文件與資料夾請遵循以下規則，保持結構一致：

- 資料夾／檔名一律使用**英文 kebab-case**（小寫、以 `-` 連接），避免空格與特殊字元。
- 有先後順序的文件以**兩位數字前綴**排序（`01-`、`02-`…）。
- 每個教學資料夾以 `README.md` 為主文件，截圖與文件放在同一層並用相對路徑引用。
