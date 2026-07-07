在 Ubuntu Server（17.10 版本之後）中，設定固定 IP 的標準工具是 **Netplan**。它使用 YAML 格式的設定檔，雖然簡潔，但對「縮排」非常挑剔。

以下是設定固定 IP 的四個簡單步驟：

---

### Step 1：確認網路介面名稱
首先，你需要知道你的網路卡叫什麼名字（例如 `eth0` 或 `enp0s3`）。
在終端機輸入：
```bash
ip addr
```
找到那個狀態為 `UP` 且目前有 IP 的介面名稱。

---

### Step 2：尋找 Netplan 設定檔
Netplan 的設定檔通常位在 `/etc/netplan/` 目錄下，檔名通常是 `01-netcfg.yaml` 或 `50-cloud-init.yaml`。
你可以用這條指令查看確切檔名：
```bash
ls /etc/netplan/
```

---

### Step 3：編輯設定檔
使用你喜歡的編輯器（如 `nano`）打開它：
```bash
sudo nano /etc/netplan/你的檔名.yaml
```

將內容修改為以下格式（**請注意：YAML 嚴禁使用 Tab 鍵，請務必使用空白鍵進行縮排**）：

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:               # 這裡填入你在 Step 1 查到的介面名稱
      dhcp4: no           # 關閉 DHCP
      addresses:
        - 192.168.1.100/24 # 你想要設定的固定 IP 與子網路遮罩
      routes:
        - to: default
          via: 192.168.1.1 # 你的預設閘道 (Router IP)
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4] # DNS 伺服器
```



---

### Step 4：套用設定
在儲存並離開編輯器後，先讓 Netplan 測試一下設定檔是否有誤：
```bash
sudo netplan try
```
如果沒有噴出錯誤訊息，直接執行以下指令正式生效：
```bash
sudo netplan apply
```

---

### 如何確認是否成功？
再次輸入 `ip addr`，檢查你的介面是否已經換成剛才設定的 `192.168.1.100`。
此外，可以嘗試 ping 看看外部網路：
```bash
ping -c 4 google.com
```

> **💡 小提醒：**
> 如果你是透過 SSH 連線進行設定，更改 IP 後連線會立即中斷，記得要用**新的 IP** 重新連入喔！

你有遇到任何縮排報錯，或是 `netplan apply` 出現什麼奇怪的訊息嗎？
