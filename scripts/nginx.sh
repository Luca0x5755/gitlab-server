#!/usr/bin/env bash
# 外部 Nginx 選單腳本（離線套件）：【有網路的電腦】下載含相依的 .deb 並打包、
# 【GitLab 伺服器】解包安裝並驗證。只有互動選單，不收參數。
# 來源文件：docs/04-nginx.md（說明與排查內容併入本檔）；docs/01-install-and-config.md 第三部分
# 的 gitlab.rb 設定以偵測 nginx.conf 的 user 取代寫死的 www-data（見 docs/decision-log.md）。
# 停用內建 Nginx、憑證、反向代理設定、驗證與切回內建 Nginx 在本檔後半（選單 4 到 8）。
#
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得函式而不啟動選單。
#
# 可由環境變數覆寫的路徑（供測試用，預設為正式路徑；它們不是命令列參數）：
#   NGX_KEYRING、NGX_SOURCES_LIST、OS_RELEASE_FILE、GITLAB_NGINX_BIN、GITLAB_OPT_DIR、TMPDIR、
#   NGINX_CONF（/etc/nginx/nginx.conf）、NGINX_CONF_D（/etc/nginx/conf.d）、NGINX_SSL_DIR（/etc/nginx/ssl）、
#   WORKHORSE_SOCKET、GITLAB_SSL_DIR、GITLAB_RB。

_ngx_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_ngx_dir/lib/common.sh"

NGX_KEY_URL="https://nginx.org/keys/nginx_signing.key"
NGX_KEYRING_DEFAULT="/usr/share/keyrings/nginx-archive-keyring.gpg"
NGX_SOURCES_DEFAULT="/etc/apt/sources.list.d/nginx.list"
# 外部 Nginx 的管理區塊名稱；與 install.sh 的 install_https 不同名，回切才能精準移除。
NGX_EXT_BLOCK="nginx_external"

nginx_main_conf() { echo "${NGINX_CONF:-/etc/nginx/nginx.conf}"; }
ngx_conf_d() { echo "${NGINX_CONF_D:-/etc/nginx/conf.d}"; }
ngx_ssl_dir() { echo "${NGINX_SSL_DIR:-/etc/nginx/ssl}"; }
workhorse_socket() { echo "${WORKHORSE_SOCKET:-/var/opt/gitlab/gitlab-workhorse/sockets/socket}"; }

# ── 解析（純函式）───────────────────────────────────────────────────

