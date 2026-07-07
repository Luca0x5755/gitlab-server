## 💾 第三部分：備份與還原

> **備份不包含的項目：** Object Storage 中的內容、Mattermost 資料、Redis 佇列資料、系統層級的 server hooks。這些需另外處理。

### 1. 建立資料備份
執行後檔案會存在 `/var/opt/gitlab/backups`：
```bash
sudo gitlab-backup create
```

### 2. 備份設定與金鑰 (極重要)
**沒有這些檔案，資料備份將無法還原。**
設定備份應與資料備份存放在**不同的安全位置**，避免金鑰與加密資料放在一起：
```bash
sudo gitlab-ctl backup-etc
```
備份檔會產生在 `/etc/gitlab/config_backup/`，僅 root 可讀。

### 3. 定期清理
編輯 `gitlab.rb` 設定備份保留 7 天 (604800 秒)：
```ruby
gitlab_rails['backup_keep_time'] = 604800
```
修改後需重新載入設定：
```bash
sudo gitlab-ctl reconfigure
```

---

### 4. 還原流程

#### 前置條件
- 新主機的 GitLab **版本與類型 (CE/EE) 必須與備份時完全一致**
- 新主機必須已安裝 GitLab 並至少執行過一次 `sudo gitlab-ctl reconfigure`
- 目標主機**不應有既有的正式資料**（還原會覆蓋）
- 準備好資料備份檔（`*_gitlab_backup.tar`）與設定備份檔

#### 步驟

**① 還原設定與金鑰**
```bash
sudo tar -xvf gitlab_config_*.tar -C /
sudo gitlab-ctl reconfigure
```

**② 將備份檔放到備份目錄**
```bash
sudo cp *_gitlab_backup.tar /var/opt/gitlab/backups/
sudo chown git:git /var/opt/gitlab/backups/*_gitlab_backup.tar
```

**③ 停止寫入相關服務**
```bash
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq
sudo gitlab-ctl status
```

**④ 執行還原**

`BACKUP=` 只填時間戳 ID，**不含路徑、不含 `_gitlab_backup.tar` 後綴**（系統會自動補上）：
```
備份檔名：1776235587_2026_04_15_18.7.6_gitlab_backup.tar
            ↓ 只取這段 ↓
BACKUP=    1776235587_2026_04_15_18.7.6
```
```bash
sudo gitlab-backup restore BACKUP=1776235587_2026_04_15_18.7.6
```
還原過程會詢問是否覆蓋現有資料，輸入 `yes` 確認。

**⑤ 啟動服務**
```bash
sudo gitlab-ctl reconfigure
sudo gitlab-ctl start
```
確認所有服務皆為 `run` 狀態後，再進行驗證：
```bash
sudo gitlab-ctl status
```

**⑥ 驗證**
```bash
sudo gitlab-rake gitlab:check SANITIZE=true
sudo gitlab-rake gitlab:doctor:secrets
sudo gitlab-rake gitlab:artifacts:check
sudo gitlab-rake gitlab:lfs:check
sudo gitlab-rake gitlab:uploads:check
```

#### 驗證項目
- 登入 GitLab Web 介面確認帳號與專案存在
- 隨機 clone 一個專案確認 Git 資料完整
- 確認 CI/CD 變數、Runner 等設定正常
