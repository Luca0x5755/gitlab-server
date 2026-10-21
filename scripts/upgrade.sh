#!/usr/bin/env bash
# GitLab 升級選單腳本：吃一個放著多個版本 .deb 的資料夾，依版本由小到大逐版升級，
# 每一版之間等背景遷移歸零。只有互動選單，不收參數。說明與排查見選單項目。
# 「該停在哪些中間版本」由人查 Upgrade Path Tool，腳本不猜；資料夾放什麼，就照順序裝什麼。
#
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得純函式而不啟動選單。
#
# 可由環境變數覆寫的設定（供測試用，預設為正式值；它們不是命令列參數）：
#   GITLAB_OPT_DIR、UPG_POLL_INTERVAL（輪詢間隔秒數，預設 30）、UPG_POLL_MAX（最多輪詢次數，預設 120，
#   即約 1 小時），另外備份相關路徑同 backup_auto.sh。

_upg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_upg_dir/lib/common.sh"

UPG_RUNNER_EXPR='puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count'

# ── 純函式 ───────────────────────────────────────────────────────────────────

# 已安裝的 gitlab-ce 套件版本（dpkg 的 Version，例 18.7.6-ce.0）；獨立成函式讓測試能換掉。
installed_gitlab_pkg_version() { dpkg-query -W -f='${Version}\n' gitlab-ce; }

# 決定要安裝哪些 .deb。stdin：一行一個檔案路徑；參數：已裝版本。
# stdout：比已裝版本新的 .deb 路徑，依版本由小到大（數值比較：18.7 < 18.10）。
# stderr：略過者（已裝版本以下）逐行說明。
# 不是 gitlab-ce_<版本>_<架構>.deb 的 .deb、架構與本機不同、同一版本出現兩次，都視為錯誤
# （回非 0 且不輸出任何路徑）：寧可中止也不要猜。非 .deb 的檔案直接忽略。
select_upgrade_debs() { # select_upgrade_debs <已裝版本> [本機架構]
    local installed="$1" arch="${2:-}" path base ver key re c
    local -A seen=()
    local keyed="" skipped=""
    valid_gitlab_version "$installed" || { echo "✗ 已裝版本格式不符：$installed" >&2; return 1; }
    [ -n "$arch" ] || arch="$(dpkg --print-architecture)"
    re='^gitlab-ce_([^_]+)_([a-z0-9]+)[.]deb$'
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        base="${path##*/}"
        [[ $base == *.deb ]] || continue
        ver="$(deb_version "$base")" || { echo "✗ 不認得的 .deb 檔名（須為 gitlab-ce_<版本>_<架構>.deb）：$base" >&2; return 1; }
        [[ $base =~ $re ]] || return 1
        [ "${BASH_REMATCH[2]}" = "$arch" ] || { echo "✗ 架構不符：$base 的架構是 ${BASH_REMATCH[2]}，這台是 $arch。" >&2; return 1; }
        [ -z "${seen[$ver]:-}" ] || { echo "✗ 版本 $ver 出現兩次：${seen[$ver]} 與 $path" >&2; return 1; }
        seen[$ver]="$path"
        c="$(version_cmp "$ver" "$installed")"
        if [ "$c" -le 0 ]; then
            skipped+="  略過 $base（$ver 不高於已裝的 $installed）"$'\n'
            continue
        fi
        key="$(_version_key "$ver")"
        keyed+="$key"$'\t'"$path"$'\n'
    done
    [ -z "$skipped" ] || printf '%s' "$skipped" >&2
    [ -n "$keyed" ] || return 0
    printf '%s' "$keyed" | LC_ALL=C sort | cut -f2-
}

# 取出 `gitlab-rails runner` 輸出（stdin）中最後一個純數字行（前面可能有警告訊息）。
# 找不到回非 0。
parse_queued_count() {
    local line n=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ $line =~ ^[0-9]+$ ]] && n="$line"
    done
    [ -n "$n" ] || return 1
    printf '%s\n' "$n"
}

# ── 說明與排查 ───────────────────────────────────────────────────────────────

