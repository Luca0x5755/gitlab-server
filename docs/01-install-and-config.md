## 📦 第一部分：離線安裝 GitLab



### 1. 準備工作 (有網路的電腦)

#### 方法一：從官網手動下載
1.  前往 [GitLab CE 官方套件庫](https://packages.gitlab.com/gitlab/gitlab-ce)。
2.  搜尋 **Ubuntu 24.04 (Noble)** 版本。
3.  下載最新的 `amd64.deb` 檔案 (例如：`gitlab-ce_17.x.x_amd64.deb`)。

#### 方法二：透過 apt 下載 (有網路的 Ubuntu)
先加入 GitLab 官方套件來源：
```bash
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash
```
查詢可用版本：
```bash
apt-cache madison gitlab-ce
```
僅下載 `.deb` 檔，不進行安裝：
```bash
apt download gitlab-ce
# 或指定版本
apt download gitlab-ce=18.7.6-ce.0
```
下載完成後，`.deb` 檔會存放在當前目錄中，再將其傳送至斷網伺服器即可。

### 2. 檔案傳輸
將下載好的檔案傳送到斷網伺服器的 `~/` 資料夾：
```bash
# 範例：從區網電腦傳送
scp gitlab-ce_18.7.6-ce.0_amd64.deb user@192.168.9.129:~/
```

### 3. 執行安裝
切換至檔案目錄並安裝：
```bash
sudo dpkg -i gitlab-ce_18.7.6-ce.0_amd64.deb
```

### 4. 設定 IP 與初始化
編輯設定檔：
```bash
sudo nano /etc/gitlab/gitlab.rb
```
找到 `external_url` 並修改為伺服器 IP：
```ruby
external_url 'http://192.168.9.129'
```
存檔離開 (Ctrl+O, Enter, Ctrl+X) 後執行初始化：
```bash
sudo gitlab-ctl reconfigure
```

### 5. 取得初始密碼
```bash
sudo cat /etc/gitlab/initial_root_password
```
> **注意：** 帳號為 `root`，請於 24 小時內登入並修改密碼。

---

## 🔒 第二部分：設定 HTTPS 加密

### 1. 建立憑證
建立資料夾並產生自簽名憑證 (效期 10 年)：
```bash
sudo mkdir -p /etc/gitlab/ssl
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/gitlab/ssl/192.168.9.129.key \
  -out /etc/gitlab/ssl/192.168.9.129.crt
```

### 2. 修改設定
```bash
sudo nano /etc/gitlab/gitlab.rb
```
修改以下內容：
```ruby
external_url 'https://192.168.9.129'
nginx['redirect_http_to_https'] = true
```

### 3. 套用與防火牆
```bash
sudo gitlab-ctl reconfigure
sudo ufw allow 443/tcp
```

---

## 🌐 第三部分：使用外部 Nginx (取代內建)

若需自訂 Nginx 版本、模組或在同一台伺服器服務多個站台，可停用 GitLab 內建 Nginx 改用外部安裝的 Nginx。

> **完整安裝指南請參考 [4. 安裝nginx.md](4.%20安裝nginx.md)**，以下僅列出 GitLab 端的設定變更。

### 1. 修改 gitlab.rb
```bash
sudo nano /etc/gitlab/gitlab.rb
```
```ruby
# 停用內建 Nginx
nginx['enable'] = false

# 允許外部 Nginx (www-data) 存取 GitLab Workhorse socket
web_server['external_users'] = ['www-data']
```
> `external_url` 維持不變。HTTPS 改由外部 Nginx 設定，不再需要 `nginx['redirect_http_to_https']`。

### 2. 套用設定
```bash
sudo gitlab-ctl reconfigure
```

### 3. 確認 Workhorse socket
```bash
ls -la /var/opt/gitlab/gitlab-workhorse/sockets/socket
```
確認 socket 存在且 `www-data` 群組有讀寫權限後，即可進行外部 Nginx 的反向代理設定。

---

## 🔑 第五部分：Active Directory (LDAP) 登入整合

### 1. 前置確認
開始設定前，請先向 AD 管理員取得以下資訊：

| 項目 | 範例值 | 說明 |
|------|--------|------|
| AD 伺服器 IP | `192.168.9.10` | Domain Controller 的 IP |
| Port | `389` (明文) / `636` (SSL) | LDAP 連線埠 |
| Bind DN | `CN=gitlab_svc,OU=Service Accounts,DC=example,DC=com` | 用於查詢 AD 的服務帳號完整 DN |
| Bind 密碼 | — | 上述服務帳號的密碼 |
| Base DN | `OU=Users,DC=example,DC=com` | 要搜尋使用者的 OU 範圍 |

確認 GitLab 伺服器可連到 AD 伺服器：
```bash
# 測試明文連線 (Port 389)
ldapsearch -x -H ldap://192.168.9.10 -D "CN=gitlab_svc,OU=Service Accounts,DC=example,DC=com" -W -b "OU=Users,DC=example,DC=com" "(sAMAccountName=testuser)"
```
> **提示：** 若系統沒有 `ldapsearch`，可先用 `telnet 192.168.9.10 389` 或 `nc -zv 192.168.9.10 389` 測試連線。

### 2. 編輯 gitlab.rb 設定 LDAP
```bash
sudo nano /etc/gitlab/gitlab.rb
```
在檔案中加入以下 LDAP 設定區塊：
```ruby
gitlab_rails['ldap_enabled'] = true

gitlab_rails['ldap_servers'] = {
  'main' => {
    'label'                         => 'AD Login',
    'host'                          => '192.168.9.10',
    'port'                          => 389,
    'uid'                           => 'sAMAccountName',
    'bind_dn'                       => 'CN=gitlab_svc,OU=Service Accounts,DC=example,DC=com',
    'password'                      => 'your_bind_password',
    'encryption'                    => 'plain',           # 'plain' | 'start_tls' | 'simple_tls'
    'active_directory'              => true,
    'base'                          => 'OU=Users,DC=example,DC=com',
    'allow_username_or_email_login' => true,
    'block_auto_created_users'      => false,             # true = 新使用者需管理員手動啟用
  }
}
```
> **加密模式說明：**
> - `plain` (Port 389)：明文傳輸，適合內網且無憑證環境
> - `start_tls` (Port 389)：在明文連線上啟動 TLS 加密
> - `simple_tls` (Port 636)：直接建立 SSL 加密連線，需將 `port` 改為 `636`

### 3. 套用設定
```bash
sudo gitlab-ctl reconfigure
```

### 4. 驗證 LDAP 連線
```bash
sudo gitlab-rake gitlab:ldap:check
```
預期成功輸出：
```
Checking LDAP ...
LDAP: ... Server: ldap://192.168.9.10
LDAP authentication... Success
```
驗證通過後，登入頁面會出現 **「AD Login」** 分頁，使用者可用 AD 帳號密碼登入。

### 5. 常見問題排查

| 症狀 | 可能原因 | 排查方式 |
|------|----------|----------|
| Connection timed out | 防火牆阻擋或 IP 錯誤 | `nc -zv AD_IP 389` 測試連線 |
| Bind failed / Invalid credentials | Bind DN 或密碼錯誤 | 用 `ldapsearch` 手動測試 Bind |
| 找不到使用者 | Base DN 範圍不對 | 確認使用者所在 OU 是否在 Base DN 之下 |
| SSL 憑證錯誤 | AD 使用自簽名憑證 | 將 CA 憑證放到 `/etc/gitlab/trusted-certs/` 後重新 `reconfigure` |
