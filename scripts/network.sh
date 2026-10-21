#!/usr/bin/env bash
# 固定 IP（Netplan）選單腳本：列網卡、輸入 IP／閘道／DNS、備份並產生 netplan yaml、驗證後套用。
# 只有互動選單，不收參數。說明與排查見選單項目。
#
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得純函式而不啟動選單。
#
# 可由環境變數覆寫的路徑（供測試用，預設為正式路徑；它們不是命令列參數）：
#   NETPLAN_DIR（/etc/netplan）、GITLAB_RB（/etc/gitlab/gitlab.rb）、PING_COUNT（4）。

_net_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_net_dir/lib/common.sh"

NET_NEW_YAML="01-gitlab-static.yaml"

# ── 驗證與解析（純函式）──────────────────────────────────────────────────────

# IP/CIDR：合法 IPv4 加上 /1～/32（不接受 /0 與前導零）。
valid_cidr() {
    local ip="${1%%/*}" prefix="${1#*/}"
    [[ $1 == */* ]] || return 1
    valid_ipv4 "$ip" || return 1
    [[ $prefix =~ ^[1-9][0-9]?$ ]] && [ "$prefix" -le 32 ]
}

# DNS 清單：逗號或空白分隔的 IPv4，至少一個，不接受空項目。
valid_dns_list() {
    local list="${1//,/ }" item n=0 stripped="${1// /}"
    [[ $stripped != ,* && $stripped != *, && $stripped != *,,* ]] || return 1
    for item in $list; do
        valid_ipv4 "$item" || return 1
        n=$((n + 1))
    done
    [ "$n" -gt 0 ]
}

# 產生 netplan yaml（只用空白縮排，絕不輸出 Tab）。
# 用法：render_netplan <介面> <IP/CIDR> <閘道> <DNS 清單，逗號或空白分隔>
render_netplan() {
    local iface="$1" cidr="$2" gw="$3" dns="${4//,/ }" joined="" d
    for d in $dns; do joined="${joined:+$joined, }$d"; done
    cat <<YAML
network:
  version: 2
  renderer: networkd
  ethernets:
    $iface:
      dhcp4: no
      addresses:
        - $cidr
      routes:
        - to: default
          via: $gw
      nameservers:
        addresses: [$joined]
YAML
}

# 取出 gitlab.rb 中最後一個有效 external_url 的主機（不含協定、port、路徑）；無則回空。
external_url_host() {
    local file="$1" url
    [ -f "$file" ] || return 0
    url="$(sed -n -E "s/^[[:space:]]*external_url[[:space:]]*=?[[:space:]]*['\"]([^'\"]*)['\"].*$/\1/p" "$file" | tail -n1)"
    url="${url#*://}"
    url="${url%%/*}"
    url="${url##*@}"
    echo "${url%%:*}"
}

# 新 IP 與 external_url 主機不一致就需要提醒（回 0）。
# 主機是網域名時一律提醒；找不到 external_url（空主機）不提醒。
needs_followup() {
    local host="$1" new_ip="${2%%/*}"
    [ -n "$host" ] && [ "$host" != "$new_ip" ]
}

# 列出網卡與其 IPv4：每行「介面<Tab>位址1,位址2」，沒有 IPv4 以 - 表示；略過 lo。
list_ifaces() {
    ip -o addr 2>/dev/null | awk '
        $2 != "lo" {
            if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 }
            if ($3 == "inet") a[$2] = (a[$2] ? a[$2] "," : "") $4
        }
        END { for (i = 1; i <= n; i++) print order[i] "\t" (a[order[i]] ? a[order[i]] : "-") }'
}

# ── 機器檢查 ─────────────────────────────────────────────────────────────────

# 改固定 IP 通常發生在安裝 GitLab 之前，所以只要求 Ubuntu 工具、不要求 /opt/gitlab。
# （偏離 PR-COM-04 字面，已記於 docs/decision-log.md。）
net_check_machine() { require_machine ubuntu netplan ip; }

# ── 說明與排查 ────────────────────────────────

show_help() {
    cat <<'TXT'
【說明】固定 IP 與 Netplan
Ubuntu Server（17.10 之後）設定固定 IP 的標準工具是 Netplan。它讀 /etc/netplan/ 下的
YAML 設定檔，對縮排非常挑剔：YAML 嚴禁使用 Tab，只能用空白。

本腳本代你完成以下步驟：
  1. 用 ip addr 列出網卡與目前 IP，讓你選介面（找狀態 UP 且有 IP 的那張）。
  2. 詢問 IP/CIDR（例 192.168.1.100/24）、預設閘道、DNS，並檢查格式。
  3. 備份 /etc/netplan 下既有的 yaml（檔名加 .bak-時間戳，netplan 不會載入），
     再寫入新的 yaml（只用空白縮排，權限 600）。
  4. 先跑 netplan generate 驗證；失敗就還原舊檔，不套用。
  5. 輸入 yes 後才 netplan apply，並顯示 ip addr、ping 閘道確認。

注意：
  - 經由 SSH 連線操作時，改 IP 後連線會立即中斷，要用「新的 IP」重新連入；
    若新設定有誤，可能無法再連回，請先確認有主控台可以救援。
  - 改 IP 後 GitLab 的 external_url、憑證、Nginx server_name 若仍指向舊 IP，
    本腳本只會列出需重跑的項目，不會自動修改。
  - 設定前請先備妥新 IP、閘道與 DNS。
TXT
}

show_troubleshooting() {
    cat <<'TXT'
【常見問題排查】
  縮排或格式錯誤：netplan generate 會報錯。YAML 只能用空白縮排、不可有 Tab；
    本腳本產生的檔案已符合，若你手動改過，請依備份檔（*.yaml.bak-時間戳）比對。
  generate 失敗：腳本已自動還原原本的 yaml，網路設定沒有被動到；
    看上方錯誤訊息，通常是 IP/CIDR、閘道或 DNS 填錯。
  套用後 ip addr 看不到新 IP：確認選對介面；用 ip addr 看介面是否 UP。
  ping 閘道不通：確認閘道位址與子網路遮罩正確、網路線與交換器正常。
    （伺服器多半不能連外，所以只 ping 閘道，不 ping 外部網站。）
  重開機後 IP 又變回去：若 /etc/netplan/50-cloud-init.yaml 是 cloud-init 產生的，
    它可能在開機時重新產生；需在 /etc/cloud/cloud.cfg.d/ 加一個檔案內容為
    network: {config: disabled} 來停用 cloud-init 的網路設定。
  想還原舊設定：把 /etc/netplan/ 內想還原的 *.yaml.bak-時間戳 改名回 *.yaml，
    移走 01-gitlab-static.yaml，再執行 netplan apply。
  SSH 斷線後連不上：改由主控台（console）登入，用上面的還原步驟處理。
TXT
}

# ── 設定流程 ─────────────────────────────────────────────────────────────────

# 備份並停用目錄內所有既有 *.yaml，寫入新 yaml，generate 驗證，通過才 apply。
# 備份檔名為「<原檔名>.bak-<時間戳>」，不以 .yaml 結尾，netplan 不會載入它。
# generate 或 apply 失敗就把舊檔原樣還原、移除新 yaml。回 0＝已套用；非 0＝已還原。
# 用法：apply_netplan <介面> <IP/CIDR> <閘道> <DNS 清單>
apply_netplan() {
    local dir="${NETPLAN_DIR:-/etc/netplan}" new ts f
    local olds=()
    new="$dir/$NET_NEW_YAML"
    ts="$(date +%Y%m%d%H%M%S)"
    # 本函式在 `|| return` 條件中被呼叫，set -e 會失效，所以每個會失敗的步驟都明確檢查。
    for f in "$dir"/*.yaml; do
        [ -e "$f" ] && olds+=("$f")
    done
    # 先全部備份，成功後才移除原檔：備份途中失敗時原檔都還在。
    for f in "${olds[@]}"; do
        if ! cp -p "$f" "$f.bak-$ts"; then
            echo "✗ 備份 $f 失敗，未做任何變更。" >&2
            return 1
        fi
        echo "  已備份：$f.bak-$ts"
    done
    for f in "${olds[@]}"; do rm -f "$f"; done
    if ! { (umask 077; render_netplan "$@" >"$new") && chmod 600 "$new"; }; then
        echo "✗ 寫入 $new 失敗；已還原原本的設定。" >&2
        net_restore "$new" "$ts" "${olds[@]}"
        return 1
    fi

    if ! netplan generate; then
        echo "✗ netplan generate 驗證失敗，不套用；已還原原本的設定。" >&2
        net_restore "$new" "$ts" "${olds[@]}"
        return 1
    fi
    if ! netplan apply; then
        echo "✗ netplan apply 失敗；已還原原本的設定檔（請再手動執行 netplan apply，並從主控台確認網路）。" >&2
        net_restore "$new" "$ts" "${olds[@]}"
        return 2
    fi
}

# net_restore <新檔> <時間戳> <原檔…>：移除新檔，把備份複製回原路徑。
net_restore() {
    local new="$1" ts="$2" f
    shift 2
    rm -f "$new"
    for f in "$@"; do cp -p "$f.bak-$ts" "$f" || echo "✗ 還原 $f 失敗，請手動由 $f.bak-$ts 還原。" >&2; done
}

# 套用後提醒：external_url 的主機與新 IP 不一致時列出需重跑的項目；只提醒，不修改任何檔案。
print_followup() { # print_followup <新 IP/CIDR>
    local rb="${GITLAB_RB:-/etc/gitlab/gitlab.rb}" host
    host="$(external_url_host "$rb")"
    needs_followup "$host" "$1" || return 0
    cat <<TXT

⚠ $rb 的 external_url 主機是「$host」，與新 IP ${1%%/*} 不一致。
  以下項目需重跑或更新，請自行處理（本腳本不會自動修改）：
    - gitlab.rb 的 external_url，然後 gitlab-ctl reconfigure
    - HTTPS 憑證（SAN 要含新 IP 或網域）
    - 外部 Nginx 的 server_name 與憑證路徑（若有使用外部 Nginx）
TXT
}

configure_ip() {
    local ifaces=() names=() addrs=() line n i choice iface cidr gw dns
    require_root
    while IFS= read -r line; do ifaces+=("$line"); done < <(list_ifaces)
    [ "${#ifaces[@]}" -gt 0 ] || die "找不到任何網路介面。"
    echo "網路介面與目前 IP："
    i=0
    for line in "${ifaces[@]}"; do
        i=$((i + 1))
        names+=("${line%%$'\t'*}")
        addrs+=("${line#*$'\t'}")
        printf '  %d) %-12s %s\n' "$i" "${names[$((i - 1))]}" "${addrs[$((i - 1))]}"
    done
    n="${#ifaces[@]}"
    choice=""
    read -r -p "選擇介面編號：" choice || die "未選擇介面。"
    if ! [[ $choice =~ ^[1-9][0-9]*$ ]] || [ "$choice" -gt "$n" ]; then die "無效的介面編號：$choice"; fi
    iface="${names[$((choice - 1))]}"

    cidr="$(ask_param NET_CIDR "IP/CIDR（例 192.168.1.100/24）" "" valid_cidr)"
    gw="$(ask_param NET_GATEWAY "預設閘道" "" valid_ipv4)"
    dns="$(ask_param NET_DNS "DNS（逗號分隔，可多個）" "" valid_dns_list)"

    echo
    echo "將寫入 ${NETPLAN_DIR:-/etc/netplan}/$NET_NEW_YAML："
    render_netplan "$iface" "$cidr" "$gw" "$dns" | sed 's/^/    /'
    echo "並把該目錄內既有的 *.yaml 全部備份後停用（含其他介面的設定，需要的話請事後自行補回）。"
    if [ -n "${SSH_CONNECTION:-}" ]; then
        echo
        echo "⚠ 偵測到 SSH_CONNECTION：目前是經由 SSH 連線操作。套用後連線會立即中斷，"
        echo "  須用新 IP 重新連入；若新設定有誤，有無法連回、需要回滾的風險，請先確認有主控台可以救援。"
    fi
    confirm "確定套用？" || { echo "已取消，未做任何變更。"; return 0; }

    apply_netplan "$iface" "$cidr" "$gw" "$dns" || return 1
    echo
    echo "── ip addr ──"
    ip addr show "$iface"
    echo "── ping 閘道 $gw ──"
    ping -c "${PING_COUNT:-4}" "$gw" || echo "⚠ ping 閘道 $gw 不通：設定已套用，不中止；請檢查閘道位址、遮罩與實體網路。"
    print_followup "$cidr"
}

# ── 選單 ─────────────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== 固定 IP（Netplan）===
  1) 設定固定 IP         【GitLab 伺服器】
  2) 說明                【GitLab 伺服器】
  3) 常見問題排查        【GitLab 伺服器】
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) configure_ip ;;
        2) show_help ;;
        3) show_troubleshooting ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_net_dir")"
    net_check_machine
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
