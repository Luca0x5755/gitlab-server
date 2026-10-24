#!/usr/bin/env bash
# GitLab 容器（Docker）選單腳本：打包與載入 GitLab 映像包。只有互動選單，不收參數。
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得函式而不啟動選單。
#
# 遷移（deb → GitLab 容器）見 docker_migrate、逐站升級見 docker_upgrade；說明與排查見選單 8、9。

_glc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_glc_dir/lib/common.sh"

# 升級路徑上的停靠站（各 minor 的最新 patch，依 Upgrade Path Tool）；可由 ask_param 修改。
GLC_DEFAULT_VERSIONS="18.10.3 18.11.13 19.2.9 19.5.1"
# 映像 tag 的後綴固定 -ce.0（使用者輸入 18.10.3 時自動補上）。
GLC_TAG_SUFFIX="-ce.0"

# ── 純函式 ───────────────────────────────────────────────────────────────────

# 單一版本補成 X.Y.Z-ce.N 形式（已帶 -ce.N 的不動）。不驗證，交給 valid_gitlab_version。
_glc_with_suffix() {
    case "$1" in
        *-ce.*) echo "$1" ;;
        *) echo "$1$GLC_TAG_SUFFIX" ;;
    esac
}

# 映像參照：gitlab/gitlab-ce:<版本>-ce.N。版本須是完整 X.Y.Z-ce.N，否則回非 0。
docker_image_ref() { # docker_image_ref <X.Y.Z-ce.N>
    valid_gitlab_version "$1" || return 1
    echo "gitlab/gitlab-ce:$1"
}

# 空白分隔的版本清單 → 每行一個 X.Y.Z-ce.N，依數值由小到大、去重。
# 清單為空或任一項非法：回非 0 且不輸出任何 tag（寧可中止也不要少拉一版）。
docker_normalize_versions() { # docker_normalize_versions "<清單>"
    local v n=0 list=""
    for v in $1; do
        v="$(_glc_with_suffix "$v")"
        valid_gitlab_version "$v" || { echo "✗ 版本格式不符：$v" >&2; return 1; }
        list+="$v"$'\n'
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || { echo "✗ 版本清單是空的。" >&2; return 1; }
    printf '%s' "$list" | sort_versions asc | awk '!seen[$0]++'
}

# 官方映像只有 C／C.utf8／en_US.utf8。deb 時代建的資料庫若用其他 LC_COLLATE（例如 zh_TW.UTF-8），
# 容器內 PostgreSQL 會報 `database locale is incompatible with operating system` 而起不來。
# 伺服器沒有網路，所以在【有網路的電腦】把 locale 烤進映像（同 tag 覆蓋），隨映像包一起帶過去。
GLC_DB_LOCALE="${GLC_DB_LOCALE:-zh_TW.UTF-8}"

# 在官方映像上加裝 locale 的 Dockerfile（stdout）。安裝 locales 套件會重建 locale 資料而洗掉原有的 en_US.utf8，
# 所以一併補回，讓新映像是原映像的超集。locale 須為 語言_地區.編碼 形式，否則回非 0。
docker_locale_dockerfile() { # docker_locale_dockerfile <映像參照> <locale>
    local ref="$1" loc="$2" name charmap
    [[ $loc =~ ^[A-Za-z]+_[A-Za-z]+\.[A-Za-z0-9-]+$ ]] || return 1
    [ -n "$ref" ] || return 1
    name="${loc%%.*}"
    charmap="${loc#*.}"
    cat <<DOCKERFILE
FROM $ref
RUN apt-get update \\
 && apt-get install -y --no-install-recommends locales \\
 && localedef -i $name -f $charmap $loc \\
 && localedef -i en_US -f UTF-8 en_US.UTF-8 \\
 && locale -a | grep -qi '^${name}\\.${charmap//-/}\$' \\
 && locale -a | grep -qi '^en_US\\.utf8\$' \\
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
}

# ask_param 用的驗證函式：清單合法回 0。
valid_docker_version_list() { docker_normalize_versions "$1" >/dev/null 2>&1; }


# ── 遷移用純函式（ISSUE-004）─────────────────────────────────────────────────

# 三個掛載目錄（GLOSSARY），宿主機與容器路徑相同；逐行輸出 `-v` 與 `src:dst`。
GLC_MOUNT_DIRS="${GLC_MOUNT_DIRS:-/etc/gitlab /var/opt/gitlab /var/log/gitlab}"
docker_mount_args() {
    local d
    for d in $GLC_MOUNT_DIRS; do printf '%s\n%s\n' "-v" "$d:$d"; done
}

# `docker run` 後面的整串參數，一行一個（值都不含空白）。容器名 gitlab、--restart always、
# --shm-size 256m、發佈 80／443 與 Git SSH 埠 2222→22（宿主機 sshd 的 22 不動）。
docker_run_args() { # docker_run_args <映像參照>
    [ -n "${1:-}" ] || return 1
    printf '%s\n' -d --name gitlab --restart always --shm-size 256m \
        -p 80:80 -p 443:443 -p "$GLC_SSH_PORT:22"
    docker_mount_args
    printf '%s\n' "$1"
}


# 遷移時移除的外部 Nginx 管理區塊（名稱與 nginx.sh 的 NGX_EXT_BLOCK 相同）與新增的 Git SSH 埠區塊。
GLC_NGX_BLOCK="nginx_external"
GLC_SSH_BLOCK="docker_ssh_port"
GLC_SSH_PORT=2222

# 遷移後的 gitlab.rb 全文（stdout，不寫檔）：先移除外部 Nginx 區塊，再以管理區塊設定 Git SSH 埠。
# 重用 common.sh 的 strip_block／replace_block；標記毀損或讀不到檔案回非 0 且不輸出。
docker_migrate_rb_content() { # docker_migrate_rb_content <gitlab.rb>
    local stripped tmp rc=0
    # 結尾補 x 保住最後的換行；strip_block 的結束碼要在子 shell 內帶出來。
    stripped="$(strip_block "$1" "$GLC_NGX_BLOCK" && echo x)" || return 1
    tmp="$(umask 077 && mktemp)" || return 1
    printf '%s' "${stripped%x}" >"$tmp"
    replace_block "$tmp" "$GLC_SSH_BLOCK" "gitlab_rails['gitlab_shell_ssh_port'] = $GLC_SSH_PORT" || rc=$?
    rm -f "$tmp"
    return "$rc"
}