# 從 `apt-cache depends --recurse` 的 stdin 取出要下載的實體套件名（排序去重）。
# 只收「整行就是一個套件名」的頂層行：
#   - 縮排行（Depends:／提供者）不是頂層；
#   - <虛擬套件> 以 < 開頭；
#   - libc6:i386 這類其他架構含冒號，丟棄（原文件的 grep "^\w" 會放過它）。
# 沒有任何套件名回非 0，讓呼叫端不會拿空清單去 apt-get download。
parse_dep_pkgs() {
    local out
    out="$(grep -E '^[A-Za-z0-9][A-Za-z0-9.+-]*$' | LC_ALL=C sort -u)" || true
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# 官方 mainline 來源那一行；keyring 路徑可由 NGX_KEYRING 覆寫（測試用）。
nginx_apt_source_line() { # nginx_apt_source_line <codename>
    echo "deb [signed-by=${NGX_KEYRING:-$NGX_KEYRING_DEFAULT}] http://nginx.org/packages/mainline/ubuntu $1 nginx"
}

# 目前系統的 Ubuntu codename；讀不到回空字串。
os_codename() {
    local f="${OS_RELEASE_FILE:-/etc/os-release}"
    [ -f "$f" ] || return 0
    sed -n 's/^VERSION_CODENAME=//p' "$f" | tail -n1 | tr -d '"'
}

# 從 `nginx -V`／`nginx -v` 的輸出（stdin；它們寫到 stderr，呼叫端須 2>&1）取出版本號。
# 沒有「nginx version: nginx/X」那一行回非 0。
parse_nginx_version() {
    local v
    v="$(sed -n -E 's|^nginx version: nginx/([0-9][^ ]*).*$|\1|p' | head -n1)"
    [ -n "$v" ] || return 1
    echo "$v"
}

# `apt-cache policy nginx`（須 LC_ALL=C）的 stdin：Candidate 版本的來源含 nginx.org 才回 0。
# 版本表的版本列縮排 1～5 格（已安裝者為「 *** 版本」），來源行縮排更深；
# 候選版本不一定在第一列，同一版本也可能有多個來源，所以逐列歸屬、逐列比對。
candidate_from_nginx_org() {
    awk '
        /^  Candidate:/ { cand = $2; next }
        /^ *(Installed|Candidate|Version table):/ { next }
        {
            match($0, /^ */)
            if (RLENGTH >= 1 && RLENGTH <= 5) {
                line = $0; sub(/^ *(\*\*\* )?/, "", line); split(line, f, " ")
                cur = f[1]
            } else if (RLENGTH > 5 && cur == cand && cand != "" && cand != "(none)" \
                       && index($0, "://nginx.org/packages/") > 0) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }'
}

# `dpkg -i` 輸出（stdin）中「Errors were encountered while processing:」之後列出的套件
# （每行一個，去掉 :arch 後綴）。成功的輸出沒有這一段，回空。
dpkg_failed_pkgs() {
    awk '
        /^Errors were encountered while processing:/ { on = 1; next }
        on && /^ [^ ]/ { sub(/^ /, ""); sub(/:.*$/, ""); print; next }
        on { on = 0 }'
}

# `dpkg -i` 輸出中缺少或版本不足、得回【有網路的電腦】補下載的相依套件（去 :arch，排序去重）。
# 「is not configured yet」是同批套件尚未設定，不是缺檔，不算。
dpkg_missing_deps() {
    sed -n -E \
        -e 's/^  Package ([^ ]+) is not installed\.$/\1/p' \
        -e 's/^  Version of ([^ ]+) on system is .*$/\1/p' \
        | sed 's/:.*$//' | LC_ALL=C sort -u
}

# ── 反向代理設定（純函式）────────────────────────────────────────────────────

# 讀 nginx.conf 的 user 指令（只在主層級合法）：取第一個名稱（可有 group 第二個）。
# 去掉 # 註解；找不到回非 0。官方套件為 nginx，Ubuntu 預設庫為 www-data——以實際設定為準。
detect_nginx_user() { # detect_nginx_user <nginx.conf>
    local line re='^[[:space:]]*user[[:space:]]+([A-Za-z_][A-Za-z0-9._-]*)([[:space:]]+[A-Za-z_][A-Za-z0-9._-]*)?[[:space:]]*;'
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        if [[ $line =~ $re ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$1"
    return 1
}

valid_unix_user() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; }

# 停用內建 Nginx 的管理區塊內容。
render_external_block() { # render_external_block <worker 使用者>
    valid_unix_user "$1" || return 1
    echo "nginx['enable'] = false"
    echo "web_server['external_users'] = ['$1']"
}

valid_nginx_scheme() { [[ $1 == https || $1 == http ]]; }
valid_cert_source() { [[ $1 == generate || $1 == copy ]]; }

# 站台設定範本。內容含 nginx 變數（$http_host、$http_upgrade…），所以一律用單引號 heredoc，
# 渲染時只替換 @@…@@ 佔位符，不經 shell 展開。
_ngx_tpl_https() {
    cat <<'TPL'
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
    server_name @@SERVER_NAME@@;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name @@SERVER_NAME@@;

    ssl_certificate     @@CERT@@;
    ssl_certificate_key @@KEY@@;
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
TPL
}

_ngx_tpl_http() {
    cat <<'TPL'
upstream gitlab-workhorse {
    server unix:/var/opt/gitlab/gitlab-workhorse/sockets/socket fail_timeout=0;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name @@SERVER_NAME@@;

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
TPL
}

# render_nginx_conf <https|http> <server_name> [憑證路徑 私鑰路徑]：stdout 為整份 gitlab.conf。
# server_name 與路徑都是白名單值（不會夾帶 nginx 指令或換行）；不合格回非 0 且不輸出。
render_nginx_conf() {
    local mode="$1" name="$2" cert="${3:-}" key="${4:-}" t
    valid_cert_host "$name" || return 1
    case "$mode" in
        https)
            valid_local_path "$cert" && valid_local_path "$key" || return 1
            t="$(_ngx_tpl_https)"
            ;;
        http) t="$(_ngx_tpl_http)" ;;
        *) return 1 ;;
    esac
    t="${t//@@SERVER_NAME@@/$name}"
    t="${t//@@CERT@@/$cert}"
    t="${t//@@KEY@@/$key}"
    printf '%s\n' "$t"
}

# `ss -Hltn` 輸出（stdin）中監聽 80 或 443 的列（本機位址欄以 :80／:443 結尾）。
listeners_80_443() { awk '$4 ~ /:(80|443)$/'; }

# ── 離線套件包（打包與解包前的檢查）──────────────────────────────────────────

# 檢查離線包可以安全解開：必須是 gzip tar、至少一個 .deb、每個條目名稱符合白名單
# （扁平、只含 [A-Za-z0-9._+~%-]，%3a 是 epoch 的檔名編碼；因此 ./x.deb、sub/x.deb、
# ../x.deb、/abs/x.deb、含空白者都被拒絕）、每個條目都是一般檔案（拒絕 symlink／hardlink／
# 目錄／裝置）。不通過回非 0 並在 stderr 說明原因。
check_offline_tar() {
    local tar_file="$1" names types name t i=0 n
    [ -f "$tar_file" ] || { echo "✗ 找不到離線包：$tar_file" >&2; return 1; }
    gzip -t "$tar_file" 2>/dev/null || { echo "✗ 不是 gzip 壓縮檔：$tar_file" >&2; return 1; }
    names="$(tar tzf "$tar_file" 2>/dev/null)" || { echo "✗ 無法讀取 tar 內容：$tar_file" >&2; return 1; }
    types="$(tar tvzf "$tar_file" 2>/dev/null | cut -c1)" || { echo "✗ 無法讀取 tar 內容：$tar_file" >&2; return 1; }
    [ -n "$names" ] || { echo "✗ 離線包內沒有任何 .deb：$tar_file" >&2; return 1; }
    n="$(printf '%s\n' "$names" | wc -l)"
    [ "$n" -eq "$(printf '%s\n' "$types" | wc -l)" ] || { echo "✗ tar 條目數不一致，拒絕解包：$tar_file" >&2; return 1; }
    while IFS= read -r name; do
        if ! [[ $name =~ ^[A-Za-z0-9._+~%-]+\.deb$ ]]; then
            echo "✗ 離線包含不合規的條目（只接受扁平的 .deb 檔名）：$name" >&2
            return 1
        fi
    done <<<"$names"
    while IFS= read -r t; do
        i=$((i + 1))
        if [ "$t" != "-" ]; then
            echo "✗ 離線包的條目不是一般檔案（類型 $t）：$(printf '%s\n' "$names" | sed -n "${i}p")" >&2
            return 1
        fi
    done <<<"$types"
}

