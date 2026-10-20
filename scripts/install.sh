#!/usr/bin/env bash
# GitLab 安裝選單腳本：加來源、列版本、下載 .deb、scp 傳送、dpkg 安裝、設定 external_url、
# 顯示初始 root 密碼。只有互動選單，不收參數。來源文件：docs/01-install-and-config.md 第一部分
# （HTTPS、LDAP 由後續票追加進本選單；外部 Nginx 屬於 nginx.sh）。
#
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得純函式而不啟動選單。
#
# 可由環境變數覆寫的路徑（供測試用，預設為正式路徑；它們不是命令列參數）：
#   GITLAB_RB（/etc/gitlab/gitlab.rb）、GITLAB_INITIAL_PW（/etc/gitlab/initial_root_password）、
#   OS_RELEASE_FILE（/etc/os-release）、GITLAB_OPT_DIR（/opt/gitlab）。

_ins_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_ins_dir/lib/common.sh"

INS_REPO_SCRIPT_URL="https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh"
INS_URL_BLOCK="install_external_url"

# ── 驗證與解析（純函式）──────────────────────────────────────────────────────

# 版本字串會進 `apt download gitlab-ce=<版本>`，所以只收嚴格格式（擋注入）。
valid_gitlab_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+-ce\.[0-9]+$ ]]; }

# 解析 `apt-cache madison gitlab-ce` 的輸出：每行一個版本，保留輸入順序、去重（保留首次出現）。
# 只收套件名為 gitlab-ce 且版本合法的行；其餘（gitlab-ee、空行、雜訊）略過。
parse_madison() {
    local name ver rest
    local -A seen=()
    while IFS='|' read -r name ver rest || [ -n "$name" ]; do
        name="${name//[[:space:]]/}"
        ver="${ver//[[:space:]]/}"
        [ "$name" = "gitlab-ce" ] || continue
        valid_gitlab_version "$ver" || continue
        [ -z "${seen[$ver]:-}" ] || continue
        seen[$ver]=1
        echo "$ver"
    done
}

# 本機 dpkg 架構；獨立成函式讓測試能覆寫。
deb_arch() { dpkg --print-architecture; }

# deb_filename <版本> [架構]：apt download 產生的檔名。架構預設取本機的 deb_arch。
deb_filename() {
    local arch="${2:-}"
    valid_gitlab_version "$1" || return 1
    [ -n "$arch" ] || arch="$(deb_arch)"
    echo "gitlab-ce_$1_${arch}.deb"
}

# deb_version <檔名或路徑>：從 gitlab-ce_<版本>_<架構>.deb 取出版本；不是這種檔名回非 0。
deb_version() {
    local base="${1##*/}" re='^gitlab-ce_([^_]+)_[a-z0-9]+[.]deb$' ver
    [[ $base =~ $re ]] || return 1
    ver="${BASH_REMATCH[1]}"
    valid_gitlab_version "$ver" || return 1
    echo "$ver"
}

# /etc/os-release 的 VERSION_CODENAME（去引號）；檔案不存在或沒有該行回空。
os_codename() {
    local f="${OS_RELEASE_FILE:-/etc/os-release}" line v
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            VERSION_CODENAME=*)
                v="${line#VERSION_CODENAME=}"
                v="${v#\"}"
                v="${v%\"}"
                echo "$v"
                return 0
                ;;
        esac
    done <"$f"
}

# GitLab 的 .deb 依發行版與架構區分；不是 Ubuntu 24.04（noble）amd64 就先問過再繼續。
check_repo_platform() {
    local codename arch
    codename="$(os_codename)"
    arch="$(deb_arch)"
    if [ "$codename" = "noble" ] && [ "$arch" = "amd64" ]; then
        return 0
    fi
    echo "⚠ 這台是 ${codename:-未知發行版}／${arch:-未知架構}，本流程以 Ubuntu 24.04（noble）amd64 為準。" >&2
    echo "  GitLab 的 .deb 依發行版與架構區分；下載的檔案可能無法在 GitLab 伺服器上安裝。" >&2
    confirm "仍要繼續嗎？"
}

# 主機：IPv4 或主機名（英數開頭結尾，中間可有 . -）。全數字加點的必須是合法 IPv4。
_valid_host() {
    [[ $1 =~ ^[0-9.]+$ ]] && { valid_ipv4 "$1"; return; }
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

# 以下驗證都是白名單，且不接受以 - 開頭（會被 scp／dpkg 當成選項）。
valid_scp_user() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; }
valid_scp_host() { _valid_host "$1"; }
valid_remote_dir() { [[ $1 =~ ^[A-Za-z0-9._/~][A-Za-z0-9._/~-]*$ ]]; }
# 本機路徑必須是絕對路徑：含 : 會被 scp 當成遠端主機，./ 與 - 開頭則可能被當成選項。
valid_local_path() { [[ $1 =~ ^/[A-Za-z0-9._/-]*$ ]]; }
valid_download_dir() { valid_local_path "$1"; }

