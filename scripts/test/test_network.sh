#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# network.sh 的純函式（接縫 B）與行程層級行為（接縫 C）。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
net="$here/../network.sh"

# source 取得函式：main 守門，source 時不啟動選單、不改選項。
. "$net"

# ── valid_cidr（PR-NET-02）──
for c in 192.168.1.100/24 10.0.0.1/8 1.2.3.4/32 1.2.3.4/1; do
    assert_status 0 "合法 CIDR：$c" valid_cidr "$c"
done
for c in "" 192.168.1.100 192.168.1.100/ 192.168.1.100/33 192.168.1.100/0 192.168.1.100/024 192.168.1.100/a 300.1.1.1/24 192.168.1.100/24/1 " 1.2.3.4/24"; do
    assert_nonzero "非法 CIDR：[$c]" valid_cidr "$c"
done

# ── valid_dns_list ──
for d in 8.8.8.8 "8.8.8.8,8.8.4.4" "8.8.8.8, 8.8.4.4" "8.8.8.8 8.8.4.4"; do
    assert_status 0 "合法 DNS：[$d]" valid_dns_list "$d"
done
for d in "" "8.8.8.8," ",8.8.8.8" "8.8.8.8,,8.8.4.4" "8.8.8.8,abc" "8.8.8.256" "dns.example.com"; do
    assert_nonzero "非法 DNS：[$d]" valid_dns_list "$d"
done

# ── render_netplan（PR-NET-03）──
want='network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      dhcp4: no
      addresses:
        - 192.168.1.100/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]'
got="$(render_netplan enp0s3 192.168.1.100/24 192.168.1.1 "8.8.8.8,8.8.4.4")"
assert_eq "$want" "$got" "render_netplan 產出預期的 yaml"
assert_eq "$want" "$(render_netplan enp0s3 192.168.1.100/24 192.168.1.1 "8.8.8.8 8.8.4.4")" "DNS 用空白分隔也正規化成逗號"
assert_eq "no" "$([[ $got == *$'\t'* ]] && echo yes || echo no)" "yaml 不含 Tab"

# ── external_url_host（PR-NET-07 的判斷材料）──
rb="$T_TMP/gitlab.rb"
host_of() { printf '%s\n' "$1" >"$rb"; external_url_host "$rb"; }
assert_eq "10.0.0.5" "$(host_of "external_url 'http://10.0.0.5'")" "http + IP"
assert_eq "gitlab.example.com" "$(host_of "external_url 'https://gitlab.example.com'")" "https + 網域"
assert_eq "10.0.0.5" "$(host_of "external_url \"https://10.0.0.5:8443/\"")" "雙引號、port、結尾斜線"
assert_eq "10.0.0.5" "$(host_of "  external_url = 'http://10.0.0.5'")" "前導空白與等號"
assert_eq "" "$(host_of "# external_url 'http://10.0.0.5'")" "被註解的行不算"
assert_eq "" "$(host_of "nginx['enable'] = false")" "沒有 external_url 回空"
printf "external_url 'http://1.1.1.1'\n# external_url 'http://2.2.2.2'\nexternal_url 'http://3.3.3.3'\n" >"$rb"
assert_eq "3.3.3.3" "$(external_url_host "$rb")" "多處設定取最後一個有效的"
assert_eq "" "$(external_url_host "$T_TMP/no-such-file")" "檔案不存在回空"

# ── needs_followup（PR-NET-07）──
assert_nonzero "主機等於新 IP（含 /24 前綴）不需提醒" needs_followup 10.0.0.5 10.0.0.5/24
assert_nonzero "主機等於新 IP（無前綴）不需提醒" needs_followup 10.0.0.5 10.0.0.5
assert_status 0 "主機是舊 IP 需提醒" needs_followup 10.0.0.4 10.0.0.5/24
assert_status 0 "主機是網域名需提醒" needs_followup gitlab.example.com 10.0.0.5/24
assert_nonzero "找不到 external_url（空主機）不提醒" needs_followup "" 10.0.0.5/24