# 把 <來源目錄> 內的 *.deb 打成扁平的 tar.gz。先寫同目錄的暫存檔，驗證通過才 mv 過去：
# 任何一步失敗都清掉暫存檔，既有的輸出檔原樣保留。
pack_offline() { # pack_offline <來源目錄> <輸出 tar.gz>
    local src="$1" out="$2" f tmp
    local names=()
    for f in "$src"/*.deb; do
        [ -e "$f" ] && names+=("${f##*/}")
    done
    [ "${#names[@]}" -gt 0 ] || { echo "✗ $src 內沒有任何 .deb，不打包。" >&2; return 1; }
    mkdir -p "$(dirname "$out")" || return 1
    tmp="$(mktemp "$out.XXXXXX")" || return 1
    if tar czf "$tmp" -C "$src" -- "${names[@]}" && check_offline_tar "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$out"; then
        return 0
    fi
    rm -f "$tmp"
    echo "✗ 打包失敗，未產生 $out（既有檔案保持原樣）。" >&2
    return 1
}

# ── 動作 ─────────────────────────────────────────────────────────────

# 檢查必備指令。不重用 require_machine 的額外指令參數：它只在 ubuntu 角色生效，
# online／server 角色會忽略；本腳本兩種機器都要查額外指令（apt-get、curl、gpg、dpkg…），
# 所以在此用 have_cmd 自查。（ISSUE-005 的 apt 來源／金鑰邏輯日後可能與此合併進 common.sh。）
ngx_require_cmds() {
    local c
    for c in "$@"; do
        have_cmd "$c" || die "缺少指令 $c。請在符合的機器上執行（見選單標示的【有網路的電腦】或【GitLab 伺服器】）。"
    done
}

# 預設離線包路徑：sudo 下 $HOME 可能是 /root，所以有 SUDO_USER 時改用該使用者的家目錄。
ngx_default_tarball() {
    local home="$HOME" h=""
    if [ -n "${SUDO_USER:-}" ] && have_cmd getent; then
        h="$(getent passwd "$SUDO_USER" | cut -d: -f6)" || h=""
        [ -z "$h" ] || home="$h"
    fi
    echo "$home/nginx-offline.tar.gz"
}

# 在暫存目錄 <stage> 內完成：匯入金鑰、加來源、下載含相依的 .deb、打包到 <tarball>。
# 本函式在 `|| rc=$?` 條件中被呼叫，set -e 會失效，所以每個會失敗的步驟都明確檢查。
_ngx_build_in() { # _ngx_build_in <stage> <tarball> <codename>
    local stage="$1" tarball="$2" codename="$3" sources keyring debs f v
    local pkgs=()
    keyring="${NGX_KEYRING:-$NGX_KEYRING_DEFAULT}"
    sources="${NGX_SOURCES_LIST:-$NGX_SOURCES_DEFAULT}"
    echo "── 匯入 Nginx 官方簽名金鑰並加入 mainline 來源 ──"
    # 先存檔再 gpg，不用 curl | gpg：避免管線吃掉 curl 的失敗。
    if ! curl -fsSL "$NGX_KEY_URL" -o "$stage/nginx_signing.key"; then
        echo "✗ 下載金鑰失敗（$NGX_KEY_URL）。請確認這台可連外；未修改任何來源設定。" >&2
        return 1
    fi
    if ! gpg --dearmor --yes -o "$keyring" "$stage/nginx_signing.key"; then
        echo "✗ gpg --dearmor 失敗，未修改任何來源設定。" >&2
        return 1
    fi
    nginx_apt_source_line "$codename" >"$sources" || return 1
    apt-get update || { echo "✗ apt-get update 失敗。" >&2; return 1; }
    echo "── 可用的 nginx 版本 ──"
    apt-cache madison nginx || true
    # 候選版本若不是 nginx.org 的（例如 Ubuntu 自家的 1.24），打出來的包就不是 mainline。
    LC_ALL=C apt-cache policy nginx >"$stage/policy.txt" || { echo "✗ apt-cache policy 失敗。" >&2; return 1; }
    if ! candidate_from_nginx_org <"$stage/policy.txt"; then
        cat "$stage/policy.txt" >&2
        echo "✗ nginx 的候選版本不是來自 nginx.org（見上方 apt-cache policy），不下載。請確認來源行與網路。" >&2
        return 1
    fi

    echo "── 解析相依並下載 ──"
    if ! apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances nginx >"$stage/depends.txt" 2>"$stage/depends.err"; then
        cat "$stage/depends.err" >&2
        echo "✗ apt-cache depends 失敗。" >&2
        return 1
    fi
    parse_dep_pkgs <"$stage/depends.txt" >"$stage/pkgs.txt" \
        || { echo "✗ 解析不到任何相依套件（apt-cache depends 輸出為空），不下載。" >&2; return 1; }
    mapfile -t pkgs <"$stage/pkgs.txt"
    debs="$stage/debs"
    mkdir "$debs" || return 1
    (cd "$debs" && apt-get download "${pkgs[@]}") || { echo "✗ apt-get download 失敗，不打包。" >&2; return 1; }

    v=""
    for f in "$debs"/nginx_*.deb; do
        [ -e "$f" ] && v="${f##*/nginx_}" && v="${v%_*}"
    done
    [ -n "$v" ] || { echo "✗ 下載結果沒有 nginx 套件，不打包。" >&2; return 1; }
    echo "已下載 $(find "$debs" -name '*.deb' | wc -l | tr -d ' ') 個 .deb；nginx 版本 $v"
    pack_offline "$debs" "$tarball" || return 1
    cat <<TXT

✓ 已產生離線包：$tarball
  下一步：把它傳到 GitLab 伺服器，例如
    scp $tarball <使用者>@<伺服器IP>:~/
  再到伺服器執行本腳本的「解包並安裝 Nginx」。
TXT
}