# external_url：http(s)://主機[:port]，不含路徑、帳號、引號、空白（值會放進 Ruby 單引號字串）。
valid_external_url() {
    local re='^https?://([^/:]+)(:([0-9]+))?$' host port hasport
    [[ $1 =~ $re ]] || return 1
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]}"
    hasport="${BASH_REMATCH[2]}"
    _valid_host "$host" || return 1
    if [ -n "$hasport" ]; then
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || return 1
    fi
}

render_external_url() {
    valid_external_url "$1" || return 1
    echo "external_url '$1'"
}

# 取出 initial_root_password 檔中 `Password:` 後的值（純 bash 前綴剝除，值原樣輸出）。
# 找不到或值為空回非 0 且不輸出，由呼叫端退回「請 sudo cat 該檔」。
extract_initial_password() {
    local line pw
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line == "Password: "* ]]; then
            pw="${line#Password: }"
            [ -n "$pw" ] || return 1
            printf '%s\n' "$pw"
            return 0
        fi
    done <"$1"
    return 1
}

# ── 機器檢查 ─────────────────────────────────────────────────────────────────

# 【有網路的電腦】的動作：要有 apt 與列出的指令；缺就中止並指向正確的機器。
ins_require_online() { # ins_require_online [必備指令…]
    local c
    require_machine online
    for c in "$@"; do
        have_cmd "$c" || die "缺少指令 $c。這個動作須在【有網路的電腦】（Ubuntu／Debian）上執行。"
    done
}

# 安裝 .deb 時 GitLab 還沒裝，所以不要求 /opt/gitlab，只要 Ubuntu 工具與 dpkg
# （沿用 network.sh 的 ubuntu 角色，偏離 PR-COM-04 字面，已記於 docs/decision-log.md）。
ins_require_install_host() { require_machine ubuntu dpkg; }

# 安裝完成後才有意義的動作（改 gitlab.rb、讀初始密碼）：要求 GitLab 已安裝。
ins_require_gitlab_host() { require_machine server; }

# ── 說明與排查（內容取自 docs/01-install-and-config.md 第一部分）─────────────

show_help() {
    cat <<'TXT'
【說明】離線安裝 GitLab CE
GitLab 伺服器通常不能連外，所以分兩台機器作業：
  【有網路的電腦】（Ubuntu／Debian）：加入 GitLab 官方套件來源、查可用版本、
    用 apt download 只下載 .deb（不安裝），再以 scp 傳到伺服器。
  【GitLab 伺服器】（Ubuntu 24.04 Noble）：dpkg -i 安裝 .deb，設定 external_url，
    執行 gitlab-ctl reconfigure 初始化，最後取得 root 的初始密碼。

前置條件：
  - 伺服器為 Ubuntu 24.04（Noble）、架構 amd64；.deb 依發行版與架構區分，要下載對應的版本。
    也可以改到官方套件庫 https://packages.gitlab.com/gitlab/gitlab-ce 手動下載
    Ubuntu 24.04（Noble）的 amd64.deb。
  - 兩台機器之間可用 scp（SSH）互傳檔案；安裝與設定需要 root（sudo）。
  - 版本格式例：18.7.6-ce.0，下載的檔名例：gitlab-ce_18.7.6-ce.0_amd64.deb。

注意事項：
  - 改 gitlab.rb 之前，腳本會先備份為 gitlab.rb.bak-時間戳（權限 600，因為 gitlab.rb
    可能含密碼）；external_url 寫在以標記行包夾的「管理區塊」內，重跑會整段取代，
    區塊以外的手寫內容不會被動到。請勿手改標記行之間的內容。
  - reconfigure 失敗時，腳本會詢問是否還原備份。
  - initial_root_password 檔案（/etc/gitlab/initial_root_password）內的密碼只在安裝後
    第一次 reconfigure 起 24 小時內有效，檔案也會在 24 小時後第一次 reconfigure 時自動刪除；
    帳號為 root，請於 24 小時內登入並修改密碼。
  - 外部 Nginx 請用 nginx.sh；HTTPS、LDAP 由本腳本後續選單項目提供。
TXT
}

