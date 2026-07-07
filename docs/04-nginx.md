## 🌐 離線安裝外部 Nginx (取代 GitLab 內建)

> **適用情境：** 需要自訂 Nginx 組態、使用特定版本或模組，或在同一台伺服器上以 Nginx 服務多個站台。
>
> **前置條件：** GitLab CE 已安裝完成且至少執行過一次 `sudo gitlab-ctl reconfigure`。

---

### 1. 查看 GitLab 內建 Nginx 版本 (參考用)

```bash
sudo /opt/gitlab/embedded/sbin/nginx -V
```

> 可據此決定外部 Nginx 要安裝的版本，以確保功能相容。

---

### 2. 準備離線套件 (有網路的電腦)

在**相同 Ubuntu 24.04 (Noble)** 的有網路電腦上操作。

#### 加入 Nginx 官方 mainline 套件來源

參考 [Nginx 官方安裝說明](http://nginx.org/en/linux_packages.html#Ubuntu)：
```bash
# 匯入 Nginx 官方簽名金鑰
curl -fsSL https://nginx.org/keys/nginx_signing.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

# 加入 mainline 版本來源 (最新功能版)
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu noble nginx" \
  | sudo tee /etc/apt/sources.list.d/nginx.list

sudo apt-get update
```

確認可用版本：
```bash
apt-cache madison nginx
```

#### 下載 Nginx 及相依套件
```bash
mkdir -p ~/nginx-offline && cd ~/nginx-offline

# 下載最新 mainline 版本及所有相依
apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests \
  --no-conflicts --no-breaks --no-replaces --no-enhances nginx \
  2>/dev/null | grep "^\w" | sort -u)
```

確認下載結果：
```bash
ls *.deb | wc -l   # 通常約 15–25 個套件
```

打包並清理：
```bash
tar czf nginx-offline.tar.gz *.deb
rm -f *.deb
```

> **提示：** `apt-get download` 不受本機已安裝狀態影響，會下載所有列出的 `.deb`，可安心在已裝有 Nginx 的電腦上執行。

---

### 3. 傳輸至離線伺服器

```bash
scp nginx-offline.tar.gz user@192.168.9.129:~/
```

---

### 4. 安裝 Nginx

```bash
mkdir -p ~/nginx-offline && cd ~/nginx-offline
tar xzf ~/nginx-offline.tar.gz

# 安裝所有套件 (已安裝的相依會自動略過)
sudo dpkg -i *.deb
```

若出現相依性錯誤，檢查遺漏的套件名稱並回到有網路的電腦補下載：
```bash
# 查看哪些套件有問題
dpkg -l | grep -E "^i[^i]" | grep nginx
sudo dpkg --configure -a
```

驗證安裝：
```bash
nginx -v
sudo systemctl status nginx
```

---

### 5. 停用 GitLab 內建 Nginx

編輯 GitLab 設定：
```bash
sudo nano /etc/gitlab/gitlab.rb
```

加入或修改以下項目：
```ruby
# 停用內建 Nginx
nginx['enable'] = false

# 允許外部 Nginx 存取 GitLab Workhorse socket
# Nginx 官方套件的 worker 使用者是 'nginx'；Ubuntu 預設庫則是 'www-data'
web_server['external_users'] = ['nginx']
```

> **注意：** `external_url` 維持不變（可以是 IP 或網域名稱，例如 `'https://192.168.9.129'` 或 `'https://gitlab.example.com'`）。此設定決定 GitLab 產生的連結（clone URL、通知信等），只要與使用者實際訪問的網址一致即可。若使用網域名稱，步驟 7 的 `server_name` 及 SSL 憑證也須對應該網域。

套用設定：
```bash
sudo gitlab-ctl reconfigure
```

確認 Workhorse socket 已建立且權限正確：
```bash
sudo ls -la /var/opt/gitlab/gitlab-workhorse/sockets/socket
```

---

### 6. 建立 SSL 憑證 (HTTPS)

若使用 HTTPS（推薦），建立自簽名憑證（效期 10 年）：
```bash
sudo mkdir -p /etc/nginx/ssl

sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/192.168.9.129.key \
  -out /etc/nginx/ssl/192.168.9.129.crt
```

> 若已在 `/etc/gitlab/ssl/` 建立過憑證，可直接複製使用：
> ```bash
> sudo cp /etc/gitlab/ssl/192.168.9.129.crt /etc/nginx/ssl/
> sudo cp /etc/gitlab/ssl/192.168.9.129.key /etc/nginx/ssl/
> ```

---

### 7. 設定 Nginx 反向代理

建立 GitLab 站台設定檔：
```bash
sudo nano /etc/nginx/conf.d/gitlab.conf
```

#### HTTPS 設定 (推薦)

```nginx
upstream gitlab-workhorse {
    server unix:/var/opt/gitlab/gitlab-workhorse/sockets/socket fail_timeout=0;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP → HTTPS 自動導向
server {
    listen 80;
    server_name 192.168.9.129;  # ← 改為你的網域或 IP
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name 192.168.9.129;  # ← 改為你的網域或 IP（須與上方一致）

    ssl_certificate     /etc/nginx/ssl/192.168.9.129.crt;  # ← 改為你的憑證路徑
    ssl_certificate_key /etc/nginx/ssl/192.168.9.129.key;   # ← 改為你的私鑰路徑
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # 不限制上傳大小 (Git LFS / 大型 repo)
    client_max_body_size 0;
    chunked_transfer_encoding on;

    location / {
        proxy_pass http://gitlab-workhorse;

        proxy_set_header Host              $http_host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Ssl   on;

        proxy_read_timeout    3600;
        proxy_connect_timeout 300;
        proxy_redirect        off;

        # WebSocket 支援 (Action Cable / 即時功能)
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

#### HTTP 設定 (僅供測試或內網無加密需求)

<details>
<summary>展開 HTTP 設定</summary>

```nginx
upstream gitlab-workhorse {
    server unix:/var/opt/gitlab/gitlab-workhorse/sockets/socket fail_timeout=0;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name 192.168.9.129;

    client_max_body_size 0;
    chunked_transfer_encoding on;

    location / {
        proxy_pass http://gitlab-workhorse;

        proxy_set_header Host              $http_host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout    3600;
        proxy_connect_timeout 300;
        proxy_redirect        off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

</details>

---

### 8. 啟用站台與重啟

先確認 GitLab 內建 Nginx 已停用，避免 port 衝突：
```bash
# 確認 gitlab.rb 設定正確（應輸出兩行：nginx['enable'] = false 與 external_users）
sudo grep -E "nginx\['enable'\]|external_users" /etc/gitlab/gitlab.rb | grep -v '^\s*#'

# 重新套用設定
sudo gitlab-ctl reconfigure

# 確認內建 Nginx 已停止（應顯示 down 或找不到服務）
sudo gitlab-ctl status nginx

# 確認 80/443 port 已釋放（應無輸出）
sudo ss -tlnp | grep -E ':80|:443'
```

確認 port 已釋放後，啟動外部 Nginx：
```bash
# 移除預設站台設定
sudo rm -f /etc/nginx/conf.d/default.conf

# 測試設定檔語法
sudo nginx -t

# 啟動 Nginx
sudo systemctl restart nginx
sudo systemctl enable nginx
```

---

### 9. 防火牆設定

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

---

### 10. 驗證

```bash
# 確認 Nginx 運行中
sudo systemctl status nginx

# 確認 GitLab 服務正常
sudo gitlab-ctl status

# 測試 HTTPS 連線
curl -kI https://192.168.9.129
```

瀏覽器訪問 `https://192.168.9.129`，應可正常看到 GitLab 登入頁面。

---

### 常見問題

| 症狀 | 可能原因 | 排查方式 |
|------|----------|----------|
| 502 Bad Gateway | Workhorse socket 不存在或未啟動 | `sudo gitlab-ctl status` 確認 workhorse 運行中；`ls -la /var/opt/gitlab/gitlab-workhorse/sockets/socket` 確認 socket 存在 |
| Permission denied | Nginx worker 使用者無權存取 socket | 用 `ps aux | grep 'nginx: worker'` 確認實際使用者（官方套件為 `nginx`），確認 `web_server['external_users']` 設定一致並重新 `reconfigure` |
| 413 Request Entity Too Large | Nginx 限制上傳大小 | 確認 `client_max_body_size 0;` 已寫入站台設定 |
| WebSocket 連線失敗 | 缺少 Upgrade header | 確認 `map $http_upgrade` 區塊與 `proxy_set_header Upgrade` 皆已設定 |
| Nginx 無法啟動 | Port 衝突或設定檔語法錯誤 | `sudo nginx -t` 檢查語法；`sudo ss -tlnp | grep ':80'` 檢查是否有其他程式佔用 Port |
| 網頁可開但 Git push/pull 失敗 | proxy_read_timeout 過短 | 確認 `proxy_read_timeout 3600;` 已設定，大型 repo 操作需要較長的 timeout |

---

### 切換回內建 Nginx

若需還原為 GitLab 內建 Nginx：
```bash
sudo nano /etc/gitlab/gitlab.rb
```
```ruby
# 註解或移除以下兩行
# nginx['enable'] = false
# web_server['external_users'] = ['www-data']
```
```bash
# 停用外部 Nginx
sudo systemctl stop nginx
sudo systemctl disable nginx

# 重新啟用內建 Nginx
sudo gitlab-ctl reconfigure
```