# 【有網路的電腦】下載含相依的 .deb 並打包（PR-NGX-01）。
ngx_build_offline() {
    local tarball stage rc=0 codename
    require_machine online
    ngx_require_cmds apt-get apt-cache curl gpg tar
    codename="$(os_codename)"
    [ "$codename" = "noble" ] \
        || die "這個動作須在 Ubuntu 24.04（noble）上執行：來源行與相依套件都對應 noble，目前是「${codename:-未知}」。"
    require_root
    tarball="$(ask_param NGX_TARBALL "離線包輸出路徑" "$(ngx_default_tarball)")"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/nginx-offline.XXXXXX")" || die "建立暫存目錄失敗。"
    _ngx_build_in "$stage" "$tarball" "$codename" || rc=$?
    rm -rf "$stage"
    return "$rc"
}

# 【GitLab 伺服器】顯示 GitLab 內建 Nginx 的版本（參考用，可據此決定外部 Nginx 版本）。
ngx_show_builtin() {
    local bin out ver
    require_machine server
    bin="${GITLAB_NGINX_BIN:-${GITLAB_OPT_DIR:-/opt/gitlab}/embedded/sbin/nginx}"
    [ -x "$bin" ] || die "找不到內建 Nginx（$bin）。請先執行過至少一次 sudo gitlab-ctl reconfigure。"
    # nginx -V 把輸出寫到 stderr。
    out="$("$bin" -V 2>&1)" || die "$bin -V 執行失敗：$out"
    printf '%s\n' "$out"
    ver="$(printf '%s\n' "$out" | parse_nginx_version)" || die "無法從 $bin -V 的輸出判讀版本。"
    echo
    echo "GitLab 內建 Nginx 版本：$ver（外部 Nginx 請選功能相容的版本）"
}

# 解包後的安裝：dpkg -i 全部 .deb；失敗時分流提示。成功才清暫存目錄。
# shellcheck disable=SC2001
_ngx_install_in() { # _ngx_install_in <解包目錄>
    local dir="$1" log rc=0 failed missing
    local debs=()
    debs=("$dir"/*.deb)
    log="$dir/dpkg.log"
    dpkg -i "${debs[@]}" >"$log" 2>&1 || rc=$?
    cat "$log"
    if [ "$rc" -ne 0 ]; then
        failed="$(dpkg_failed_pkgs <"$log")"
        missing="$(dpkg_missing_deps <"$log")"
        echo "✗ dpkg -i 失敗（結束碼 $rc）。" >&2
        [ -z "$failed" ] || { echo "有問題的套件：" >&2; sed 's/^/  /' <<<"$failed" >&2; }
        if [ -n "$missing" ]; then
            echo "缺少或版本不足的相依套件：" >&2
            sed 's/^/  /' <<<"$missing" >&2
            echo "請回【有網路的電腦】補下載後一起傳到伺服器，例如：" >&2
            echo "  apt-get download $(paste -sd" " <<<"$missing")" >&2
        else
            echo "沒有找到缺少的相依套件，可能是 nginx 啟動失敗（例如 80 埠被 GitLab 內建 Nginx 佔用）；" >&2
            echo "請看選單的「常見問題排查」。" >&2
        fi
        echo "解包目錄已保留供檢查：$dir" >&2
        return 1
    fi
    echo "── 驗證 ──"
    nginx -v 2>&1 || { echo "✗ nginx -v 失敗。" >&2; return 1; }
    systemctl status nginx --no-pager \
        || echo "⚠ systemctl status nginx 顯示服務未在執行；若是 80／443 被內建 Nginx 佔用，停用內建 Nginx 後再啟動（後續流程處理）。"
    rm -rf "$dir"
}

# 【GitLab 伺服器】解包離線包並 dpkg -i，驗證 nginx -v 與 systemctl status（PR-NGX-02）。
ngx_install_offline() {
    local tarball dir rc=0 f
    require_machine server
    ngx_require_cmds dpkg tar systemctl
    require_root
    tarball="$(ask_param NGX_TARBALL "離線包路徑" "$(ngx_default_tarball)")"
    [ -f "$tarball" ] || die "找不到離線包：$tarball"
    dir="$(mktemp -d "${TMPDIR:-/tmp}/nginx-install.XXXXXX")" || die "建立暫存目錄失敗。"
    # 先複製成私有副本（暫存目錄為 700），檢查與解包都用這份：
    # 避免檢查通過後原檔被換成別的內容（TOCTOU）。白名單已通過；--no-same-owner 不套用包內擁有者。
    if ! cp "$tarball" "$dir/offline.tar.gz" || ! check_offline_tar "$dir/offline.tar.gz" \
        || ! tar xzf "$dir/offline.tar.gz" -C "$dir" --no-same-owner; then
        rm -rf "$dir"
        die "離線包無法安全解開：$tarball"
    fi
    rm -f "$dir/offline.tar.gz"
    echo "將以 dpkg -i 安裝下列套件（相依套件若比系統現有的新，可能一併升級系統套件）："
    for f in "$dir"/*.deb; do echo "  ${f##*/}"; done
    if ! confirm "確定安裝？"; then
        rm -rf "$dir"
        echo "已取消，未做任何變更。"
        return 0
    fi
    _ngx_install_in "$dir" || rc=$?
    return "$rc"
}