show_help() {
    cat <<'TXT'
【說明】逐版升級 GitLab
本腳本在【GitLab 伺服器】上執行，需要 root（sudo）。

升級路徑（最重要）：
  GitLab 不可跨大版本直接升級。請先用選單 1 確認目前版本，再到 Upgrade Path Tool
  https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/ 查詢必須停留的「中間版本」，
  把每個版本的 gitlab-ce_<版本>_amd64.deb 都下載好放進同一個資料夾。
  本腳本不判斷路徑：資料夾裡有什麼（高於已裝版本的），就依版本由小到大逐一安裝。

流程（選單 3）：
  1. 吃一個資料夾；已裝版本以下的 .deb 略過；印出將安裝的版本順序，須輸入 yes 才繼續。
  2. 開跑前呼叫 backup_auto.sh（資料備份＋設定備份）；備份失敗即中止，不升級。
  3. 每一版：gitlab-ctl stop puma → stop sidekiq → dpkg -i → gitlab-ctl reconfigure →
     gitlab-ctl start → gitlab-ctl status。
     reconfigure 不會自動重啟服務，所以要手動 start；Sidekiq 必須運行才能處理背景遷移。
  4. 輪詢背景遷移 BatchedMigration.queued.count，回傳 0 才進入下一版（約每 30 秒查一次，
     最多等約 1 小時；逾時就停止並指向 sidekiq 日誌）。
  5. 全部完成後 gitlab-ctl restart，並執行 gitlab-rake gitlab:check SANITIZE=true
     （SANITIZE=true 會隱藏輸出中的敏感資訊，如 token、密碼）。

中斷後重跑：
  再執行選單 3 即可。腳本以「目前已裝的版本」為準，只裝比它新的；接續前會先確認目前版本的
  背景遷移已歸零，才安裝下一版。

選單 2 只預覽順序，不做任何變更。
TXT
}

show_troubleshooting() {
    cat <<'TXT'
【常見問題排查】
  「沒有比已裝版本新的 .deb」：資料夾裡的版本都不高於目前版本；用選單 1 確認版本，
    並確認下載了更新的中間版本。
  「不認得的 .deb 檔名」：檔名須為 gitlab-ce_<版本>_<架構>.deb（例 gitlab-ce_18.7.6-ce.0_amd64.deb），
    不要改檔名；EE 套件（gitlab-ee_…）不支援。
  「架構不符」：.deb 的架構須與伺服器相同（dpkg --print-architecture）。
  開跑前備份失敗：本流程不會在沒有備份時升級。先排除備份問題（磁碟空間、服務狀態，
    見 backup.sh 的「常見問題排查」與 /var/log/gitlab_backup.log）。
  dpkg -i 失敗：看輸出的錯誤；此時 puma 與 sidekiq 是停止的。排除後重跑選單 3
    （已裝版本沒變，會從同一個版本重試）。必要時 sudo gitlab-ctl start 先恢復服務。
  reconfigure 失敗：同上；可用 sudo gitlab-ctl tail 看原因。
  背景遷移一直不是 0（逾時）：
    - 先確認 sidekiq 在運行：sudo gitlab-ctl status sidekiq
    - 看 sidekiq 日誌：sudo gitlab-ctl tail sidekiq（檔案在 /var/log/gitlab/sidekiq/current）
    - 大型資料庫的遷移可能要數小時；耐心等待後重跑選單 3 會先等遷移歸零才繼續。
    - 手動查詢：sudo gitlab-rails runner -e production 'puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count'
    - 不要在遷移未歸零時硬裝下一版，這是升級失敗最常見的原因。
  gitlab:check 有 FAILED：照輸出修正；剛重啟後幾分鐘內的暫時失敗可稍後再跑
    sudo gitlab-rake gitlab:check SANITIZE=true。
  升級中途停電或連線中斷：重新登入後先 sudo gitlab-ctl start、sudo gitlab-ctl status，
    再執行選單 3 接續。
TXT
}

# ── 動作 ─────────────────────────────────────────────────────────────────────

upg_require_cmds() {
    local c
    for c in "$@"; do
        have_cmd "$c" || die "缺少指令 $c。這個動作須在已安裝 GitLab 的【GitLab 伺服器】上執行。"
    done
}

show_current_version() {
    require_machine server
    upg_require_cmds gitlab-rake
    gitlab-rake gitlab:env:info
}

# 列出所選資料夾的升級計畫並放進全域 _upg_plan（陣列）；沒有可裝的版本時陣列為空。
_upg_make_plan() { # _upg_make_plan <資料夾> <已裝版本>
    local dir="$1" installed="$2" out f
    [ -d "$dir" ] || die "找不到資料夾：$dir"
    _upg_plan=()
    out="$(
        for f in "$dir"/*.deb; do [ -e "$f" ] && printf '%s\n' "$f"; done | select_upgrade_debs "$installed"
    )" || die "無法決定升級順序，未做任何變更。"
    [ -z "$out" ] || mapfile -t _upg_plan <<<"$out"
}

_upg_print_plan() { # _upg_print_plan <已裝版本>
    local i=0 f
    echo "目前已安裝：$1"
    echo "將依序安裝（共 ${#_upg_plan[@]} 版）："
    for f in "${_upg_plan[@]}"; do
        i=$((i + 1))
        echo "  $i. $(deb_version "$f")   ${f##*/}"
    done
}

preview_upgrade() {
    local dir installed
    require_machine server
    upg_require_cmds dpkg-query dpkg
    dir="$(ask_param UPG_DEB_DIR "放 .deb 的資料夾（絕對路徑）" "" valid_local_path)"
    installed="$(installed_gitlab_pkg_version)" || die "讀不到已安裝的 gitlab-ce 版本。"
    _upg_make_plan "$dir" "$installed"
    if [ "${#_upg_plan[@]}" -eq 0 ]; then
        echo "資料夾裡沒有比已裝版本（$installed）新的 .deb，不需要升級。"
        return 0
    fi
    _upg_print_plan "$installed"
    echo "（僅預覽，未做任何變更。）"
}