# ── list_ifaces：解析真實 Ubuntu `ip -o addr` 樣本 ──
fixture='1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
1: lo    inet6 ::1/128 scope host \       valid_lft forever preferred_lft forever
2: enp0s3    inet 192.168.1.50/24 metric 100 brd 192.168.1.255 scope global dynamic enp0s3\       valid_lft 86000sec preferred_lft 86000sec
2: enp0s3    inet6 fe80::a00:27ff:fe4e:66a1/64 scope link \       valid_lft forever preferred_lft forever
3: enp0s8    inet 10.0.0.5/24 brd 10.0.0.255 scope global enp0s8\       valid_lft forever preferred_lft forever
3: enp0s8    inet 10.0.0.6/24 brd 10.0.0.255 scope global secondary enp0s8\       valid_lft forever preferred_lft forever
4: enp0s9    inet6 fe80::a00:27ff:fe4e:66a2/64 scope link \       valid_lft forever preferred_lft forever'
printf '%s\n' "$fixture" >"$T_TMP/ip-o-addr.txt"
ip() { cat "$T_TMP/ip-o-addr.txt"; }
want=$'enp0s3\t192.168.1.50/24\nenp0s8\t10.0.0.5/24,10.0.0.6/24\nenp0s9\t-'
assert_eq "$want" "$(list_ifaces)" "略過 lo 與 IPv6；多位址合併；無 IPv4 以 - 表示"
unset -f ip

# ══ 接縫 C：行程層級 ══════════════════════════════════════════════════════════
# 建立一個沙盒：假的 apt／ip／netplan／ping 放在 PATH 最前面，所有呼叫記進 $STUB_LOG。
# 這只證明「腳本在什麼條件下呼叫什麼」，不證明真實 netplan 接受產出的 yaml。
setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/netplan"
    STUB_LOG="$SB/stub.log"
    : >"$STUB_LOG"
    export STUB_LOG
    cp "$T_TMP/ip-o-addr.txt" "$SB/ip-o-addr.txt"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" ip 'if [ "$1 $2" = "-o addr" ]; then cat "'"$SB"'/ip-o-addr.txt"; else echo "ip addr output for $*"; fi'
    make_stub "$SB/bin" netplan 'case "$1" in generate) exit "${STUB_GENERATE_RC:-0}" ;; *) exit 0 ;; esac'
    make_stub "$SB/bin" ping 'echo "PING $*"; exit "${STUB_PING_RC:-0}"'
}

# run_net <stdin 內容> [環境變數 KEY=VAL…]：在沙盒中執行 network.sh（無參數）。
run_net() {
    local input="$1"
    shift
    printf '%b' "$input" | env -u SSH_CONNECTION PATH="$SB/bin:$PATH" NETPLAN_DIR="$SB/netplan" GITLAB_RB="$SB/gitlab.rb" \
        OPS_FAKE_UID=0 PING_COUNT=2 "$@" bash "$net" 2>&1
}

setup_sandbox menu

# ── 無參數（PR-COM-01）──
assert_status 2 "帶參數即拒絕" env PATH="$SB/bin:$PATH" bash "$net" foo
assert_status 2 "空字串參數也拒絕" env PATH="$SB/bin:$PATH" bash "$net" ""
assert_status 2 "多個參數也拒絕" env PATH="$SB/bin:$PATH" bash "$net" -h --help
out="$(run_net 'q\n')"; rc=$?
assert_contains "$out" "說明" "選單含「說明」"
assert_contains "$out" "常見問題排查" "選單含「常見問題排查」"
assert_contains "$out" "【GitLab 伺服器】" "選單項目標示執行機器（PR-COM-04）"
assert_status 0 "q 離開結束碼 0" bash -c "printf 'q\n' | env PATH='$SB/bin:$PATH' NETPLAN_DIR='$SB/netplan' bash '$net'"
assert_status 0 "stdin EOF 離開結束碼 0" bash -c "env PATH='$SB/bin:$PATH' bash '$net' </dev/null"