# ── 停用內建、憑證、反向代理、驗證、回切 ─────────────────────────────────────

# 【GitLab 伺服器】偵測外部 Nginx 的 worker 使用者，以管理區塊停用內建 Nginx 並 reconfigure，
# 確認 Workhorse socket 存在（PR-NGX-03）。
ngx_disable_builtin() {
    local user body line rc=0 sock
    require_machine server
    ngx_require_cmds nginx
    require_root
    user="$(detect_nginx_user "$(nginx_main_conf)")" \
        || die "讀不到 $(nginx_main_conf) 的 user 指令。請先用選單 3 安裝外部 Nginx。"
    body="$(render_external_block "$user")" || die "worker 使用者名稱不合法：$user"
    echo "偵測到外部 Nginx 的 worker 使用者：$user（官方套件為 nginx，Ubuntu 預設庫為 www-data）"
    echo "將在 $(gitlab_rb_file) 以管理區塊（$NGX_EXT_BLOCK）寫入："
    while IFS= read -r line; do echo "    $line"; done <<<"$body"
    echo "（external_url 維持不變，須與使用者實際訪問的網址一致。）"
    apply_managed_block "$NGX_EXT_BLOCK" "$body" || rc=$?
    case "$rc" in
        0) ;;
        1) echo "✗ reconfigure 失敗，見上方說明。" >&2; return 1 ;;
        3) echo "✗ 寫入 gitlab.rb 失敗，已自動還原。" >&2; return 3 ;;
        *) echo "✗ 未寫入任何變更。" >&2; return "$rc" ;;
    esac
    sock="$(workhorse_socket)"
    if [ -S "$sock" ]; then
        ls -la -- "$sock"
        echo "✓ 內建 Nginx 已停用；Workhorse socket 存在。下一步：選單 5 準備憑證、選單 6 設定反向代理。"
    else
        echo "⚠ 找不到 Workhorse socket（$sock）。請確認 sudo gitlab-ctl status 的 workhorse 在運行；" >&2
        echo "  沒有它外部 Nginx 會回 502（見「常見問題排查」）。" >&2
        return 1
    fi
}

# 【GitLab 伺服器】憑證：產生自簽（共用 make_self_signed_cert）或複製 /etc/gitlab/ssl 既有的（PR-NGX-04）。
ngx_prepare_cert() {
    local host source dir crt key from_crt from_key
    require_machine server
    require_root
    host="$(ask_param NGX_SERVER_NAME "server_name（IP 或網域，須與瀏覽器輸入的一致）" "$(env_get INS_HTTPS_HOST)" valid_cert_host)"
    source="$(ask_param NGX_CERT_SOURCE "憑證來源（generate＝產生自簽、copy＝複製 $(ssl_dir) 既有憑證）" generate valid_cert_source)"
    dir="$(ngx_ssl_dir)"
    crt="$dir/$host.crt"
    key="$dir/$host.key"
    if [ -e "$crt" ] || [ -e "$key" ]; then
        echo "已有憑證：$crt"
        confirm "要覆蓋舊的憑證與私鑰嗎？" || { echo "已取消，沿用既有憑證。"; return 0; }
    fi
    case "$source" in
        generate)
            have_cmd openssl || die "缺少指令 openssl，無法產生憑證。"
            make_self_signed_cert "$host" "$dir"
            ;;
        copy)
            from_crt="$(ssl_dir)/$host.crt"
            from_key="$(ssl_dir)/$host.key"
            if [ ! -f "$from_crt" ] || [ ! -f "$from_key" ]; then die "找不到 $from_crt 或 $from_key。請改選 generate，或先到 install.sh 選單 8 產生。"; fi
            ( umask 077 && mkdir -p "$dir" && cp -- "$from_crt" "$crt" && cp -- "$from_key" "$key" ) || die "複製憑證失敗。"
            if ! { chmod 600 "$key" && chmod 644 "$crt"; }; then die "設定憑證權限失敗。"; fi
            echo "  已複製：$from_crt → $crt"
            echo "  已複製：$from_key → $key"
            ;;
    esac
    echo "✓ 憑證就緒。下一步：選單 6 設定反向代理。"
}