# `ss -Hltn` 輸出（stdin）中監聽 80、443 或 2222 的列（本機位址欄以 :埠 結尾）。
docker_busy_listeners() { awk '$4 ~ /:(80|443|2222)$/'; }

# 取 gitlab.rb 中最後一個未註解的 external_url（去掉引號）；沒有回非 0。
docker_external_url() { # docker_external_url <gitlab.rb>
    local url
    url="$(sed -n -E "s/^[[:space:]]*external_url[[:space:]]+['\"]([^'\"]+)['\"].*/\1/p" "$1" 2>/dev/null | tail -n1)"
    [ -n "$url" ] || return 1
    echo "$url"
}

# deb 版本與要啟動的映像 tag 相同才回 0（兩者都須是合法版本）。
docker_version_matches() { # docker_version_matches <deb 版本> <tag>
    [ "$(version_cmp "$1" "$2" 2>/dev/null)" = 0 ]
}

# 位元組數 → 人看的大小（1024 進位，B／KiB／MiB／GiB／TiB）。
format_bytes() { # format_bytes <位元組>
    awk -v b="$1" 'BEGIN {
        if (b < 1024) { printf "%d B\n", b; exit }
        split("KiB MiB GiB TiB", u, " "); v = b; i = 0
        while (v >= 1024 && i < 4) { v /= 1024; i++ }
        printf "%.1f %s\n", v, u[i]
    }'
}

# HTTP 狀態碼 2xx／3xx 視為服務有回應（GitLab 首頁會 302 到登入頁）。
http_status_ok() { [[ $1 =~ ^[23][0-9][0-9]$ ]]; }

# ── 遷移動作（ISSUE-004；每個階段獨立成函式，失敗即 die 並說明）──────────────────

# deb 安裝的 gitlab-ce 版本；獨立成函式讓測試能換掉。
docker_deb_version() { dpkg-query -W -f='${Version}\n' gitlab-ce; }

# 資料目錄（含 git-data/repositories）；GLC_DATA_DIR 供測試覆寫。
glc_data_dir() { echo "${GLC_DATA_DIR:-/var/opt/gitlab}"; }

# PR-DKR-10 前置檢查：deb 版本等於要啟動的映像 tag、Docker 已安裝、映像已載入。
# 另擋兩個會讓容器起不來的狀況：已有名為 gitlab 的容器、git-data/repositories 不是真目錄。
docker_preflight() { # docker_preflight <tag>
    local tag="$1" ref deb repos
    ref="$(docker_image_ref "$tag")" || die "前置檢查失敗：映像 tag 不合法：$tag"
    have_cmd docker || die "前置檢查失敗：Docker 未安裝。請先執行選單 4 安裝 Docker。"
    deb="$(docker_deb_version)" || die "前置檢查失敗：讀不到 deb 安裝的 gitlab-ce 版本。這個動作只適用 deb 安裝的 GitLab。"
    docker_version_matches "$deb" "$tag" \
        || die "前置檢查失敗：deb 版本（$deb）與要啟動的映像 tag（$tag）不同。版本必須一致才能沿用掛載目錄。"
    docker image inspect "$ref" >/dev/null 2>&1 \
        || die "前置檢查失敗：映像 $ref 尚未載入。請先執行選單 2 載入 GitLab 映像包。"
    [ -z "$(docker ps -a --filter name=^gitlab$ --format '{{.Names}}')" ] \
        || die "前置檢查失敗：已有名為 gitlab 的容器。請先確認它的狀況（docker ps -a），本動作不覆蓋既有容器。"
    repos="$(glc_data_dir)/git-data/repositories"
    [ -d "$repos" ] \
        || die "前置檢查失敗：$repos 不存在或是壞掉的 symlink，容器啟動會報 stat: missing operand。請先修好再重試。"
    echo "✓ 前置檢查通過：deb $deb、映像 $ref 已載入。"
}


# 機外備份確認字串（不是密碼，不需隱藏）。
GLC_OFFSITE_PHRASE="offsite-copied"

# 呼叫現有 backup_auto.sh（deb 還活著，所以仍是 deb 模式）；獨立成函式讓測試能換掉。
docker_run_backup() { bash "$_glc_dir/backup_auto.sh"; }

# <目錄> 內符合 <樣式>、且比 <標記檔> 新的最新檔案路徑；沒有回非 0。
# 要求比標記新：backup_auto.sh 就算回 0 卻什麼都沒寫，也不會把舊備份當成剛做好的。
_glc_newest() { # _glc_newest <目錄> <樣式> <標記檔>
    local f best=""
    for f in "$1"/$2; do
        [ -f "$f" ] && [ "$f" -nt "$3" ] || continue
        if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
    done
    [ -n "$best" ] || return 1
    echo "$best"
}

# PR-DKR-11：備份 → 列出兩個檔案的路徑與大小 → 要求輸入確認字串。任一步失敗即中止，此時還沒動 deb 版。
docker_backup_stage() {
    local data cfg ans="" mark rc=0
    echo "══ 備份 ══"
    mark="$(mktemp)" || die "備份失敗：無法建立暫存檔，deb 版未被更動。"
    # 以 mtime 標記區分「這次做的」與舊備份。
    docker_run_backup || rc=$?
    if [ "$rc" -eq 0 ]; then
        data="$(_glc_newest "$(data_backup_dir)" '*_gitlab_backup.tar' "$mark")" || rc=data
        [ "$rc" != 0 ] || cfg="$(_glc_newest "$(config_backup_dir)" 'gitlab_config_*.tar' "$mark")" || rc=cfg
    fi
    rm -f "$mark"
    case "$rc" in
        0) ;;
        data) die "備份失敗：在 $(data_backup_dir) 找不到這次產生的資料備份，已中止，deb 版未被更動。" ;;
        cfg) die "備份失敗：在 $(config_backup_dir) 找不到這次產生的設定備份，已中止，deb 版未被更動。" ;;
        *) die "備份失敗（結束碼 $rc），已中止，deb 版未被更動。請先排除備份問題。" ;;
    esac
    echo "資料備份：$data（$(format_bytes "$(stat -c %s "$data")")）"
    echo "設定備份：$cfg（$(format_bytes "$(stat -c %s "$cfg")")）"
    echo "⚠ 這台沒有退路。請把上面兩個檔案複製到這台機器以外的地方（兩者缺一不可）。"
    read -r -p "已複製到機外？輸入 $GLC_OFFSITE_PHRASE 繼續：" ans || true
    [ "$ans" = "$GLC_OFFSITE_PHRASE" ] || die "未輸入確認字串，已中止，deb 版未被更動。"
    echo "✓ 備份完成並已確認複製到機外。"
}


