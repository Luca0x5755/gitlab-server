Status: Proposed

# GitLab 容器使用內建 Nginx，外部 Nginx 方案退場

## 決定

GitLab 容器直接發佈宿主機 80／443，由容器內建 Nginx 服務，沿用 `/etc/gitlab/ssl` 的自簽憑證。遷移時移除 `gitlab.rb` 中由 `nginx.sh` 寫入的**管理區塊**（`nginx['enable'] = false`、`web_server['external_users']` 等）。`nginx.sh` 的外部 Nginx 流程不再適用於容器版。

## 為什麼

- 外部 Nginx 靠 **Workhorse socket**，而 socket 權限與 `external_users` 在容器內難以處理。
- 只有一個要維護的設定與憑證位置。

## 否決的做法

- **保留宿主機 Nginx 反向代理到容器發佈的埠**：可行，但宿主機上沒有其他站台要承載，徒增一層設定。
- **把 Workhorse socket 掛到宿主機**：UID 與權限在容器邊界上不穩定。

## 後果

- `nginx.sh` 與其測試要在實作時決定刪除或標示為僅適用 deb 安裝。
- 容器內 Nginx 取代後，Runner 的 `clone_url`、`tls-ca-file` 設計（區網 IP:443、憑證本身當 CA）不變。