# 80／443 是否可以交給外部 Nginx：外部 nginx 正在跑時它自己佔著，重啟會釋放，放行；
# 否則任何監聽者（尤其是尚未停用的內建 Nginx）都是衝突。
ngx_ports_ready() {
    local busy
    if systemctl is-active --quiet nginx; then
        return 0
    fi
    have_cmd ss || die "缺少指令 ss，無法確認 80／443 已釋放，不啟動 nginx。"
    busy="$(ss -Hltnp | listeners_80_443)" || true
    if [ -n "$busy" ]; then
        echo "✗ 80 或 443 仍被佔用，不啟動 nginx：" >&2
        printf '%s\n' "$busy" | sed 's/^/  /' >&2
        echo "  內建 Nginx 尚未停用的話，請先執行選單 4；其他程式請先停掉。" >&2
        return 1
    fi
}

# 【GitLab 伺服器】產生 conf.d/gitlab.conf 並啟用（PR-NGX-05、06、07）。
ngx_configure_proxy() {
    local host scheme dir conf bak="" crt key ts body
    require_machine server
    ngx_require_cmds nginx systemctl
    require_root
    block_present "$(gitlab_rb_file)" "$NGX_EXT_BLOCK" \
        || die "尚未停用內建 Nginx（gitlab.rb 沒有 $NGX_EXT_BLOCK 區塊）。請先執行選單 4。"
    host="$(ask_param NGX_SERVER_NAME "server_name（IP 或網域）" "$(env_get INS_HTTPS_HOST)" valid_cert_host)"
    scheme="$(ask_param NGX_SCHEME "對外協定（https／http）" https valid_nginx_scheme)"
    dir="$(ngx_conf_d)"
    conf="$dir/gitlab.conf"
    crt="$(ngx_ssl_dir)/$host.crt"
    key="$(ngx_ssl_dir)/$host.key"
    if [ "$scheme" = https ]; then
        if [ ! -f "$crt" ] || [ ! -f "$key" ]; then die "找不到憑證 $crt 或 $key。請先執行選單 5 準備憑證。"; fi
        body="$(render_nginx_conf https "$host" "$crt" "$key")" || die "設定值不合法，未寫入。"
    else
        echo "⚠ HTTP 模式沒有加密，僅供測試或內網無加密需求。"
        body="$(render_nginx_conf http "$host")" || die "設定值不合法，未寫入。"
    fi
    ngx_ports_ready || return 1

    mkdir -p "$dir" || die "無法建立 $dir。"
    if [ -f "$conf" ]; then
        ts="$(now_stamp)"
        bak="$conf.bak-$ts"
        cp -p -- "$conf" "$bak" || die "備份 $conf 失敗，未修改。"
        echo "  已備份舊設定：$bak"
    fi
    printf '%s\n' "$body" >"$conf" || { [ -z "$bak" ] || cp -- "$bak" "$conf"; die "寫入 $conf 失敗。"; }
    echo "將使用的設定：$conf（server_name $host，$scheme）"
    if ! nginx -t; then
        if [ -n "$bak" ]; then cp -- "$bak" "$conf"; else rm -f "$conf"; fi
        echo "✗ nginx -t 失敗，已還原舊設定，未重啟 nginx。" >&2
        return 1
    fi
    # 預設站台改名而不是刪除：nginx 只載入 *.conf，效果等同移除，且可復原。
    if [ -f "$dir/default.conf" ]; then
        mv -- "$dir/default.conf" "$dir/default.conf.bak-$(now_stamp)" || die "無法移除預設站台 $dir/default.conf。"
        echo "  已移除預設站台（改名為 default.conf.bak-…）。"
    fi
    systemctl restart nginx || die "systemctl restart nginx 失敗。請看 sudo journalctl -u nginx 與「常見問題排查」。"
    systemctl enable nginx || echo "⚠ systemctl enable nginx 失敗，開機後可能不會自動啟動。" >&2
    if have_cmd ufw; then
        ufw allow 80/tcp || echo "⚠ ufw allow 80/tcp 失敗，請手動放行。" >&2
        ufw allow 443/tcp || echo "⚠ ufw allow 443/tcp 失敗，請手動放行。" >&2
    else
        echo "⚠ 找不到 ufw，請自行確認防火牆已放行 80／443。" >&2
    fi
    echo "✓ 外部 Nginx 已啟用。請用選單 7 驗證。"
}

# 【GitLab 伺服器】驗證（PR-NGX-08）：三項各自回報，任一失敗整體回非 0。
ngx_verify() {
    local host scheme fails=0
    require_machine server
    ngx_require_cmds systemctl curl
    host="$(env_get NGX_SERVER_NAME)"
    scheme="$(env_get NGX_SCHEME)"
    [ -n "$host" ] || die "還沒有設定 server_name。請先執行選單 6。"
    valid_nginx_scheme "$scheme" || scheme=https
    echo "── systemctl status nginx ──"
    systemctl status nginx --no-pager || { echo "✗ nginx 未在運行。" >&2; fails=$((fails + 1)); }
    echo "── gitlab-ctl status ──"
    if have_cmd gitlab-ctl; then
        gitlab-ctl status || { echo "✗ GitLab 有服務未運行。" >&2; fails=$((fails + 1)); }
    else
        echo "✗ 找不到 gitlab-ctl。" >&2
        fails=$((fails + 1))
    fi
    echo "── curl -kI $scheme://$host ──"
    curl -kI -sS -m 10 "$scheme://$host" || { echo "✗ 連不上 $scheme://$host。" >&2; fails=$((fails + 1)); }
    [ "$fails" -eq 0 ] || return 1
    echo "✓ 驗證通過。瀏覽器訪問 $scheme://$host 應可看到 GitLab 登入頁。"
}