# PR-DKR-12：移除 nginx.sh 的管理區塊、設定 Git SSH 埠 2222。只備份一次、直接寫入，
# 不在宿主機 reconfigure（deb 即將停用，設定由容器啟動時套用）。不動 external_url 與 ssl。
docker_edit_gitlab_rb() {
    local f new
    f="$(gitlab_rb_file)"
    echo "══ 改 gitlab.rb ══"
    new="$(umask 077 && mktemp)" || die "改 gitlab.rb 失敗：無法建立暫存檔。"
    if ! docker_migrate_rb_content "$f" >"$new"; then
        rm -f "$new"
        die "改 gitlab.rb 失敗：無法產生新內容（檔案不存在或管理區塊標記毀損），gitlab.rb 未被更動。"
    fi
    if ! backup_gitlab_rb; then
        rm -f "$new"
        die "改 gitlab.rb 失敗：備份失敗，gitlab.rb 未被更動。"
    fi
    if ! write_file_from "$new" "$f"; then
        rm -f "$new"
        restore_gitlab_rb "$LAST_GITLAB_RB_BAK" || true
        die "改 gitlab.rb 失敗：寫入失敗，已嘗試由備份還原。"
    fi
    rm -f "$new"
    echo "✓ 已移除外部 Nginx 區塊並設定 gitlab_shell_ssh_port = $GLC_SSH_PORT。"
}

# PR-DKR-13：停 deb 版並停用開機服務，再確認 80、443、2222 未被占用。
docker_stop_deb() {
    local busy out
    echo "══ 停止 deb 版 GitLab ══"
    gitlab-ctl stop || die "停止 deb 版失敗（gitlab-ctl stop）。"
    systemctl disable --now gitlab-runsvdir || die "停用 deb 版開機服務（gitlab-runsvdir）失敗。此時 deb 版已停止、gitlab.rb 已改；請手動停用該服務並確認 80／443／2222 空閒後，從啟動容器接續。"
    have_cmd ss || die "缺少指令 ss，無法確認 80／443／2222 已釋放。"
    out="$(ss -Hltn)" || die "ss 執行失敗，無法確認 80/443/2222 已釋放。"
    busy="$(docker_busy_listeners <<<"$out")"
    if [ -n "$busy" ]; then
        echo "✗ 80、443 或 2222 仍被佔用：" >&2
        printf '%s\n' "$busy" | sed 's/^/  /' >&2
        die "請先停掉佔用的程式再重試（sudo ss -tlnp 可看是誰）。"
    fi
    echo "✓ deb 版已停止，80、443、2222 空閒。"
}

# PR-DKR-14：以暫時容器掛三個掛載目錄跑 update-permissions，對齊 UID。不手動 chown。
docker_align_permissions() { # docker_align_permissions <映像參照>
    local args=()
    echo "══ 對齊權限 ══"
    mapfile -t args < <(docker_mount_args)
    docker run --rm "${args[@]}" "$1" update-permissions \
        || die "對齊權限失敗（update-permissions）。請勿手動 chown 成 root:root；見 docker logs 或說明。"
    echo "✓ 權限已對齊。"
}

# PR-DKR-15：以純函式組裝的參數啟動 GitLab 容器。
docker_start_container() { # docker_start_container <映像參照>
    local args=()
    echo "══ 啟動 GitLab 容器 ══"
    mapfile -t args < <(docker_run_args "$1")
    docker run "${args[@]}" || die "啟動容器失敗（docker run）。"
    echo "✓ 已啟動容器 gitlab。"
}

# PR-DKR-16：輪詢到容器 healthy 才算成功；容器已結束或逾時即失敗並指向 docker logs gitlab。
# 間隔與次數可由 GLC_HEALTH_INTERVAL（預設 10 秒）、GLC_HEALTH_MAX（預設 90 次）調整。
docker_wait_healthy() {
    local interval="${GLC_HEALTH_INTERVAL:-10}" max="${GLC_HEALTH_MAX:-90}" i out state health
    echo "══ 等待容器健康 ══"
    for ((i = 1; i <= max; i++)); do
        out="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' gitlab 2>/dev/null)" || out=""
        state="${out%% *}"
        health="${out#* }"
        if [ "$health" = healthy ]; then
            echo "✓ 容器已健康。"
            return 0
        fi
        case "$state" in
            exited | dead | removing)
                die "容器已結束（$state）。請看 docker logs gitlab 找原因。"
                ;;
        esac
        echo "  第 $i 次：${out:-（讀不到狀態）}，等待中..."
        [ "$i" -ge "$max" ] || sleep "$interval"
    done
    die "等了 $max 次容器仍不健康，已停止。請看 docker logs gitlab 找原因。"
}

# PR-DKR-17：容器內 gitlab:check，再 curl -kI external_url（自簽憑證所以 -k）；狀態碼 2xx／3xx 才通過。
docker_verify() {
    local url code
    echo "══ 驗證 ══"
    url="$(docker_external_url "$(gitlab_rb_file)")" || die "驗證失敗：在 $(gitlab_rb_file) 找不到 external_url。"
    docker exec gitlab gitlab-rake gitlab:check || die "驗證失敗：gitlab:check 未通過。"
    code="$(curl -ksI --max-time 30 -o /dev/null -w '%{http_code}' "$url")" || code="000"
    http_status_ok "$code" || die "驗證失敗：curl -kI $url 回應 $code（需 2xx／3xx）。"
    env_set GLC_VERIFIED_AT "$(glc_now_epoch)" # 驗證通過才記下時間，供 purge 判斷「剛通過」
    echo "✓ gitlab:check 通過，$url 回應 $code。"
}


# ── purge 用純函式（ISSUE-006）───────────────────────────────────────────────