show_troubleshooting() {
    cat <<'TXT'
【常見問題排查】
  列不出版本（apt-cache madison 沒有輸出）：還沒加入 GitLab 套件來源；先執行選單 1。
    也確認這台是 Ubuntu 24.04（noble），來源是依發行版區分的。
  下載的 .deb 在伺服器上裝不起來：發行版或架構與伺服器不同。選單 1 在非 noble／amd64
    的機器上會先警告；請改在與伺服器相同發行版與架構的機器上下載。
  scp 失敗：確認伺服器的 SSH 服務、帳號、IP 與遠端目錄；本腳本只接受英數與 . _ - ~ / 的路徑。
  dpkg -i 回報相依套件缺少：伺服器不能連外，無法自動補裝。請在【有網路的電腦】用
    apt download 抓取所列套件，一併傳到伺服器後再 dpkg -i。
  reconfigure 失敗：腳本會詢問是否還原 gitlab.rb 備份（gitlab.rb.bak-時間戳）。
    原因可用 sudo gitlab-ctl tail 或 reconfigure 的錯誤輸出判斷。
  initial_root_password 檔案不存在：它在第一次 reconfigure 之後 24 小時由系統自動刪除，
    或安裝前就用 GITLAB_ROOT_PASSWORD／gitlab.rb 設過密碼。忘記密碼請在伺服器執行
    sudo gitlab-rake "gitlab:password:reset[root]" 重設。
  瀏覽器開不起來或被導向錯誤位址：external_url 要與瀏覽器輸入的網址一致；
    重新執行選單 6 即可整段取代，再 reconfigure。
  想還原 gitlab.rb：備份在 /etc/gitlab/gitlab.rb.bak-時間戳，複製回 gitlab.rb 後
    執行 sudo gitlab-ctl reconfigure。
TXT
}

# ── 【有網路的電腦】──────────────────────────────────────────────────────────

# 官方文件的做法是 curl 取得安裝腳本再交給 bash；用子 shell 開 pipefail，
# curl 失敗時整體就失敗，不會因為管線尾端的 bash 成功而被吞掉。
run_repo_script() {
    ( set -o pipefail; curl -fsSL "$INS_REPO_SCRIPT_URL" | bash )
}

add_repo() {
    ins_require_online curl
    require_root
    check_repo_platform || die "已取消。"
    echo "將執行：curl -fsSL $INS_REPO_SCRIPT_URL | bash"
    echo "（這會從網路取得官方安裝腳本並以 root 執行，請確認來源可信。）"
    confirm "加入 GitLab 套件來源？" || { echo "已取消，未做任何變更。"; return 0; }
    run_repo_script
    echo "✓ 已加入 GitLab 套件來源。可用選單 2 列出版本。"
}

list_versions() {
    local vers
    ins_require_online apt-cache
    vers="$(apt-cache madison gitlab-ce | parse_madison | sort_versions desc)" || true
    [ -n "$vers" ] || die "找不到 gitlab-ce 的可用版本。請先執行選單 1 加入套件來源。"
    echo "可用的 gitlab-ce 版本（新到舊）："
    sed 's/^/  /' <<<"$vers"
}

download_deb() {
    local dir ver file
    ins_require_online apt
    dir="$(ask_param INS_DOWNLOAD_DIR "下載目錄（絕對路徑）" "$HOME/gitlab-debs" valid_download_dir)"
    ver="$(ask_param INS_VERSION "要下載的版本（例 18.7.6-ce.0）" "" valid_gitlab_version)"
    mkdir -p "$dir"
    file="$dir/$(deb_filename "$ver")"
    ( cd "$dir" && apt download "gitlab-ce=$ver" )
    [ -f "$file" ] || die "下載後找不到 $file。"
    env_set INS_DEB_PATH "$file"
    echo "✓ 已下載：$file"
    echo "  接著用選單 4 以 scp 傳到 GitLab 伺服器。"
}

send_deb() {
    local deb user host rdir
    ins_require_online scp
    deb="$(ask_param INS_DEB_PATH "要傳送的 .deb 完整路徑（絕對路徑）" "" valid_local_path)"
    [ -f "$deb" ] || die "找不到檔案：$deb"
    deb_version "$deb" >/dev/null || die "檔名不是 gitlab-ce_<版本>_<架構>.deb：$deb"
    user="$(ask_param INS_SERVER_USER "伺服器登入帳號" "${USER:-}" valid_scp_user)"
    host="$(ask_param INS_SERVER_HOST "伺服器 IP 或主機名" "" valid_scp_host)"
    rdir="$(ask_param INS_REMOTE_DIR "伺服器上的目錄" "~/" valid_remote_dir)"
    echo "傳送：$deb → $user@$host:$rdir"
    scp -- "$deb" "$user@$host:$rdir"
    echo "✓ 已傳送。接著到【GitLab 伺服器】用選單 5 安裝。"
}