# 【GitLab 伺服器】切回內建 Nginx（PR-NGX-09）：先停外部 nginx 釋放 80／443，再移除管理區塊並 reconfigure。
ngx_revert_builtin() {
    local rc=0
    require_machine server
    ngx_require_cmds systemctl
    require_root
    if ! block_present "$(gitlab_rb_file)" "$NGX_EXT_BLOCK"; then
        echo "gitlab.rb 沒有本腳本的外部 Nginx 區塊（$NGX_EXT_BLOCK），不需切換。"
        echo "（若是手動寫了 nginx['enable'] = false，請自行編輯 gitlab.rb 後 reconfigure。）"
        return 0
    fi
    echo "將停用並關閉外部 nginx，移除管理區塊 $NGX_EXT_BLOCK，並 reconfigure 啟用內建 Nginx。"
    confirm "確定切回內建 Nginx？服務會短暫中斷。" || { echo "已取消，未做任何變更。"; return 0; }
    systemctl stop nginx || echo "⚠ systemctl stop nginx 失敗（可能本來就沒在跑）。" >&2
    systemctl disable nginx || echo "⚠ systemctl disable nginx 失敗。" >&2
    remove_managed_block "$NGX_EXT_BLOCK" || rc=$?
    case "$rc" in
        0) echo "✓ 已切回內建 Nginx。$(ngx_conf_d)/gitlab.conf 留在原處但不再被載入。" ;;
        1) echo "✗ reconfigure 失敗，見上方說明。" >&2 ;;
        3) echo "✗ 寫入 gitlab.rb 失敗，已自動還原。" >&2 ;;
        *) echo "✗ 未寫入任何變更。" >&2 ;;
    esac
    return "$rc"
}

# ── 說明與排查（內容取自 docs/04-nginx.md 與排查表）────────────────

show_help() {
    cat <<'TXT'
【說明】離線安裝外部 Nginx（取代 GitLab 內建）
適用情境：需要自訂 Nginx 組態、使用特定版本或模組，或在同一台伺服器上以 Nginx 服務多個站台。

前置條件：GitLab CE 已安裝完成，且至少執行過一次 sudo gitlab-ctl reconfigure。

流程（本選單負責前四步）：
  1. 【GitLab 伺服器】選 1 查看內建 Nginx 版本（等同 sudo /opt/gitlab/embedded/sbin/nginx -V），
     可據此決定外部 Nginx 要裝的版本，以確保功能相容。
  2. 【有網路的電腦】選 2 準備離線套件：須在「相同 Ubuntu 24.04（noble）」的電腦上操作。
     腳本會匯入 Nginx 官方簽名金鑰、加入 mainline 套件來源、確認候選版本來自 nginx.org，
     再下載 nginx 與所有相依的 .deb，打包成 nginx-offline.tar.gz。
     apt-get download 不受本機已安裝狀態影響，會下載所有列出的 .deb，
     所以可以安心在已安裝 Nginx 的電腦上執行。
  3. 傳輸：腳本打包完成後會印出 scp 指令範例，例如
       scp ~/nginx-offline.tar.gz <使用者>@<伺服器IP>:~/
  4. 【GitLab 伺服器】選 3 解包並安裝：腳本先檢查離線包（只接受扁平的 .deb 檔名），
     解到暫存目錄後以 dpkg -i 安裝，已安裝的相依會自動略過，最後驗證 nginx -v 與
     systemctl status nginx。

注意：
  - dpkg -i 會安裝離線包內的全部 .deb；若其中的基礎套件（例如 libc6）比伺服器現有的新，
    會一併升級系統套件。安裝前腳本會列出清單並要求輸入 yes。
  - 若出現相依性錯誤，腳本會列出有問題的套件與缺少的相依；請回【有網路的電腦】
    以 apt-get download 補下載後再傳來，必要時執行 sudo dpkg --configure -a。

後續步驟（選單 4 到 8，皆在【GitLab 伺服器】）：
  4. 停用內建 Nginx：讀 /etc/nginx/nginx.conf 的 user 指令填入 web_server['external_users']
     （官方套件為 nginx，Ubuntu 預設庫為 www-data，以實際設定為準），nginx['enable'] = false，
     以管理區塊（nginx_external）寫入並 reconfigure，最後確認 Workhorse socket 存在。
     external_url 維持不變，可以是 IP 或網域（例 'https://192.168.9.129'），只要與使用者實際
     訪問的網址一致；它決定 GitLab 產生的連結（clone URL、通知信等）。使用網域時，
     server_name 與憑證也須對應該網域。
  5. 憑證：產生自簽憑證（效期 10 年、含 subjectAltName），或複製 /etc/gitlab/ssl 已有的憑證；
     放在 /etc/nginx/ssl/<IP或網域>.crt／.key。
  6. 反向代理：產生 /etc/nginx/conf.d/gitlab.conf（HTTPS 為推薦；HTTP 僅供測試或內網無加密需求）。
     先 nginx -t，失敗就還原舊設定且不重啟；確認 80／443 已釋放才 systemctl restart nginx，
     並移除預設站台、enable nginx、ufw allow 80/tcp 與 443/tcp。
  7. 驗證：systemctl status nginx、gitlab-ctl status、curl -kI。
  8. 切換回內建 Nginx：停用並關閉外部 nginx，移除管理區塊，reconfigure。
  - 若曾用 install.sh 啟用內建 Nginx 的 HTTPS（install_https 區塊），external_url 會是 https，
    改用外部 Nginx 後其 nginx['redirect_http_to_https'] 不再生效，導向由 gitlab.conf 負責。
TXT
}

