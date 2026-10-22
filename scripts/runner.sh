#!/usr/bin/env bash
# GitLab Runner 選單腳本（同機、Docker executor、離線）。只有互動選單，不收參數。
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得函式而不啟動選單。
#
# 可由環境變數覆寫的路徑（供測試用，預設為正式路徑；它們不是命令列參數）：
#   RUNNER_CONFIG_DIR（/etc/gitlab-runner）、DOCKER_DATA_DIR（/var/lib/docker）、
#   GITLAB_OPT_DIR、GITLAB_SSL_DIR、TMPDIR。

_rnr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_rnr_dir/lib/common.sh"

# ── 解析（純函式）───────────────────────────────────────────────────

# 從 version-manifest.txt（/opt/gitlab/version-manifest.txt）第一個 gitlab-ce／gitlab-ee 行取版本。
# 找不到檔案或沒有該行回非 0。
runner_gitlab_version() { # runner_gitlab_version <version-manifest.txt>
    local f="$1" ver
    [ -f "$f" ] || return 1
    ver="$(sed -n -E 's/^gitlab-(ce|ee)[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*$/\2/p' "$f" | head -n1)"
    [ -n "$ver" ] || return 1
    echo "$ver"
}

# 取版本字串的 major.minor；debian 後綴（-1）與 ~ 之後都忽略。非法回非 0。
_rnr_major_minor() {
    local re='^([0-9]+)\.([0-9]+)\.[0-9]+([~-].*)?$'
    [[ $1 =~ $re ]] || return 1
    echo "$((10#${BASH_REMATCH[1]})).$((10#${BASH_REMATCH[2]}))"
}

# Runner 與 GitLab 的 major.minor 不同回 0（不一致）、相同回 1、任一非法回 2。
runner_version_mismatch() { # runner_version_mismatch <GitLab 版本> <Runner 版本>
    local g r
    g="$(_rnr_major_minor "$1")" || return 2
    r="$(_rnr_major_minor "$2")" || return 2
    [ "$g" != "$r" ]
}