# 驗證「剛通過」：戳記（epoch 秒）存在、是數字、不在未來、距現在不超過時限才回 0。
docker_verify_fresh() { # docker_verify_fresh <戳記> <現在> <最長秒數>
    [[ ${1:-} =~ ^[0-9]+$ ]] || return 1
    [ "$1" -le "$2" ] && [ $(($2 - $1)) -le "$3" ]
}

# purge 前後的掛載目錄清單（每行一個項目）比對：輸出 purge 前有、purge 後沒有的項目。
docker_dirs_lost() { # docker_dirs_lost <前清單> <後清單>
    comm -23 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u)
}

# 掛載目錄仍在的判斷：purge 前清單不能是空的（空清單無從比較，不能當作安全），且沒有任何項目消失才回 0。
docker_dirs_lost_check() { # docker_dirs_lost_check <前清單> <後清單>
    [ -n "$(printf '%s' "$1" | sed '/^$/d')" ] || return 1
    [ -z "$(docker_dirs_lost "$1" "$2")" ]
}


# ── 逐站升級用純函式（ISSUE-007）─────────────────────────────────────────────

# 決定要升哪些站。參數：目前容器的 tag、已載入的 tag 清單（一行一個）。
# stdout：數值上比目前版本高的 tag，由小到大、去重（18.9 < 18.10）。
# stderr：略過者（不高於目前版本）逐行說明。任一版本非法回非 0 且不輸出：寧可中止也不要猜。
docker_upgrade_plan() { # docker_upgrade_plan <目前 tag> <已載入 tag 清單>
    local cur="$1" sorted t keep=""
    valid_gitlab_version "$cur" || { echo "✗ 目前版本格式不符：$cur" >&2; return 1; }
    # 排序與去重分兩步：sort_versions 的失敗不能被管線尾端的 awk 蓋掉。
    sorted="$(printf '%s\n' "$2" | sed '/^$/d' | sort_versions asc)" || return 1
    sorted="$(printf '%s\n' "$sorted" | awk '!seen[$0]++')"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        if [ "$(version_cmp "$t" "$cur")" = 1 ]; then
            keep+="$t"$'\n'
        else
            echo "略過 $t：不高於目前版本 $cur。" >&2
        fi
    done <<<"$sorted"
    printf '%s' "$keep"
}

# 由映像參照 gitlab/gitlab-ce:<tag> 取出 tag；不是 gitlab-ce 映像或 tag 不合法回非 0。
docker_tag_from_image() { # docker_tag_from_image <映像參照>
    local tag="${1#gitlab/gitlab-ce:}"
    [ "$tag" != "$1" ] && valid_gitlab_version "$tag" || return 1
    echo "$tag"
}

# 該站是否為 18.11（啟動時會自動升級 PostgreSQL，PR-DKR-23）。
docker_station_needs_pg_warning() { # docker_station_needs_pg_warning <站 tag>
    [[ $1 =~ ^18\.11\.[0-9]+-ce\.[0-9]+$ ]]
}

# 由 `df -Pk` 輸出取剩餘空間（人看的大小）；讀不到回非 0。
docker_free_space_line() { # docker_free_space_line <df -Pk 輸出>
    local kb
    kb="$(printf '%s\n' "$1" | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }')"
    [ -n "$kb" ] || return 1
    format_bytes "$((kb * 1024))"
}

# ── 逐站升級動作（ISSUE-007）─────────────────────────────────────────────────
# 未驗證：以下流程只用假 docker 測過，沒有在真實環境升級過（真實 docker 升級與 18.11 的
# PostgreSQL 自動升級無法無人值守執行）。部署前須在 WSL／VM 以實際映像包走一遍。

# 背景遷移查詢式（容器內 gitlab-rails runner）；與 upgrade.sh 的 deb 版相同。
GLC_QUEUED_EXPR='puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count'

# 目前 gitlab 容器的版本 tag；沒有容器或不是 gitlab-ce 映像回非 0。獨立成函式讓測試能換掉。
docker_current_tag() {
    local img
    img="$(docker inspect -f '{{.Config.Image}}' gitlab 2>/dev/null)" || return 1
    docker_tag_from_image "$img"
}

# 已載入的 gitlab/gitlab-ce tag（一行一個，只留合法版本）。
docker_loaded_tags() {
    local t
    for t in $(docker images gitlab/gitlab-ce --format '{{.Tag}}'); do
        valid_gitlab_version "$t" && echo "$t"
    done
    return 0
}

# PR-DKR-24：輪詢容器內背景遷移佇列直到 0。間隔與次數沿用 upgrade.sh 的 UPG_POLL_INTERVAL（預設 30 秒）、
# UPG_POLL_MAX（預設 120 次）。讀不到數字不當作 0。逾時回非 0 並指向 sidekiq 日誌。
docker_upgrade_wait_migrations() {
    local interval="${UPG_POLL_INTERVAL:-30}" max="${UPG_POLL_MAX:-120}" i out n="" last=""
    echo "等待背景遷移歸零（queued.count 須為 0）..."
    for ((i = 1; i <= max; i++)); do
        out="$(docker exec gitlab gitlab-rails runner -e production "$GLC_QUEUED_EXPR" 2>&1)" || true
        if n="$(parse_queued_count <<<"$out")"; then
            last="$n"
            if [ "$n" = 0 ]; then
                echo "  背景遷移已歸零。"
                return 0
            fi
            echo "  第 $i 次：仍有 $n 個背景遷移在佇列中..."
        else
            last="（無法讀取）"
            echo "  第 $i 次：讀不到佇列數量（服務可能還沒起來）..."
        fi
        [ "$i" -ge "$max" ] || sleep "$interval"
    done
    echo "✗ 等了 $max 次仍未歸零（最後一次：$last）。已停止，未升級下一站。" >&2
    echo "  請看 sidekiq 日誌：docker exec gitlab gitlab-ctl tail sidekiq（宿主機 /var/log/gitlab/sidekiq/current）；" >&2
    echo "  歸零後重跑選單 7 即可接續（以目前容器版本為準）。" >&2
    return 1
}