# ── 【GitLab 伺服器】─────────────────────────────────────────────────────────

install_deb() {
    local deb
    ins_require_install_host
    require_root
    deb="$(ask_param INS_DEB_PATH "要安裝的 .deb 完整路徑（絕對路徑）" "" valid_local_path)"
    [ -f "$deb" ] || die "找不到檔案：$deb。未執行 dpkg。"
    deb_version "$deb" >/dev/null || die "檔名不是 gitlab-ce_<版本>_<架構>.deb：$deb。未執行 dpkg。"
    if gitlab_installed; then
        echo "⚠ 偵測到 ${GITLAB_OPT_DIR:-/opt/gitlab}：這台已安裝 GitLab。升級請改用 upgrade.sh（會先備份並依序升級）。"
        confirm "仍要用 dpkg -i 覆蓋安裝？" || { echo "已取消，未做任何變更。"; return 0; }
    fi
    dpkg -i -- "$deb"
    echo "✓ 已安裝。接著用選單 6 設定 external_url 並 reconfigure。"
}

set_external_url() {
    local url body rc=0
    ins_require_gitlab_host
    require_root
    url="$(ask_param INS_EXTERNAL_URL "external_url（例 http://192.168.9.129）" "" valid_external_url)"
    body="$(render_external_url "$url")"
    echo "將在 $(gitlab_rb_file) 以管理區塊寫入："
    sed 's/^/    /' <<<"$body"
    echo "（gitlab.rb 內原本的 external_url 行不動；Ruby 以後出現者為準，管理區塊在檔尾。）"
    apply_managed_block "$INS_URL_BLOCK" "$body" || rc=$?
    case "$rc" in
        0) echo "✓ external_url 已設定並完成 reconfigure。可用選單 7 查看 root 初始密碼。" ;;
        1) echo "✗ reconfigure 失敗，見上方說明。" >&2 ;;
        3) echo "✗ 寫入 gitlab.rb 失敗，已自動還原。" >&2 ;;
        *) echo "✗ 未寫入任何變更。" >&2 ;;
    esac
    return "$rc"
}

# 顯示 root 初始密碼。依 decision-log：這是 PR-COM-06 的唯一例外，只印密碼那一行，
# 不寫參數檔／日誌／命令列；解析不到就請使用者自己 sudo cat，不 die。
show_initial_password() {
    local f="${GITLAB_INITIAL_PW:-/etc/gitlab/initial_root_password}" pw
    ins_require_gitlab_host
    if [ ! -f "$f" ]; then
        cat <<TXT
找不到 $f。可能的原因：
  - 它在第一次 reconfigure 之後 24 小時，由系統於下一次 reconfigure 時自動刪除；
  - 安裝前就用 GITLAB_ROOT_PASSWORD 或 gitlab.rb 設定過 root 密碼，不會產生此檔。
忘記密碼請在伺服器執行：sudo gitlab-rake "gitlab:password:reset[root]"
TXT
        return 0
    fi
    if pw="$(extract_initial_password "$f" 2>/dev/null)"; then
        echo "帳號：root"
        printf '密碼：%s\n' "$pw"
        echo "⚠ 請於 24 小時內登入並修改密碼；逾時此密碼失效、檔案也會被自動刪除。"
    else
        echo "無法自動讀出密碼（沒有權限或格式不符）。請自行執行：sudo cat $f"
        echo "⚠ 帳號為 root；請於 24 小時內登入並修改密碼。"
    fi
}

# ── 選單 ─────────────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== GitLab 安裝 ===
  1) 加入 GitLab 套件來源          【有網路的電腦】
  2) 列出可用版本                  【有網路的電腦】
  3) 下載指定版本 .deb             【有網路的電腦】
  4) 以 scp 傳到 GitLab 伺服器     【有網路的電腦】
  5) 安裝 .deb（dpkg -i）          【GitLab 伺服器】
  6) 設定 external_url 並 reconfigure 【GitLab 伺服器】
  7) 顯示 root 初始密碼            【GitLab 伺服器】
  8) 說明
  9) 常見問題排查
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) add_repo ;;
        2) list_versions ;;
        3) download_deb ;;
        4) send_deb ;;
        5) install_deb ;;
        6) set_external_url ;;
        7) show_initial_password ;;
        8) show_help ;;
        9) show_troubleshooting ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_ins_dir")"
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
