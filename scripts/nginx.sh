#!/usr/bin/env bash
# 外部 Nginx 選單腳本（離線套件）：【有網路的電腦】下載含相依的 .deb 並打包、
# 【GitLab 伺服器】解包安裝並驗證。只有互動選單，不收參數。
# 來源文件：docs/04-nginx.md 第 1 到 4 節與排查表（說明與排查內容併入本檔）。
# 反向代理設定、停用內建 Nginx、回切由後續票（ISSUE-010）在本檔追加。
#
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得函式而不啟動選單。
#
# 可由環境變數覆寫的路徑（供測試用，預設為正式路徑；它們不是命令列參數）：
#   NGX_KEYRING、NGX_SOURCES_LIST、OS_RELEASE_FILE、GITLAB_NGINX_BIN、GITLAB_OPT_DIR、TMPDIR。

_ngx_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_ngx_dir/lib/common.sh"

NGX_KEY_URL="https://nginx.org/keys/nginx_signing.key"
NGX_KEYRING_DEFAULT="/usr/share/keyrings/nginx-archive-keyring.gpg"
NGX_SOURCES_DEFAULT="/etc/apt/sources.list.d/nginx.list"

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

# ── 說明與排查（內容取自 docs/04-nginx.md 第 1 到 4 節與排查表）────────────────

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
  - 停用內建 Nginx、反向代理設定與切回內建 Nginx 的步驟不在這四步內，由後續功能提供。
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
TXT
}

# ── 選單 ─────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== 外部 Nginx（離線安裝）===
  1) 顯示 GitLab 內建 Nginx 版本   【GitLab 伺服器】
  2) 準備離線套件並打包            【有網路的電腦】
  3) 解包並安裝 Nginx              【GitLab 伺服器】
  4) 說明                          【有網路的電腦】【GitLab 伺服器】
  5) 常見問題排查                  【有網路的電腦】【GitLab 伺服器】
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) ngx_show_builtin ;;
        2) ngx_build_offline ;;
        3) ngx_install_offline ;;
        4) show_help ;;
        5) show_troubleshooting ;;
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