# 升一站（PR-DKR-21／22／24）：備份 → 停止並移除舊容器（不動掛載目錄）→ 以新 tag 與同一組參數重建
# → 等健康 → 等背景遷移歸零。任一步失敗即 die。備份失敗時舊容器完全沒動。
docker_upgrade_station() { # docker_upgrade_station <站 tag>
    local tag="$1" ref
    ref="$(docker_image_ref "$tag")" || die "站版本不合法：$tag"
    echo "══ 升級到 $tag ══"
    docker_run_backup || die "升級前備份失敗（結束碼 $?），已中止，容器 gitlab 未被更動。請先排除備份問題。"
    # 停止逾時預設 300 秒（GLC_STOP_TIMEOUT 可調）：預設 10 秒可能在資料庫關閉前就強殺。
    docker stop -t "${GLC_STOP_TIMEOUT:-300}" gitlab || die "停止容器 gitlab 失敗。"
    docker rm gitlab || die "移除舊容器 gitlab 失敗（掛載目錄未動）。"
    docker_start_container "$ref"
    docker_wait_healthy
    docker_upgrade_wait_migrations || die "背景遷移未歸零，已停止在 $tag。"
    echo "✓ 已升級到 $tag。"
}

# ── 動作 ─────────────────────────────────────────────────────────────────────

# 【有網路的電腦】依版本清單逐一 docker pull，再 docker save 成單一 GitLab 映像包。
# 任一 pull 失敗、或 save 失敗，都不留下 tar（先寫暫存檔，成功才 mv 到位）。
docker_build_bundle() {
    local versions tag ref tar_file tmp rc=0 refs=() tags
    require_machine online
    require_cmds docker
    versions="$(ask_param GLC_VERSIONS "GitLab 版本清單（空白分隔）" "$GLC_DEFAULT_VERSIONS" valid_docker_version_list)" \
        || die "版本清單不合法（須為 X.Y.Z 形式，例如 18.10.3，以空白分隔）。"
    tar_file="$(ask_param GLC_BUNDLE_TAR "GitLab 映像包輸出路徑" "$(sudo_home_dir)/gitlab-images.tar" valid_local_path)" \
        || die "映像包路徑不合法。"
    tags="$(docker_normalize_versions "$versions")" || die "版本清單不合法。"
    # 先全部 pull 完才 save：任何一版失敗就在這裡中止，不會有 tar。
    # 以陣列＋for 迭代而不用 while read：避免 docker 子程序吞掉迴圈的 stdin。
    for tag in $tags; do refs+=("$(docker_image_ref "$tag")"); done
    for ref in "${refs[@]}"; do
        docker pull "$ref" || die "拉取 $ref 失敗。請確認這台可連外、該版本存在。"
    done
    # 補上資料庫 locale：同 tag 覆蓋，之後 docker save 存的就是加料後的映像。
    for ref in "${refs[@]}"; do
        echo "══ 補上 locale $GLC_DB_LOCALE：$ref ══"
        docker_locale_dockerfile "$ref" "$GLC_DB_LOCALE" | docker build -t "$ref" - \
            || die "補 locale 失敗（$ref）。請確認這台可連外，且 GLC_DB_LOCALE（$GLC_DB_LOCALE）格式為 zh_TW.UTF-8。"
    done
    tmp="$(mktemp "$tar_file.XXXXXX")" || die "無法在 $(dirname "$tar_file") 建立暫存檔。"
    docker save -o "$tmp" "${refs[@]}" || rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$tmp"; die "docker save 失敗，未產生映像包。"; fi
    chmod 644 "$tmp" && mv -f "$tmp" "$tar_file" || { rm -f "$tmp"; die "無法寫入 $tar_file。"; }
    echo "✓ 已產生 GitLab 映像包：$tar_file（請以 scp 傳到【GitLab 伺服器】）"
}

# 【GitLab 伺服器】docker load 載入 GitLab 映像包，並列出已有的 gitlab/gitlab-ce tag。
# 用 ubuntu 角色而非 server：purge 舊 deb 後 /opt/gitlab 不在了，下一批映像包仍要能載入。
docker_load_bundle() {
    local tar_file
    require_machine ubuntu docker
    require_root
    tar_file="$(ask_param GLC_BUNDLE_TAR "GitLab 映像包路徑" "$(sudo_home_dir)/gitlab-images.tar" valid_local_path)" \
        || die "映像包路徑不合法。"
    [ -f "$tar_file" ] || die "找不到映像包：$tar_file"
    docker load -i "$tar_file" || die "docker load 失敗。"
    echo "已有的 gitlab/gitlab-ce 映像："
    docker images gitlab/gitlab-ce || die "無法列出映像。"
    echo "✓ 已載入 GitLab 映像包。"
}

# 【有網路的電腦】打 Docker 離線包：docker.io 與其全部相依的 .deb（解析與下載是與 runner.sh 共用的
# docker_download_debs）。檔名預設 docker-offline.tar.gz，與 runner.sh 的 runner-offline.tar.gz 分開，不互相覆蓋。
docker_build_offline() {
    local tarball stage rc=0
    require_machine online
    require_cmds apt-get apt-cache tar
    tarball="$(ask_param GLC_DOCKER_TAR "Docker 離線包輸出路徑" "$(sudo_home_dir)/docker-offline.tar.gz" valid_local_path)" \
        || die "離線包路徑不合法。"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/docker-offline.XXXXXX")" || die "建立暫存目錄失敗。"
    # 在 `|| rc=$?` 內 set -e 會失效，所以每步都明確檢查。
    if docker_download_debs "$stage" && pack_offline "$stage" "$tarball"; then
        echo "✓ 已產生 Docker 離線包：$tarball（請以 scp 傳到【GitLab 伺服器】）"
    else
        rc=1
    fi
    rm -rf "$stage"
    return "$rc"
}

# 【GitLab 伺服器】解開 Docker 離線包、dpkg -i 安裝並啟用 docker 服務。
# 用 ubuntu 角色：安裝 Docker 發生在 GitLab 容器之前，不要求 /opt/gitlab。
docker_install_offline() {
    local tarball dir rc=0
    require_machine ubuntu dpkg tar systemctl
    require_root
    tarball="$(ask_param GLC_DOCKER_TAR "Docker 離線包路徑" "$(sudo_home_dir)/docker-offline.tar.gz" valid_local_path)" \
        || die "離線包路徑不合法。"
    [ -f "$tarball" ] || die "找不到離線包：$tarball"
    dir="$(mktemp -d "${TMPDIR:-/tmp}/docker-install.XXXXXX")" || die "建立暫存目錄失敗。"
    unpack_offline_tar "$tarball" "$dir" || { rm -rf "$dir"; die "離線包無法安全解開：$tarball"; }
    install_debs_in "$dir" || rc=$?
    rm -rf "$dir"
    [ "$rc" -ne 100 ] || return 0 # 使用者取消：已說明，不算失敗
    [ "$rc" -eq 0 ] || return "$rc"
    docker_enable_service
    echo "✓ 已安裝 Docker。下一步：載入 GitLab 映像包。"
}