# 網址的 scheme；不是 http／https 回非 0。
runner_url_scheme() { # runner_url_scheme <網址>
    local re='^(https?)://'
    [[ $1 =~ $re ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

# 網址的主機（去掉 scheme、埠、路徑）；不合法回非 0。
runner_url_host() { # runner_url_host <網址>
    local re='^https?://([A-Za-z0-9.-]+)(:[0-9]+)?(/.*)?$'
    [[ $1 =~ $re ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

# job 容器連回 GitLab 的網址：external_url 的主機換成本機區網 IP，保留 scheme 與埠。
runner_clone_url() { # runner_clone_url <external_url> <區網 IP>
    local re='^(https?)://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$'
    valid_ipv4 "$2" || return 1
    [[ $1 =~ $re ]] || return 1
    echo "${BASH_REMATCH[1]}://$2${BASH_REMATCH[2]}"
}

# 憑證的 subjectAltName 是否涵蓋主機：涵蓋 0、不涵蓋（含只有 CN）1、讀不到憑證 2。
runner_cert_covers_host() { # runner_cert_covers_host <憑證檔> <IP或網域>
    local crt="$1" host="$2" type san
    [ -f "$crt" ] || return 2
    type="$(cert_san_type "$host")" || return 2
    san="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)" || return 1
    if [ "$type" = IP ]; then
        grep -qE "IP Address:$host([,[:space:]]|\$)" <<<"$san"
    else
        grep -qE "DNS:$host([,[:space:]]|\$)" <<<"$san"
    fi
}

# ── 驗證與設定（純函式）────────────────────────────────────────────────

# docker image 參照：[registry[:埠]/][路徑/]名稱[:tag][@digest]，只收白名單字元且不得以 - 開頭
# （值會進 docker pull／save 的參數）。
valid_image_ref() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; }

# 空白分隔的映像清單：至少一個，且每個都合法。
valid_image_list() {
    local img n=0
    for img in $1; do
        valid_image_ref "$img" || return 1
        n=$((n + 1))
    done
    [ "$n" -gt 0 ]
}

# 剩餘空間（KB）低於門檻（GB）回 0，否則 1；任一非正整數回 2。
runner_disk_low() { # runner_disk_low <剩餘 KB> <門檻 GB>
    [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 2
    [ "$1" -lt "$(($2 * 1024 * 1024))" ]
}

# 只改 config.toml 頂層（第一個 [ 之前）的 concurrent；沒有就補在最前面。
runner_set_concurrent() { # runner_set_concurrent <config.toml> <正整數>
    local f="$1" n="$2" tmp
    [[ $n =~ ^[1-9][0-9]*$ ]] || return 1
    [ -f "$f" ] || return 1
    tmp="$(mktemp)" || return 1
    awk -v n="$n" '
        BEGIN { top = 1 }
        /^\[/ { top = 0 }
        top && /^concurrent[[:space:]]*=/ { next }
        { lines[++c] = $0 }
        END {
            print "concurrent = " n
            for (i = 1; i <= c; i++) print lines[i]
        }
    ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" >"$f"
    rm -f "$tmp"
}

# ── 動作 ─────────────────────────────────────────────────────────────

RNR_NAME="gitlab-ci"
RNR_DEFAULT_IMAGES="alpine:3.20 ubuntu:24.04 node:22 python:3.13 docker:27-cli"

runner_etc_dir() { echo "${RUNNER_CONFIG_DIR:-/etc/gitlab-runner}"; }
runner_config_file() { echo "$(runner_etc_dir)/config.toml"; }

# 本機第一個區網 IP（hostname -I 的第一欄）；取不到回空字串。
runner_default_lan_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

runner_is_registered() { grep -qE "^[[:space:]]*name = \"$RNR_NAME\"" "$(runner_config_file)" 2>/dev/null; }

# 【GitLab 伺服器】註冊 instance runner（Docker executor）。
# token 由使用者在後台建立 Runner 後隱藏輸入貼上，只以環境變數 CI_SERVER_TOKEN 傳給 register：
# 不進命令列、參數檔、日誌（見 docs/decision-log.md）。
runner_register() {
    local ext_url lan_ip clone_url scheme host ca_src="" ca_dst="" concurrent images image tok
    local args=()
    require_machine server
    require_cmds gitlab-runner docker openssl
    require_root
    if runner_is_registered; then
        echo "已註冊：$(runner_config_file) 已有 Runner「$RNR_NAME」。要重來請先用選單「取消註冊並移除 Runner」。"
        return 0
    fi
    ext_url="$(ask_param RNR_EXTERNAL_URL "GitLab 的 external_url" "$(env_get INS_EXTERNAL_URL)" valid_http_url)" \
        || die "external_url 不合法（須為 http:// 或 https:// 開頭）。"
    lan_ip="$(ask_param RNR_LAN_IP "job 容器連回 GitLab 用的本機區網 IP" "$(runner_default_lan_ip)" valid_ipv4)" \
        || die "區網 IP 不合法。"
    clone_url="$(runner_clone_url "$ext_url" "$lan_ip")" || die "無法由 $ext_url 與 $lan_ip 組出 clone_url。"
    scheme="$(runner_url_scheme "$ext_url")"
    host="$(runner_url_host "$ext_url")" || die "無法解析 external_url 的主機：$ext_url"
    if [ "$scheme" = https ]; then
        ca_src="$(ask_param RNR_CA_FILE "自簽憑證檔（當作 CA）" "$(ssl_dir)/$host.crt" valid_local_path)" \
            || die "憑證路徑不合法。"
        # 先複製成 Runner 自己的副本，再檢查這份副本：檢查與實際使用的是同一個檔案（避免檢查後原檔被換掉）。
        ca_dst="$(runner_etc_dir)/certs/$lan_ip.crt"
        mkdir -p "$(dirname "$ca_dst")" && cp "$ca_src" "$ca_dst" && chmod 644 "$ca_dst" \
            || die "複製憑證到 $ca_dst 失敗。"
        runner_cert_covers_host "$ca_dst" "$lan_ip" || {
            rm -f "$ca_dst"
            echo "✗ 憑證 $ca_src 的 subjectAltName 沒有涵蓋 $lan_ip（或讀不到憑證）。" >&2
            echo "  job 容器以 $lan_ip 連線，憑證須含 IP:$lan_ip，否則 git clone 會憑證驗證失敗；請用 nginx.sh／install.sh 重簽。" >&2
            exit 1
        }
    fi
    concurrent="$(ask_param RNR_CONCURRENT "同時執行的 job 數（concurrent）" 1 runner_positive_int)" \
        || die "concurrent 須為正整數。"
    images="$(env_get RNR_IMAGES)"
    images="${images:-$RNR_DEFAULT_IMAGES}"
    image="${images%% *}"
    read -rs -p "貼上 Runner token（glrt- 開頭，輸入時不顯示）：" tok || { echo; die "沒有收到 token。"; }
    echo
    [[ $tok =~ ^glrt-[A-Za-z0-9_-]+$ ]] || die "token 格式不符（須為後台建立 Runner 後取得、glrt- 開頭的 token）。"
    args=(register --non-interactive --url "$clone_url" --clone-url "$clone_url" --name "$RNR_NAME"
        --executor docker --docker-image "$image" --docker-pull-policy if-not-present)
    [ -z "$ca_dst" ] || args+=(--tls-ca-file "$ca_dst")
    CI_SERVER_TOKEN="$tok" gitlab-runner "${args[@]}" || die "gitlab-runner register 失敗。"
    runner_set_concurrent "$(runner_config_file)" "$concurrent" || die "寫入 concurrent 失敗。"
    gitlab-runner restart || echo "⚠ gitlab-runner restart 失敗，請手動重啟服務。"
    echo "✓ 已註冊 Runner「$RNR_NAME」（$clone_url）。"
}

# 剩餘空間（KB）：docker 資料目錄所在的磁碟；目錄還不存在時看它的上層。
runner_docker_avail_kb() {
    local dir="${DOCKER_DATA_DIR:-/var/lib/docker}"
    [ -d "$dir" ] || dir="$(dirname "$dir")"
    df -Pk "$dir" | awk 'NR==2 {print $4}'
}

RNR_DISK_MIN_GB=20

runner_default_tarball() { echo "$(sudo_home_dir)/runner-offline.tar.gz"; }

# 【GitLab 伺服器】解包離線包並 dpkg -i；先比對 Runner 與 GitLab 版本、檢查剩餘磁碟，不符都警告並詢問。
runner_install_offline() {
    local tarball dir rc=0 f gl rv avail
    require_machine server
    require_cmds dpkg dpkg-deb tar systemctl df
    require_root
    tarball="$(ask_param RNR_TARBALL "離線包路徑" "$(runner_default_tarball)" valid_local_path)" \
        || die "離線包路徑不合法。"
    [ -f "$tarball" ] || die "找不到離線包：$tarball"
    dir="$(mktemp -d "${TMPDIR:-/tmp}/runner-install.XXXXXX")" || die "建立暫存目錄失敗。"
    # 與 nginx.sh 相同：先複製成私有副本再檢查、解包，避免檢查通過後原檔被換掉（TOCTOU）。
    if ! cp "$tarball" "$dir/offline.tar.gz" || ! check_offline_tar "$dir/offline.tar.gz" \
        || ! tar xzf "$dir/offline.tar.gz" -C "$dir" --no-same-owner; then
        rm -rf "$dir"
        die "離線包無法安全解開：$tarball"
    fi
    rm -f "$dir/offline.tar.gz"
    [ -f "$dir/gitlab-runner_amd64.deb" ] || { rm -rf "$dir"; die "離線包內沒有 gitlab-runner_amd64.deb。"; }

    gl="$(runner_gitlab_version "${GITLAB_OPT_DIR:-/opt/gitlab}/version-manifest.txt")" \
        || { rm -rf "$dir"; die "讀不到 GitLab 版本（version-manifest.txt）。"; }
    rv="$(dpkg-deb -f "$dir/gitlab-runner_amd64.deb" Version)" || { rm -rf "$dir"; die "讀不到 Runner 套件版本。"; }
    if runner_version_mismatch "$gl" "$rv"; then
        echo "⚠ 警告：Runner $rv 與 GitLab $gl 的 major.minor 不一致，官方建議一致，否則可能出現相容問題。"
        confirm "仍要繼續？" || { rm -rf "$dir"; echo "已取消，未做任何變更。"; return 0; }
    fi
    avail="$(runner_docker_avail_kb)"
    if runner_disk_low "$avail" "$RNR_DISK_MIN_GB"; then
        echo "⚠ 警告：docker 資料目錄所在磁碟只剩約 $((avail / 1024 / 1024)) GB，低於 $RNR_DISK_MIN_GB GB；CI 的 image 與 job 容器會吃掉空間，也會擠壓 GitLab。"
        confirm "仍要繼續？" || { rm -rf "$dir"; echo "已取消，未做任何變更。"; return 0; }
    fi

    echo "將以 dpkg -i 安裝下列套件（相依套件若比系統現有的新，可能一併升級系統套件）："
    for f in "$dir"/*.deb; do echo "  ${f##*/}"; done
    if ! confirm "確定安裝？"; then
        rm -rf "$dir"
        echo "已取消，未做任何變更。"
        return 0
    fi
    dpkg -i "$dir"/*.deb || rc=$?
    rm -rf "$dir"
    [ "$rc" -eq 0 ] || { echo "✗ dpkg -i 失敗（結束碼 $rc）；相依套件不足時請見選單「常見問題排查」。" >&2; return "$rc"; }
    systemctl enable --now docker || echo "⚠ 無法啟動 docker 服務，請手動檢查。"
    echo "✓ 已安裝 Docker 與 gitlab-runner。下一步：載入映像包、註冊 Runner。"
}

RNR_DL_BASE="https://gitlab-runner-downloads.s3.amazonaws.com"

valid_runner_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# 在暫存目錄 <stage> 內完成：下載 docker.io 與其相依、gitlab-runner 與 helper images，打包到 <tarball>。
# 在 `|| rc=$?` 條件中被呼叫，set -e 會失效，所以每個會失敗的步驟都明確檢查。
_rnr_build_in() { # _rnr_build_in <stage> <tarball> <runner 版本>
    local stage="$1" tarball="$2" ver="$3" deb pkgs=()
    echo "── 下載 docker.io 與其相依套件 ──"
    mapfile -t pkgs < <(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances docker.io | parse_dep_pkgs) \
        || { echo "✗ 解析 docker.io 的相依失敗。" >&2; return 1; }
    [ "${#pkgs[@]}" -gt 0 ] || { echo "✗ 解析不到任何相依套件。" >&2; return 1; }
    (cd "$stage" && apt-get download "${pkgs[@]}") || { echo "✗ apt-get download 失敗。" >&2; return 1; }
    echo "── 下載 gitlab-runner $ver 與 helper images ──"
    for deb in gitlab-runner_amd64.deb gitlab-runner-helper-images.deb; do
        curl -fsSL "$RNR_DL_BASE/v$ver/deb/$deb" -o "$stage/$deb" \
            || { echo "✗ 下載 $deb 失敗（$RNR_DL_BASE/v$ver/deb/$deb）。請確認這台可連外、版本存在。" >&2; return 1; }
    done
    pack_offline "$stage" "$tarball" || return 1
    echo "✓ 已產生離線包：$tarball（請以 scp 傳到【GitLab 伺服器】）"
}

# 【有網路的電腦】打離線包：docker.io＋相依、gitlab-runner、helper images。
runner_build_offline() {
    local tarball ver stage rc=0
    require_machine online
    require_cmds apt-get apt-cache curl tar
    tarball="$(ask_param RNR_TARBALL "離線包輸出路徑" "$(runner_default_tarball)" valid_local_path)" \
        || die "離線包路徑不合法。"
    ver="$(ask_param RNR_RUNNER_VERSION "要下載的 gitlab-runner 版本（建議與 GitLab 的 major.minor 一致）" "" valid_runner_version)" \
        || die "版本格式須為 X.Y.Z。"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/runner-offline.XXXXXX")" || die "建立暫存目錄失敗。"
    _rnr_build_in "$stage" "$tarball" "$ver" || rc=$?
    rm -rf "$stage"
    return "$rc"
}


# 【有網路的電腦】把 CI 要用的 image 拉下來打成單一映像包（docker save）。
runner_build_images() {
    local tar_file images img rc=0 tmp
    require_machine online
    require_cmds docker
    tar_file="$(ask_param RNR_IMAGES_TAR "映像包輸出路徑" "$(sudo_home_dir)/runner-images.tar" valid_local_path)" \
        || die "映像包路徑不合法。"
    images="$(ask_param RNR_IMAGES "CI 用的 image（空白分隔）" "$RNR_DEFAULT_IMAGES" valid_image_list)" \
        || die "映像清單不合法（只收 image 名稱，不得含空白以外的特殊字元）。"
    for img in $images; do
        docker pull "$img" || die "拉取 $img 失敗。請確認這台可連外。"
    done
    tmp="$(mktemp "$tar_file.XXXXXX")" || die "無法在 $(dirname "$tar_file") 建立暫存檔。"
    # shellcheck disable=SC2086 # images 已通過 valid_image_list，刻意以空白拆開
    docker save -o "$tmp" $images || rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$tmp"; die "docker save 失敗，未產生映像包。"; fi
    chmod 644 "$tmp" && mv -f "$tmp" "$tar_file" || { rm -f "$tmp"; die "無法寫入 $tar_file。"; }
    echo "✓ 已產生映像包：$tar_file（請以 scp 傳到【GitLab 伺服器】）"
}

# 【GitLab 伺服器】載入映像包。
runner_load_images() {
    local tar_file
    require_machine server
    require_cmds docker
    require_root
    tar_file="$(ask_param RNR_IMAGES_TAR "映像包路徑" "$(sudo_home_dir)/runner-images.tar" valid_local_path)" \
        || die "映像包路徑不合法。"
    [ -f "$tar_file" ] || die "找不到映像包：$tar_file"
    docker load -i "$tar_file" || die "docker load 失敗。"
    echo "✓ 已載入映像包。"
}

# 【GitLab 伺服器】取消註冊並移除 Runner（GitLab 後台的 Runner 紀錄須另外手動刪除）。
runner_unregister() {
    require_machine server
    require_cmds gitlab-runner
    require_root
    confirm "將取消註冊 Runner「$RNR_NAME」，之後 CI job 不會再被它執行。" || { echo "已取消，未做任何變更。"; return 0; }
    gitlab-runner unregister --name "$RNR_NAME" || die "unregister 失敗。"
    echo "✓ 已取消註冊。請另外到後台（Admin → CI/CD → Runners）刪除該 Runner 的紀錄。"
}

# 【GitLab 伺服器】手動清理 docker 垃圾（停止的容器、懸空 image、未使用網路）；不加 -a，已載入的 image 不會被刪。
runner_cleanup() {
    require_machine server
    require_cmds docker
    require_root
    confirm "將執行 docker system prune -f（不含仍有標籤的 image）。" || { echo "已取消，未做任何變更。"; return 0; }
    docker system prune -f
}

# 【GitLab 伺服器】驗證：Runner 能連上 GitLab、docker 正常，並印出範例 .gitlab-ci.yml。
runner_verify() {
    require_machine server
    require_cmds gitlab-runner docker
    gitlab-runner verify || die "gitlab-runner verify 失敗：Runner 連不上 GitLab 或 token 無效。見「常見問題排查」。"
    docker info >/dev/null 2>&1 || die "docker info 失敗：docker 服務未在執行？"
    cat <<'YML'
✓ Runner 正常。到任一儲存庫放入下面的 .gitlab-ci.yml 就會由這個 Runner 執行：

hello:
  image: alpine:3.20
  script:
    - echo "hello from runner"
YML
}

# ── 說明與排查 ───────────────────────────────────────────────────────

show_help() {
    cat <<'TXT'
【流程】GitLab 本體不跑 CI，由 Runner 執行。本腳本把 Runner（Docker executor）裝在 GitLab 同一台。
  1. 【有網路的電腦】選 1 打離線套件、選 2 打映像包，用 scp 傳到【GitLab 伺服器】。
  2. 【GitLab 伺服器】選 3 安裝、選 4 載入映像包。
  3. 到 GitLab 後台 Admin → CI/CD → Runners → New instance runner 建立 Runner，取得 glrt- 開頭的 token。
  4. 【GitLab 伺服器】選 5 註冊（貼上 token；token 不落檔）。
  5. 選 6 驗證。
【注意】
  - 與 GitLab 同機，concurrent 預設 1，避免 CI 搶光資源；剩餘磁碟低於 20 GB 會警告。
  - job 容器以區網 IP 連回 GitLab；自簽憑證的 subjectAltName 必須含該 IP。
  - 不開特權；需要在 job 內 docker build 的情境不支援。
TXT
}

show_troubleshooting() {
    cat <<'TXT'
【git clone 出現 x509: certificate signed by unknown authority／certificate is valid for … not …】
  憑證 SAN 沒涵蓋 job 容器連線用的 IP，或 CA 沒交給 Runner。重簽含 IP 的憑證後，重新註冊（先取消註冊）。
【job 卡在 pending】
  Runner 未上線（選 6 驗證）、concurrent 已滿，或儲存庫的 job 要求了 Runner 沒有的 tag。
【image 拉不到：pull access denied／no such host】
  斷網環境不會線上拉取；該 image 不在映像包內。到【有網路的電腦】加進清單重打映像包，再選 4 載入。
【dpkg -i 相依錯誤】
  離線包缺相依；在【有網路的電腦】重新打包（選 1）。
【Runner 與 GitLab 版本不一致警告】
  升級 GitLab 後請重打離線包安裝相同 major.minor 的 gitlab-runner。
TXT
}

# ── 選單 ─────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== GitLab Runner（CI，離線）===
  1) 準備離線套件並打包            【有網路的電腦】
  2) 準備映像包（docker save）     【有網路的電腦】
  3) 解包並安裝 Docker／Runner     【GitLab 伺服器】
  4) 載入映像包（docker load）     【GitLab 伺服器】
  5) 註冊 Runner                   【GitLab 伺服器】
  6) 驗證                          【GitLab 伺服器】
  7) 取消註冊並移除 Runner         【GitLab 伺服器】
  8) 清理 docker 垃圾              【GitLab 伺服器】
  9) 說明                          【有網路的電腦】【GitLab 伺服器】
  10) 常見問題排查                 【有網路的電腦】【GitLab 伺服器】
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) runner_build_offline ;;
        2) runner_build_images ;;
        3) runner_install_offline ;;
        4) runner_load_images ;;
        5) runner_register ;;
        6) runner_verify ;;
        7) runner_unregister ;;
        8) runner_cleanup ;;
        9) show_help ;;
        10) show_troubleshooting ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

valid_http_url() { runner_url_scheme "$1" >/dev/null; }
runner_positive_int() { [[ $1 =~ ^[1-9][0-9]*$ ]]; }

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_rnr_dir")"
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