# 輪詢背景遷移直到 queued.count 為 0。逾時回非 0 並指向 sidekiq 日誌。
wait_migrations() {
    local interval="${UPG_POLL_INTERVAL:-30}" max="${UPG_POLL_MAX:-120}" i out n="" last=""
    echo "等待背景遷移歸零（queued.count 須為 0）..."
    for ((i = 1; i <= max; i++)); do
        out="$(gitlab-rails runner -e production "$UPG_RUNNER_EXPR" 2>&1)" || true
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
    echo "✗ 等了 $max 次仍未歸零（最後一次：$last）。已停止，未安裝下一版。" >&2
    echo "  請看 sidekiq 日誌：sudo gitlab-ctl tail sidekiq（/var/log/gitlab/sidekiq/current），" >&2
    echo "  確認 sidekiq 在運行（sudo gitlab-ctl status sidekiq）；歸零後重跑選單 3 即可接續。" >&2
    return 1
}

# 裝一版：停 puma 與 sidekiq → dpkg -i → reconfigure → start → status。
install_one_version() { # install_one_version <.deb 路徑>
    local deb="$1"
    echo "══ 安裝 $(deb_version "$deb") ══"
    gitlab-ctl stop puma || die "停止 puma 失敗。"
    gitlab-ctl stop sidekiq || die "停止 sidekiq 失敗。"
    dpkg -i -- "$deb" || die "dpkg -i 失敗：$deb。puma 與 sidekiq 目前是停止的；排除後重跑選單 3 會從這一版重試，或先 sudo gitlab-ctl start。"
    gitlab_reconfigure || die "reconfigure 失敗。排除後重跑選單 3；原因可用 sudo gitlab-ctl tail 查看。"
    gitlab-ctl start || die "gitlab-ctl start 失敗。"
    gitlab-ctl status || echo "⚠ gitlab-ctl status 回報有服務未運行，請檢查。" >&2
}

run_upgrade() {
    local dir installed f total i=0 rc=0
    require_machine server
    require_root
    upg_require_cmds dpkg dpkg-query gitlab-ctl gitlab-rails gitlab-rake
    dir="$(ask_param UPG_DEB_DIR "放 .deb 的資料夾（絕對路徑）" "" valid_local_path)"
    installed="$(installed_gitlab_pkg_version)" || die "讀不到已安裝的 gitlab-ce 版本。"
    _upg_make_plan "$dir" "$installed"
    if [ "${#_upg_plan[@]}" -eq 0 ]; then
        echo "資料夾裡沒有比已裝版本（$installed）新的 .deb，不需要升級。"
        return 0
    fi
    _upg_print_plan "$installed"
    echo "⚠ 請確認這個順序符合 Upgrade Path Tool 查到的路徑；GitLab 不可跨大版本直接升級。"
    echo "⚠ 升級期間 GitLab 會短暫中斷。開跑前會先備份，備份失敗即中止。"
    confirm "確定依上列順序升級？" || { echo "已取消，未做任何變更。"; return 0; }

    echo "══ 開跑前備份 ══"
    bash "$_upg_dir/backup_auto.sh" || die "備份失敗（結束碼 $?），不升級。請先排除備份問題。"

    # 先確認目前版本的背景遷移已歸零：中斷後重跑時，上一版的遷移可能還沒跑完。
    wait_migrations || return 1

    total="${#_upg_plan[@]}"
    for f in "${_upg_plan[@]}"; do
        i=$((i + 1))
        echo "── 第 $i／$total 版 ──"
        install_one_version "$f"
        wait_migrations || return 1
    done

    echo "══ 全部版本安裝完成，重啟並做健康檢查 ══"
    gitlab-ctl restart || die "gitlab-ctl restart 失敗。"
    gitlab-rake gitlab:check SANITIZE=true || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "✗ gitlab:check 回報問題（結束碼 $rc）；升級本身已完成，請依輸出處理（見「常見問題排查」）。" >&2
        return 1
    fi
    echo "✓ 升級完成：$installed → $(deb_version "${_upg_plan[$((total - 1))]}")。"
}

# ── 選單 ─────────────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== GitLab 升級 ===
  1) 顯示目前版本                     【GitLab 伺服器】
  2) 預覽升級順序（不執行）           【GitLab 伺服器】
  3) 逐版升級（備份→安裝→等遷移）     【GitLab 伺服器】
  4) 說明
  5) 常見問題排查
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) show_current_version ;;
        2) preview_upgrade ;;
        3) run_upgrade ;;
        4) show_help ;;
        5) show_troubleshooting ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_upg_dir")"
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