# ── 說明與排查（PR-COM-11），只斷言來源文件的標記字串存在 ──
help="$(run_net '2\nq\n')"
assert_contains "$help" "Netplan" "說明提到 Netplan"
assert_contains "$help" "Tab" "說明提醒 YAML 嚴禁 Tab"
assert_contains "$help" "SSH" "說明提醒 SSH 連線會中斷"
assert_contains "$help" "ip addr" "說明含確認步驟"
fix="$(run_net '3\nq\n')"
assert_contains "$fix" "縮排" "排查含縮排錯誤"
assert_contains "$fix" "cloud-init" "排查含 cloud-init 覆寫"
assert_contains "$fix" "備份" "排查含如何還原備份"

# ── 機器檢查：只要 Ubuntu 工具，不要求 /opt/gitlab；缺時指向 GitLab 伺服器 ──
chk() { # chk <有哪些指令> ：重新定義探測函式後呼叫 network.sh 的機器檢查
    ( have_cmd() { case " $have " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
      gitlab_installed() { return 1; }
      have="$1"; net_check_machine ) 2>&1
}
assert_status 0 "apt／netplan／ip 齊備且沒裝 GitLab 也放行" chk "apt netplan ip"
out="$(chk "apt ip")" || true
assert_contains "$out" "netplan" "缺 netplan 時點名"
assert_contains "$out" "【GitLab 伺服器】" "缺 netplan 時指向 GitLab 伺服器"
out="$(chk "netplan ip")" || true
assert_contains "$out" "【GitLab 伺服器】" "缺 apt 時指向 GitLab 伺服器"

# ══ 設定流程 ══════════════════════════════════════════════════════════════════
# 沙盒內放兩個舊 yaml，並攔截 chmod 以便驗證權限（NTFS 上 stat 看不出）。
setup_flow() { # setup_flow <名稱>
    setup_sandbox "$1"
    printf 'network:\n  version: 2\n  # 舊設定 A\n' >"$SB/netplan/50-cloud-init.yaml"
    printf 'network:\n  version: 2\n  # 舊設定 B\n' >"$SB/netplan/00-installer-config.yaml"
    mkdir -p "$SB/orig"
    cp "$SB/netplan/"*.yaml "$SB/orig/"
    make_stub "$SB/bin" chmod '[ -z "${STUB_CHMOD_FAIL:-}" ] || exit 1; exec /usr/bin/chmod "$@"'
    rm -f "$OPS_ENV_FILE"
}
# 選單 1 → 介面 2（enp0s8）→ IP/CIDR → 閘道 → DNS → 確認
flow() { # flow <確認字串：yes|空> [環境變數…]；輸入檔可由 FLOW_CIDR 等覆寫
    run_net "1\n2\n${FLOW_CIDR:-10.0.0.5/24}\n${FLOW_GW:-10.0.0.1}\n${FLOW_DNS:-8.8.8.8,8.8.4.4}\n$1\nq\n" "${@:2}"
}
yamls() { ( cd "$SB/netplan" && ls -- *.yaml 2>/dev/null | tr '\n' ' ' ); }

# ── 成功套用：netplan 最終狀態（PR-NET-03）──
setup_flow ok
out="$(flow 'yes\n')"
log="$(cat "$STUB_LOG")"
assert_eq "01-gitlab-static.yaml " "$(yamls)" "套用後 NETPLAN_DIR 只剩新檔這一個有效 *.yaml"
assert_file_eq "$SB/orig/50-cloud-init.yaml" "$(ls "$SB"/netplan/50-cloud-init.yaml.bak-* | head -n1)" "50-cloud-init 備份內容等於舊檔"
assert_file_eq "$SB/orig/00-installer-config.yaml" "$(ls "$SB"/netplan/00-installer-config.yaml.bak-* | head -n1)" "installer-config 備份內容等於舊檔"
bad=no; for f in "$SB"/netplan/*.bak-*; do [[ $f == *.yaml ]] && bad=yes; done
assert_eq "no" "$bad" "備份檔名不以 .yaml 結尾（netplan 不會載入）"
assert_eq "$(render_netplan enp0s8 10.0.0.5/24 10.0.0.1 8.8.8.8,8.8.4.4)" "$(cat "$SB/netplan/01-gitlab-static.yaml")" "新 yaml 內容正確且用所選介面"
assert_contains "$log" "chmod 600 $SB/netplan/01-gitlab-static.yaml" "新 yaml 設為 600"
[[ $(uname -s) != Linux ]] || assert_eq "600" "$(stat -c %a "$SB/netplan/01-gitlab-static.yaml")" "新 yaml 實際權限 600"
gen_line="$(grep -n '^netplan generate' "$STUB_LOG" | head -n1 | cut -d: -f1)"
app_line="$(grep -n '^netplan apply' "$STUB_LOG" | head -n1 | cut -d: -f1)"
assert_eq "yes" "$([ -n "$gen_line" ] && [ -n "$app_line" ] && [ "$gen_line" -lt "$app_line" ] && echo yes || echo no)" "先 generate 再 apply"
assert_contains "$out" "enp0s3" "列出網卡 enp0s3"
assert_contains "$out" "192.168.1.50/24" "列出目前 IP"
assert_contains "$out" "10.0.0.5/24,10.0.0.6/24" "單介面多位址一併列出"
assert_contains "$log" "ip addr show enp0s8" "套用後顯示該介面的 ip addr"
assert_contains "$log" "ping -c 2 10.0.0.1" "ping 的對象是使用者輸入的閘道"
assert_not_contains "$log" "google" "不 ping 外部網站"
assert_contains "$(cat "$OPS_ENV_FILE")" "NET_GATEWAY=10.0.0.1" "答案存入參數檔"

# ── generate 失敗：還原且不套用（PR-NET-04）──
setup_flow genfail
out="$(flow 'yes\n' STUB_GENERATE_RC=1)"
log="$(cat "$STUB_LOG")"
assert_file_eq "$SB/orig/50-cloud-init.yaml" "$SB/netplan/50-cloud-init.yaml" "generate 失敗：原路徑 byte 等於舊檔 A"
assert_file_eq "$SB/orig/00-installer-config.yaml" "$SB/netplan/00-installer-config.yaml" "generate 失敗：原路徑 byte 等於舊檔 B"
assert_eq "no" "$([ -e "$SB/netplan/01-gitlab-static.yaml" ] && echo yes || echo no)" "generate 失敗：無殘留新 yaml"
assert_not_contains "$log" "netplan apply" "generate 失敗：不呼叫 apply"
assert_contains "$out" "generate" "generate 失敗：訊息說明驗證失敗"

# ── 未確認不動任何東西（PR-COM-03）──
setup_flow eof
out="$(run_net "1\n2\n10.0.0.5/24\n10.0.0.1\n8.8.8.8\n")"   # 確認處遇到 EOF
log="$(cat "$STUB_LOG")"
assert_eq "00-installer-config.yaml 50-cloud-init.yaml " "$(yamls)" "確認處 EOF：netplan 目錄不變"
assert_file_eq "$SB/orig/50-cloud-init.yaml" "$SB/netplan/50-cloud-init.yaml" "確認處 EOF：舊檔未動"
assert_not_contains "$log" "netplan" "確認處 EOF：沒呼叫任何 netplan"
setup_flow no
flow 'no\n' >/dev/null
assert_not_contains "$(cat "$STUB_LOG")" "netplan" "回答 no：沒呼叫任何 netplan"

# ── 非 root：什麼都不動 ──
setup_flow nonroot
out="$(flow 'yes\n' OPS_FAKE_UID=1000)"
assert_contains "$out" "root" "非 root：提示需要 root"
assert_eq "00-installer-config.yaml 50-cloud-init.yaml " "$(yamls)" "非 root：netplan 目錄不變"

# ── 輸入驗證：不合格重問（PR-NET-02）──
setup_flow retry
out="$(run_net "1\n2\nbad\n10.0.0.5/24\n10.0.0.999\n10.0.0.1\nnot-dns\n8.8.8.8\nyes\nq\n")"
assert_contains "$out" "格式不符" "輸入不合格會提示"
assert_contains "$(cat "$SB/netplan/01-gitlab-static.yaml")" "- 10.0.0.5/24" "重問後以合格的值產生 yaml"
setup_flow badiface
out="$(run_net "1\n9\nq\n")"
assert_eq "00-installer-config.yaml 50-cloud-init.yaml " "$(yamls)" "選了不存在的介面編號：不動任何檔案"

# ── SSH 警告（PR-NET-05）──
setup_flow ssh
out="$(flow 'no\n' SSH_CONNECTION="1.2.3.4 5555 5.6.7.8 22")"
assert_contains "$out" "偵測到 SSH_CONNECTION" "有 SSH_CONNECTION 時警告"
assert_contains "$out" "回滾" "警告提到回滾風險"
setup_flow nossh
out="$(flow 'no\n')"
assert_not_contains "$out" "偵測到 SSH_CONNECTION" "沒有 SSH_CONNECTION 時不警告"

# ── ping 失敗只警告（PR-NET-06）且 external_url 提醒照出（PR-NET-07）──
setup_flow pingfail
printf "external_url 'http://10.0.0.4'\n" >"$SB/gitlab.rb"
cp "$SB/gitlab.rb" "$SB/gitlab.rb.orig"
out="$(flow 'yes\n' STUB_PING_RC=1)"
assert_contains "$out" "不通" "ping 失敗有警告"
assert_eq "yes" "$([ -e "$SB/netplan/01-gitlab-static.yaml" ] && echo yes || echo no)" "ping 失敗不中止、不還原"
assert_contains "$out" "需重跑" "external_url 主機與新 IP 不一致：列出需重跑項目"
assert_contains "$out" "憑證" "提醒包含憑證"
assert_contains "$out" "server_name" "提醒包含 Nginx server_name"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "不自動修改 gitlab.rb"

setup_flow match
printf "external_url 'https://10.0.0.5:8443'\n" >"$SB/gitlab.rb"
out="$(flow 'yes\n')"
assert_not_contains "$out" "需重跑" "主機等於新 IP：不提醒"

setup_flow domain
printf "external_url 'https://gitlab.example.com'\n" >"$SB/gitlab.rb"
out="$(flow 'yes\n')"
assert_contains "$out" "需重跑" "主機是網域名：照字面列出提醒"

setup_flow norb
out="$(flow 'yes\n')"
assert_not_contains "$out" "需重跑" "沒有 gitlab.rb：不提醒"

# ── 寫新檔途中失敗（例如 chmod 失敗）：舊檔不可丟失 ──
setup_flow writefail
out="$(flow 'yes\n' STUB_CHMOD_FAIL=1)"
log="$(cat "$STUB_LOG")"
assert_file_eq "$SB/orig/50-cloud-init.yaml" "$SB/netplan/50-cloud-init.yaml" "寫入新檔失敗：舊檔 A 已還原"
assert_file_eq "$SB/orig/00-installer-config.yaml" "$SB/netplan/00-installer-config.yaml" "寫入新檔失敗：舊檔 B 已還原"
assert_eq "no" "$([ -e "$SB/netplan/01-gitlab-static.yaml" ] && echo yes || echo no)" "寫入新檔失敗：無殘留新 yaml"
assert_not_contains "$log" "netplan apply" "寫入新檔失敗：不呼叫 apply"
