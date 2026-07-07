## 🚀 第四部分：版本升級 (循序漸進)

### 1. 確認升級路徑
GitLab 不可跨大版本直接升級。請先確認目前版本：
```bash
sudo gitlab-rake gitlab:env:info
```
請至 [Upgrade Path Tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/) 查詢必須停留的「中間版本」。

### 2. 執行升級指令
依序安裝各個中間版本的 `.deb` 檔：
```bash
# 1. 停止作業服務
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq

# 2. 安裝特定版本
sudo dpkg -i gitlab-ce_中間版本_amd64.deb

# 3. 重新配置
sudo gitlab-ctl reconfigure
```

### 3. 啟動服務並檢查資料庫遷移 (跨版本關鍵)
reconfigure 不會自動重啟服務，需手動啟動，Sidekiq 必須運行才能處理背景遷移：
```bash
sudo gitlab-ctl start
sudo gitlab-ctl status   # 確認所有服務皆為 run
```
**在安裝下一個版本前**，必須確保回傳值為 **0**：
```bash
sudo gitlab-rails runner -e production 'puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count'
```
若不為 0，等待幾分鐘後重新檢查，直到回傳 **0** 才可安裝下一個版本。

### 4. 完成升級
```bash
# 重啟所有服務，載入新版本程式碼
sudo gitlab-ctl restart

# 執行全面健康檢查，SANITIZE=true 會隱藏輸出中的敏感資訊（如 token、密碼）
sudo gitlab-rake gitlab:check SANITIZE=true
```