# ask_param 用的驗證函式：起始 tag 可帶或不帶 -ce.N 後綴。
valid_docker_start_tag() { valid_gitlab_version "$(_glc_with_suffix "$1")"; }

# 【GitLab 伺服器】deb → GitLab 容器（沿用掛載目錄）。依序：前置檢查、確認、備份、改 gitlab.rb、
# 停 deb、對齊權限、啟動、等健康、驗證；任一步失敗即中止（各階段 die 並說明）。
# 用 server 角色：此時 deb 必須還在（/opt/gitlab 存在）；purge 之後的動作（ISSUE-006）不走這裡。
# 本函式結束時 deb 套件仍在，GitLab 已由容器服務。
docker_migrate() {
    local tag ref
    require_machine server
    require_root
    tag="$(ask_param GLC_START_TAG "要啟動的映像版本（須與 deb 版本相同）" "$(_glc_with_suffix "${GLC_DEFAULT_VERSIONS%% *}")" valid_docker_start_tag)" \
        || die "映像版本不合法（須為 X.Y.Z 形式，例如 18.10.3）。"
    tag="$(_glc_with_suffix "$tag")"
    ref="$(docker_image_ref "$tag")" || die "映像版本不合法：$tag"
    docker_preflight "$tag"
    echo "將把 deb 安裝的 GitLab 遷移到容器 $ref（沿用 /etc/gitlab、/var/opt/gitlab、/var/log/gitlab）："
    echo "  備份 → 改 gitlab.rb → 停 deb 版 → 啟動容器 → 驗證。GitLab 會中斷數分鐘；deb 套件此步不移除。"
    confirm "確定開始遷移？" || { echo "已取消，未做任何變更。"; return 0; }
    docker_backup_stage
    docker_edit_gitlab_rb
    docker_stop_deb
    docker_align_permissions "$ref"
    docker_start_container "$ref"
    docker_wait_healthy
    docker_verify
    echo "✓ 遷移完成：GitLab 已由容器 $ref 服務（deb 套件仍在）。"
}


# 確認目前容器健康、背景遷移已歸零，再跑最終檢查並顯示版本（PR-DKR-24／25）。
# 重跑時也走這裡：上次可能中斷在某站的「等健康／等背景遷移」，那一站的容器已是新版本，
# 不先確認就進下一站，會在背景遷移未完成時繼續升級。
docker_upgrade_finish() {
    docker_wait_healthy
    docker_upgrade_wait_migrations || die "目前容器的背景遷移未歸零，已停止。"
    echo "══ 最終檢查 ══"
    docker exec gitlab gitlab-rake gitlab:check SANITIZE=true || die "gitlab:check 未通過，請看上面的輸出。"
    echo "✓ 升級完成：目前版本 $(docker_current_tag || echo "（讀不到）")。"
}

# 【GitLab 伺服器】逐站升級 GitLab 容器（PR-DKR-20／23／25）。以目前容器版本為準，只升數值上更高的已載入映像；
# 中斷後重跑自然略過已完成的站。腳本不猜停靠站：已載入哪些版本由映像包決定（人查 Upgrade Path Tool）。
# 用 ubuntu 角色：舊 deb 可能已 purge，/opt/gitlab 不在。實測狀態見上方「未驗證」註記。
docker_upgrade() {
    local cur plan tag n
    require_machine ubuntu docker
    require_root
    cur="$(docker_current_tag)" || die "讀不到容器 gitlab 的版本（容器不存在或不是 gitlab/gitlab-ce 映像）。請先完成遷移。"
    plan="$(docker_upgrade_plan "$cur" "$(docker_loaded_tags)")" || die "無法決定升級順序（版本字串不合法）。"
    if [ -z "$plan" ]; then
        echo "沒有比目前版本（$cur）更高的已載入映像，不需要升級；僅確認背景遷移與最終檢查。要升級請先載入映像包（選單 2）。"
        docker_upgrade_finish
        return 0
    fi
    echo "目前版本：$cur。將依序升級："
    n=0
    for tag in $plan; do n=$((n + 1)); echo "  $n. $tag"; done
    echo "每一站都會先備份、再停止並重建容器、等背景遷移歸零；GitLab 在每一站會中斷數分鐘。"
    confirm "確定開始逐站升級？" || { echo "已取消，未做任何變更。"; return 0; }
    # 重跑時目前容器可能是上次中斷的那一站：它的背景遷移要先歸零才能進下一站（PR-DKR-24）。
    docker_upgrade_wait_migrations || die "目前容器的背景遷移未歸零，未升級下一站。"
    for tag in $plan; do
        if docker_station_needs_pg_warning "$tag"; then
            echo "⚠ 即將進入 $tag：容器啟動時會自動升級 PostgreSQL 到 17.7，耗時隨資料庫大小增加。"
            echo "  $(glc_data_dir) 所在磁碟剩餘空間：$(docker_free_space_line "$(df -Pk "$(glc_data_dir)")" || echo "（讀不到）")"
            confirm "了解並繼續？" || { echo "已取消，停在 $(docker_current_tag || echo "$cur")。"; return 0; }
        fi
        docker_upgrade_station "$tag"
    done
    docker_upgrade_finish
}


# ── purge 舊 deb 套件（ISSUE-006）────────────────────────────────────────────

# purge 的第二道確認字串（不是密碼，不需隱藏）；驗證戳記有效秒數預設 1 小時（GLC_VERIFY_MAX_AGE 可調）。
GLC_PURGE_PHRASE="purge-old-deb"
glc_now_epoch() { date +%s; }