show_troubleshooting() {
    cat <<'TXT'
【常見問題排查】
  下載與安裝（本腳本的步驟）：
    金鑰匯入失敗：下載 https://nginx.org/keys/nginx_signing.key 失敗，確認這台能連外；
      腳本在金鑰取得前不會改動來源設定，修好網路後重跑即可。
    不是 noble：來源行寫死 noble，也只在 Ubuntu 24.04 的相依上驗證；請改在 24.04 的電腦上打包。
    候選版本不是 nginx.org：apt-cache policy nginx 的 Candidate 若是 Ubuntu 自家的 1.24，
      代表 mainline 來源沒生效；確認 /etc/apt/sources.list.d/nginx.list 與 apt-get update 沒有錯誤。
    dpkg -i 相依錯誤：腳本會列出有問題的套件與缺少的相依；回有網路的電腦
      apt-get download <套件> 補下載，傳到伺服器後再裝；必要時 sudo dpkg --configure -a。
    dpkg -i 失敗但沒有缺相依：常見原因是 nginx 套件安裝後自動啟動，卻因 80 埠被
      GitLab 內建 Nginx 佔用而失敗；先用 sudo ss -tlnp | grep ':80' 確認，
      停用內建 Nginx 後再 sudo dpkg --configure -a。
  設定與執行（04 文件的排查表）：
    502 Bad Gateway：Workhorse socket 不存在或未啟動。
      sudo gitlab-ctl status 確認 workhorse 運行中；
      ls -la /var/opt/gitlab/gitlab-workhorse/sockets/socket 確認 socket 存在。
    Permission denied：Nginx worker 使用者無權存取 socket。
      用 ps aux | grep 'nginx: worker' 確認實際使用者（官方套件為 nginx），
      確認 web_server['external_users'] 設定一致並重新 reconfigure。
    413 Request Entity Too Large：Nginx 限制上傳大小。
      確認 client_max_body_size 0; 已寫入站台設定。
    WebSocket 連線失敗：缺少 Upgrade header。
      確認 map $http_upgrade 區塊與 proxy_set_header Upgrade 皆已設定。
    Nginx 無法啟動：Port 衝突或設定檔語法錯誤。
      sudo nginx -t 檢查語法；sudo ss -tlnp | grep ':80' 檢查是否有其他程式佔用 Port
      （GitLab 內建 Nginx 尚未停用時會佔住 80／443）。
    網頁可開但 Git push/pull 失敗：proxy_read_timeout 過短。
      確認 proxy_read_timeout 3600; 已設定，大型 repo 操作需要較長的 timeout。
  選單 4 到 8 的訊息：
    選單 4 讀不到 user：尚未安裝外部 Nginx（先選 3），或 nginx.conf 沒有 user 指令。
    選單 4 找不到 Workhorse socket：GitLab 服務沒起來；sudo gitlab-ctl status、sudo gitlab-ctl restart。
    選單 6 說 80／443 仍被佔用：多半是內建 Nginx 尚未停用（先選 4）；
      sudo ss -tlnp | grep -E ':80|:443' 看是誰。
    選單 6 說 nginx -t 失敗：腳本已還原舊設定且沒有重啟；修正 nginx 輸出的錯誤後重跑。
    選單 6 找不到憑證：先選 5；憑證檔名須是 <server_name>.crt／.key，放在 /etc/nginx/ssl。
    驗證 curl 失敗：-k 已略過自簽憑證檢查；仍連不上請看 sudo nginx -t、sudo ufw status、
      sudo gitlab-ctl status。
    切回內建後網頁打不開：sudo gitlab-ctl status 看 nginx 是否 run；80／443 是否被外部 nginx
      殘留佔用（sudo systemctl status nginx 應為 inactive）。
TXT
}

# ── 選單 ─────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== 外部 Nginx（離線安裝）===
  1) 顯示 GitLab 內建 Nginx 版本   【GitLab 伺服器】
  2) 準備離線套件並打包            【有網路的電腦】
  3) 解包並安裝 Nginx              【GitLab 伺服器】
  4) 停用內建 Nginx（external_users）  【GitLab 伺服器】
  5) 準備憑證（產生或複製）        【GitLab 伺服器】
  6) 設定反向代理並啟用            【GitLab 伺服器】
  7) 驗證                          【GitLab 伺服器】
  8) 切換回內建 Nginx              【GitLab 伺服器】
  9) 說明                          【有網路的電腦】【GitLab 伺服器】
  10) 常見問題排查                 【有網路的電腦】【GitLab 伺服器】
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) ngx_show_builtin ;;
        2) ngx_build_offline ;;
        3) ngx_install_offline ;;
        4) ngx_disable_builtin ;;
        5) ngx_prepare_cert ;;
        6) ngx_configure_proxy ;;
        7) ngx_verify ;;
        8) ngx_revert_builtin ;;
        9) show_help ;;
        10) show_troubleshooting ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_ngx_dir")"
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