# 三個掛載目錄內（兩層深）的項目，一行一個；purge 前後各取一次比對。
docker_dir_listing() {
    local d
    for d in $GLC_MOUNT_DIRS; do
        [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 2 2>/dev/null
    done
    return 0
}

# PR-DKR-18 閘門：ISSUE-004 的驗證剛通過（戳記未逾時），且容器此刻仍是 healthy；否則拒絕並說明。
docker_purge_precheck() {
    local stamp out
    stamp="$(env_get GLC_VERIFIED_AT)"
    docker_verify_fresh "$stamp" "$(glc_now_epoch)" "${GLC_VERIFY_MAX_AGE:-3600}" \
        || die "拒絕移除：找不到「剛通過」的遷移驗證（沒有紀錄或已逾時）。請先重新執行選單 5 的驗證流程，確認 gitlab:check 與 curl -kI 通過後再來。"
    out="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' gitlab 2>/dev/null)" || out=""
    [ "${out#* }" = healthy ] \
        || die "拒絕移除：容器 gitlab 目前不是 healthy（${out:-讀不到狀態}）。請先用 docker logs gitlab 排除。"
}

# purge 失敗時讓容器回到原樣：還原重啟政策；原本在跑而現在沒跑就啟動它。盡力而為，不再 die。
docker_restore_container() { # docker_restore_container <重啟政策> <原狀態>
    echo "嘗試讓容器 gitlab 回到 purge 前的狀態（重啟政策 $1、狀態 $2）..." >&2
    docker update --restart "$1" gitlab >&2 || echo "⚠ 還原重啟政策失敗，請手動檢查。" >&2
    if [ "$2" = running ] && [ "$(docker inspect -f '{{.State.Status}}' gitlab 2>/dev/null)" != running ]; then
        docker start gitlab >&2 || echo "⚠ 啟動容器失敗，請手動檢查。" >&2
    fi
}

# 【GitLab 伺服器】驗證通過後 purge 舊 deb 套件。不可逆：之後只剩機外備份。
# 順序為「保持容器運行 → apt purge → 比對掛載目錄 → 重跑驗證」，直接 purge 而不是先停容器。
# 未驗證：真實 `apt purge gitlab-ce` 的 prerm／postrm 是否會動到容器正在用的掛載目錄（spec Open question 2）
# 尚未在 WSL／VM 實測，這個排法是預設假設，不是實測結論；測試只用假 apt。比對與還原就是為這個未知而設。
# 絕不呼叫 gitlab-ctl cleanse（會刪資料目錄）。apt 回非 0 不直接判失敗，以掛載目錄與容器驗證為準。
docker_purge_deb() {
    local ans="" st policy state before after lost rc=0
    require_machine ubuntu docker
    require_root
    docker_deb_version >/dev/null 2>&1 || { echo "找不到 deb 安裝的 gitlab-ce，沒有東西可移除。"; return 0; }
    docker_purge_precheck
    echo "⚠ 即將 apt purge gitlab-ce。這一步不可逆：舊 deb 版從此不存在，之後只剩機外備份可以救。"
    echo "  掛載目錄（$GLC_MOUNT_DIRS）預期不受影響，purge 後會逐項比對並重跑驗證。"
    confirm "確定移除舊 deb 套件？" || { echo "已取消，未做任何變更。"; return 0; }
    read -r -p "再次確認：輸入 $GLC_PURGE_PHRASE 繼續：" ans || true
    [ "$ans" = "$GLC_PURGE_PHRASE" ] || { echo "未輸入確認字串，已取消，未做任何變更。"; return 0; }

    st="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}} {{.State.Status}}' gitlab)" || die "讀不到容器 gitlab 的狀態，未做任何變更。"
    policy="${st%% *}"
    state="${st#* }"
    before="$(docker_dir_listing)"
    env_set GLC_VERIFIED_AT "" # purge 後必須重新驗證，不沿用 purge 前的戳記
    echo "══ apt purge gitlab-ce ══"
    apt purge -y gitlab-ce || rc=$?
    [ "$rc" -eq 0 ] || echo "⚠ apt purge 回傳 $rc（上面是實際輸出）；以掛載目錄與容器驗證為準，繼續檢查。" >&2

    after="$(docker_dir_listing)"
    if ! docker_dirs_lost_check "$before" "$after"; then
        lost="$(docker_dirs_lost "$before" "$after")"
        echo "✗ purge 後掛載目錄有項目消失（或 purge 前就是空的）：" >&2
        printf '%s\n' "${lost:-（purge 前清單為空，無法比對）}" | sed 's/^/  /' >&2
        docker_restore_container "$policy" "$state"
        die "掛載目錄內容消失，遷移不算完成，已停止。請用機外備份還原。"
    fi
    echo "✓ 掛載目錄內容仍在。"
    if ! ( docker_wait_healthy && docker_verify ); then
        docker_restore_container "$policy" "$state"
        die "purge 後重跑驗證失敗（gitlab:check／curl 未通過），遷移不算完成。請看上面的輸出與 docker logs gitlab。"
    fi
    echo "✓ 遷移完成：舊 deb 套件已移除，GitLab 由容器服務，掛載目錄完好。"
}

# ── 說明與排查 ───────────────────────────────────────────────────────────────
# 只描述已實作的行為。docker、apt 的真實動作都只用假指令測過，尚未在實機試跑；文字內如實標明。

show_help() {
    cat <<'TXT'
【說明】GitLab 容器（Docker）
本腳本把 deb 安裝的 GitLab 改成 GitLab 容器，並逐站升級；在【GitLab 伺服器】上以 root（sudo）執行。
注意：遷移、purge、逐站升級與容器備份都尚未在實機試跑（只用假 docker／apt 測過），
首次使用請先在 WSL／VM 或資料副本上走一遍。

整體順序（選單項目）：
  1（【有網路的電腦】）打包 GitLab 映像包，內含升級路徑上每一站的映像。
  3（【有網路的電腦】）打包 Docker 離線包。
  scp 把兩個包傳到【GitLab 伺服器】。
  4 安裝 Docker；2 載入 GitLab 映像包。
  5 遷移：備份並確認已複製到機外 → 改 gitlab.rb（移除外部 Nginx 管理區塊、設定 Git SSH 埠）→
    停 deb 版 → 以掛載目錄啟動 GitLab 容器 → 等 healthy → gitlab:check 與 curl 驗證。
    映像版本須與 deb 版本相同（預設 18.10.3）；這一步 deb 套件還在。
  6 移除舊 deb 套件：只有剛通過驗證才允許；不可逆，之後只剩機外備份。
  7 逐站升級：預設路徑 18.10.3 → 18.11.13 → 19.2.9 → 19.5.1。

為什麼一定要經過 18.11：
  GitLab 不可任意跨版本升級，停靠站依 Upgrade Path Tool
  （https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/）；18.11 是必停版本，
  18.11 起會自動把 PostgreSQL 升到 17.7，19.0 起 PostgreSQL 17 是最低版本，
  所以不能 18.10.3 直接到 19.2。本腳本不猜停靠站：映像包裡有什麼，就升什麼（只升比目前高的）。
  進入 18.11 前會警告並顯示資料磁碟剩餘空間；該站啟動時間隨資料庫大小增加。

逐站升級（選單 7）：
  每一站：備份 → docker stop → docker rm（掛載目錄不動）→ 以新版映像重建容器 → 等 healthy →
  等背景遷移歸零。中斷後重跑選單 7：以目前容器版本為準，先確認背景遷移歸零再升下一站。

Git SSH 埠：
  GitLab 容器把 Git SSH 埠發佈在 2222（遷移時寫入 gitlab.rb），clone 要寫成
  git clone ssh://git@<主機>:2222/<群組>/<專案>.git
  宿主機 sshd 的 22 不動，仍供管理員 ssh／scp。

HTTPS：
  容器使用內建 Nginx，直接發佈 80／443，沿用 /etc/gitlab/ssl 的自簽憑證；
  nginx.sh 的外部 Nginx 流程不適用於 GitLab 容器。install.sh、nginx.sh、upgrade.sh 僅適用 deb 安裝。

備份：
  backup_auto.sh 偵測到名為 gitlab 的容器在跑時，改以 docker exec 在容器內備份，
  產物仍在宿主機的 /var/opt/gitlab/backups 與 /etc/gitlab/config_backup。容器模式的還原不在本腳本範圍。

Docker 發佈的埠會直接寫 iptables，ufw 規則擋不住 80／443／2222；要限制來源網段請另行處理。
TXT
}

show_troubleshooting() {
    cat <<'TXT'
【常見問題排查】（以下尚未在實機試跑，指令請依實際輸出判斷）
  權限錯誤（容器日誌出現 Permission denied、檔案擁有者不對）：
    1. 以暫時容器重新對齊 UID（掛三個掛載目錄）：
       docker run --rm -v /etc/gitlab:/etc/gitlab -v /var/opt/gitlab:/var/opt/gitlab          -v /var/log/gitlab:/var/log/gitlab gitlab/gitlab-ce:<目前版本>-ce.0 update-permissions
    2. 再 docker restart gitlab。
    不要手動 chown 成 root:root。
  容器起不來或一直重啟：
    - docker logs gitlab 看原因（docker logs -f gitlab 持續追蹤）。
    - 日誌出現 stat: missing operand：通常是 /var/opt/gitlab/git-data/repositories 不存在或是壞掉的
      symlink；修好目錄後 docker restart gitlab。
    - 磁碟空間不足：df -h /var/opt/gitlab 看掛載目錄所在磁碟；18.11 的 PostgreSQL 升級需要額外空間。
    - 80、443、2222 被占用：ss -ltn 查出占用者（deb 版沒停乾淨最常見）。
    - docker ps -a 看狀態；docker inspect -f '{{.State.Health.Status}}' gitlab 看是否 healthy。
      啟動後 healthy 要數分鐘，18.11 因 PostgreSQL 升級更久。
  PostgreSQL 起不來、日誌出現 database locale is incompatible with operating system：
    deb 時代的資料庫用了容器沒有的 LC_COLLATE（例如 zh_TW.UTF-8）。伺服器無網路，無法在容器內補裝；
    請在【有網路的電腦】重新執行選單 1（會把 locale 烤進同 tag 映像），scp 到伺服器後執行選單 2，
    再 docker rm -f gitlab 並重新啟動容器（資料在掛載目錄，不會遺失）。不要為了啟動而改資料庫 collation。
    其他 locale 可用環境變數 GLC_DB_LOCALE 指定（預設 zh_TW.UTF-8）。
  前置檢查失敗：照訊息處理。deb 版本與映像版本必須相同；映像未載入先執行選單 2；已有名為 gitlab 的容器不會被覆蓋。
  背景遷移一直不是 0（逾時）：
    - docker exec gitlab gitlab-ctl status sidekiq，並看 docker exec gitlab gitlab-ctl tail sidekiq
      （宿主機檔案在 /var/log/gitlab/sidekiq/current）。
    - 大型資料庫要等很久；歸零後重跑選單 7 會接續。不要在遷移未歸零時升下一站。
  gitlab:check 有 FAILED：docker exec gitlab gitlab-rake gitlab:check SANITIZE=true，照輸出修正；
    剛重啟後幾分鐘內的暫時失敗可稍後再跑。
  備份失敗：本流程不會在沒有備份時動 deb 版或升級；先排除備份問題（磁碟空間、容器狀態）。
  purge（選單 6）：
    - 不可逆：舊 deb 套件移除後不能回頭，只剩機外備份。必須先有「剛通過」的驗證（逾時請重跑選單 5），
      並輸入確認字串。
    - purge 後若掛載目錄項目消失，或重跑驗證失敗，腳本會停止並嘗試還原容器；請用機外備份還原。
    - apt purge 對運行中容器的影響尚未在實機試跑（spec Open question 2 仍未解），
      所以才有 purge 前後比對與重新驗證；絕不使用 gitlab-ctl cleanse。
TXT
}

# ── 選單 ─────────────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== GitLab 容器（Docker）===
  1) 打包 GitLab 映像包（docker save）  【有網路的電腦】
  2) 載入 GitLab 映像包（docker load）  【GitLab 伺服器】
  3) 打包 Docker 離線包                【有網路的電腦】
  4) 安裝 Docker（含啟用服務）          【GitLab 伺服器】
  5) 遷移到 Docker（沿用現有資料）      【GitLab 伺服器】
  6) 移除舊 deb 套件（不可逆）          【GitLab 伺服器】
  7) 逐站升級 GitLab 容器              【GitLab 伺服器】
  8) 說明
  9) 常見問題排查
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) docker_build_bundle ;;
        2) docker_load_bundle ;;
        3) docker_build_offline ;;
        4) docker_install_offline ;;
        5) docker_migrate ;;
        6) docker_purge_deb ;;
        7) docker_upgrade ;;
        8) show_help ;;
        9) show_troubleshooting ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_glc_dir")"
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
