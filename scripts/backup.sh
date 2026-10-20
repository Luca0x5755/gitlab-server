#!/usr/bin/env bash
# GitLab 備份選單腳本：立即備份、列出備份、設定資料備份保留 7 天、註冊／移除 crontab、
# 複製設定備份離機。只有互動選單，不收參數。來源文件：docs/02-backup-and-restore.md
# 前半（建立與清理）；說明與排查內容併入本檔。還原由後續票（ISSUE-007）在本檔追加。
# 真正做備份的是 backup_auto.sh（cron、升級前、本選單共用同一份）。
#
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得函式而不啟動選單。
#
# 可由環境變數覆寫的路徑（供測試用，預設為正式路徑；它們不是命令列參數）：
#   GITLAB_RB、GITLAB_BACKUP_DIR、GITLAB_CONFIG_BACKUP_DIR、BACKUP_AUTO_LOG、GITLAB_OPT_DIR。

_bk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_bk_dir/lib/common.sh"

BK_KEEP_BLOCK="backup_keep_time"
BK_CRON_MARK="# gitlab-ops:backup_auto"

# ── 純函式 ───────────────────────────────────────────────────────────────────

# cron 排程：五個欄位，每欄只收數字與 * , / -（擋掉 % 與換行等會改變 cron 行意義的字元）。
valid_cron_schedule() {
    local -a f
    [[ $1 != *$'\n'* ]] || return 1
    read -ra f <<<"$1"
    [ "${#f[@]}" -eq 5 ] || return 1
    local x
    for x in "${f[@]}"; do
        [[ $x =~ ^[0-9*,/-]+$ ]] || return 1
    done
}

# 組出 cron 行：排程（空白正規化為單一空格）＋指令＋辨識用標記。
# 腳本與日誌路徑須是白名單絕對路徑；不合格回非 0。
render_cron_line() { # render_cron_line <排程> <backup_auto.sh 路徑> <日誌路徑>
    local -a f
    valid_cron_schedule "$1" || return 1
    valid_local_path "$2" || return 1
    valid_local_path "$3" || return 1
    read -ra f <<<"$1"
    printf '%s %s %s %s %s /bin/bash %s >> %s 2>&1 %s\n' "${f[@]}" "$2" "$3" "$BK_CRON_MARK"
}

# 以下三個處理 crontab 全文（stdin／stdout 無關，全文走參數與 stdout），不碰系統 crontab。
cron_has_entry() { # cron_has_entry <crontab 全文>
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line == *"$BK_CRON_MARK" ]] && return 0
    done <<<"$1"
    return 1
}

cron_strip() { # cron_strip <crontab 全文>：移除帶標記的行，其餘原樣；非空輸出以換行結尾
    local line out=""
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line == *"$BK_CRON_MARK" ]] && continue
        out+="$line"$'\n'
    done <<<"$1"
    # here-string 會多給一個空行：全文為空時不輸出
    [ "$out" = $'\n' ] && out=""
    printf '%s' "$out"
}

cron_apply() { # cron_apply <crontab 全文> <cron 行>：先移除舊的帶標記行再追加，所以重複註冊只會有一行
    local base
    base="$(cron_strip "$1")"
    [ -z "$base" ] || base+=$'\n'
    printf '%s%s\n' "$base" "$2"
}

# 路徑 $1 是否等於或位於目錄 $2 之下（純字串比對，先去掉結尾斜線；不解析符號連結）。
path_within() {
    local p="${1%/}" d="${2%/}"
    [ "$p" = "$d" ] || [[ $p == "$d"/* ]]
}

render_keep_time_block() { echo "gitlab_rails['backup_keep_time'] = 604800"; }

# ── 系統 crontab 的薄包裝（獨立成函式讓測試能覆寫）──────────────────────────

# 讀 root 的 crontab。「尚無 crontab」視為空；其他錯誤中止，免得之後把整份 crontab 寫成空的。
read_crontab() {
    local out rc=0
    out="$(crontab -l 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        [[ $out == *"no crontab"* ]] || { echo "✗ 無法讀取 crontab：$out" >&2; return 1; }
        out=""
    fi
    printf '%s' "$out"
}
write_crontab() { printf '%s' "$1" | crontab -; }

# ── 說明與排查 ───────────────────────────────────────────────────────────────

show_help() {
    cat <<'TXT'
【說明】GitLab 備份
本腳本在【GitLab 伺服器】上執行，需要 root（sudo）。

兩種備份，缺一不可：
  資料備份：gitlab-backup create 產出，檔名 <時間戳>_<日期>_<版本>_gitlab_backup.tar，
    放在 /var/opt/gitlab/backups。含儲存庫、資料庫、附件、Wiki；不含設定與金鑰。
  設定備份：gitlab-ctl backup-etc 產出，放在 /etc/gitlab/config_backup（僅 root 可讀），
    含 gitlab.rb、gitlab-secrets.json、ssl、trusted-certs 等整個 /etc/gitlab。
    沒有設定備份，資料備份無法還原。
  設定備份必須與資料備份存放在不同的安全位置，避免金鑰與加密資料放在一起；
  用選單 6 把設定備份複製到另一個目錄（例如另一顆碟或掛載的共享目錄）。

備份不包含的項目（需另外處理）：
  - Object Storage 中的內容
  - Mattermost 資料
  - Redis 佇列資料
  - 系統層級的 server hooks

保留期限：
  - 資料備份保留 7 天，由 gitlab.rb 的 backup_keep_time = 604800（秒）控制，
    選單 3 以管理區塊寫入並 reconfigure；GitLab 於每次建立資料備份時清理過期檔案。
  - 設定備份同樣保留 7 天，由 backup_auto.sh 在每次備份後清理。

自動備份：選單 4 把 backup_auto.sh 註冊進 root 的 crontab（預設每天 02:00），
  重複註冊只會留下一筆；輸出記在 /var/log/gitlab_backup.log。選單 5 移除。
  backup_auto.sh 先資料備份、再設定備份；資料備份失敗即以非 0 結束。
TXT
}

show_troubleshooting() {
    cat <<'TXT'
【常見問題排查】
  立即備份失敗：看 /var/log/gitlab_backup.log。常見原因是磁碟空間不足
    （df -h /var/opt/gitlab）或 GitLab 服務沒起來（sudo gitlab-ctl status）。
  資料備份成功但設定備份失敗：backup_auto.sh 以結束碼 2 結束。沒有設定備份就無法還原，
    請手動執行 sudo gitlab-ctl backup-etc 查看錯誤。
  舊的資料備份沒有被刪：保留期限靠 gitlab.rb 的 backup_keep_time；先用選單 3 套用，
    之後每次建立資料備份才會清理。
  cron 沒有執行：用 sudo crontab -l 確認有標記 gitlab-ops:backup_auto 的那一行；
    檢查 /var/log/syslog 的 CRON 記錄與 /var/log/gitlab_backup.log。
  註冊 crontab 被拒絕：排程須是五個欄位，只含數字與 * , / -（例：0 2 * * *）；
    本腳本所在路徑只能含英數與 . _ - /。
  找不到設定備份：預設在 /etc/gitlab/config_backup，只有 root 看得到；用 sudo 執行本腳本。
  複製設定備份被拒絕：目的地不得位於資料備份目錄（/var/opt/gitlab/backups）之下，
    也不能就是設定備份目錄本身。
  複製出去的設定備份只有 root 可讀（保留原本的權限）；放在共享目錄時請確認其他人讀不到。
TXT
}

# ── 動作 ─────────────────────────────────────────────────────────────────────

backup_now() {
    local rc=0
    require_machine server
    require_root
    bash "$_bk_dir/backup_auto.sh" || rc=$?
    case "$rc" in
        0) echo "✓ 備份完成（資料備份與設定備份）。設定備份記得複製到另一個位置（選單 6）。" ;;
        1) echo "✗ 資料備份失敗，見 $(backup_log_file)。" >&2 ;;
        2) echo "✗ 設定備份失敗，見 $(backup_log_file)。資料備份已完成但沒有設定備份就無法還原。" >&2 ;;
        *) echo "✗ 備份未完成（結束碼 $rc）。" >&2 ;;
    esac
    return "$rc"
}

# 列出一個目錄下符合 <樣式> 的檔案（新到舊）：時間、大小、檔名。
_list_files() { # _list_files <目錄> <樣式>
    local out line
    out="$(find "$1" -maxdepth 1 -type f -name "$2" -printf '%TY-%Tm-%Td %TH:%TM  %10s bytes  %f\n' 2>/dev/null | LC_ALL=C sort -r)" || true
    if [ -n "$out" ]; then
        while IFS= read -r line; do echo "  $line"; done <<<"$out"
    else
        echo "  （沒有）"
    fi
}

list_backups() {
    require_machine server
    echo "資料備份（$(data_backup_dir)）："
    _list_files "$(data_backup_dir)" '*_gitlab_backup.tar'
    echo "設定備份（$(config_backup_dir)）："
    _list_files "$(config_backup_dir)" 'gitlab_config_*.tar'
}

set_keep_time() {
    local body rc=0
    require_machine server
    require_root
    body="$(render_keep_time_block)"
    echo "將在 $(gitlab_rb_file) 以管理區塊（$BK_KEEP_BLOCK）寫入：    $body"
    apply_managed_block "$BK_KEEP_BLOCK" "$body" || rc=$?
    case "$rc" in
        0) echo "✓ 資料備份保留 7 天已設定並完成 reconfigure。" ;;
        1) echo "✗ reconfigure 失敗，見上方說明。" >&2 ;;
        3) echo "✗ 寫入 gitlab.rb 失敗，已自動還原。" >&2 ;;
        *) echo "✗ 未寫入任何變更。" >&2 ;;
    esac
    return "$rc"
}

register_cron() {
    local sched script line cur
    require_machine server
    require_root
    have_cmd crontab || die "找不到 crontab 指令。"
    script="$_bk_dir/backup_auto.sh"
    [ -f "$script" ] || die "找不到 $script。"
    sched="$(ask_param BAK_CRON_SCHEDULE "cron 排程（分 時 日 月 週）" "0 2 * * *" valid_cron_schedule)"
    line="$(render_cron_line "$sched" "$script" "$(backup_log_file)")" \
        || die "無法組出 cron 行：腳本路徑只能含英數與 . _ - /（目前：$script）。"
    cur="$(read_crontab)"
    write_crontab "$(cron_apply "$cur" "$line")"$'\n'
    echo "✓ 已註冊（重複註冊只會保留一筆）："
    echo "  $line"
}

unregister_cron() {
    local cur
    require_machine server
    require_root
    have_cmd crontab || die "找不到 crontab 指令。"
    cur="$(read_crontab)"
    if ! cron_has_entry "$cur"; then
        echo "crontab 裡沒有本腳本註冊的備份排程，不需移除。"
        return 0
    fi
    write_crontab "$(cron_strip "$cur")"
    echo "✓ 已移除備份排程。"
}

copy_config_backups() {
    local dest src f n=0 skipped=0
    require_machine server
    require_root
    src="$(config_backup_dir)"
    [ -d "$src" ] || die "找不到設定備份目錄 $src。請先執行選單 1 立即備份。"
    dest="$(ask_param BAK_COPY_DIR "複製設定備份到哪個目錄（絕對路徑）" "" valid_local_path)"
    path_within "$dest" "$(data_backup_dir)" && die "目的地不能位於資料備份目錄（$(data_backup_dir)）之下：設定備份要和資料備份放不同位置。"
    path_within "$dest" "$src" && die "目的地不能是設定備份目錄本身（$src）之下。"
    ( umask 077 && mkdir -p "$dest" ) || die "無法建立目錄 $dest。"
    for f in "$src"/gitlab_config_*.tar; do
        [ -f "$f" ] || continue
        if [ -e "$dest/${f##*/}" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        cp -p -- "$f" "$dest/" || die "複製失敗：$f"
        n=$((n + 1))
    done
    echo "✓ 已複製 $n 個設定備份到 $dest（已存在而略過：$skipped）。"
    [ "$n" -gt 0 ] || [ "$skipped" -gt 0 ] || echo "  （$src 裡沒有設定備份，請先執行選單 1。）"
}

# ── 選單 ─────────────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== GitLab 備份 ===
  1) 立即備份（資料備份＋設定備份）   【GitLab 伺服器】
  2) 列出現有備份                     【GitLab 伺服器】
  3) 設定資料備份保留 7 天            【GitLab 伺服器】
  4) 註冊自動備份到 crontab           【GitLab 伺服器】
  5) 移除 crontab 的自動備份          【GitLab 伺服器】
  6) 複製設定備份到指定目錄           【GitLab 伺服器】
  7) 說明
  8) 常見問題排查
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) backup_now ;;
        2) list_backups ;;
        3) set_keep_time ;;
        4) register_cron ;;
        5) unregister_cron ;;
        6) copy_config_backups ;;
        7) show_help ;;
        8) show_troubleshooting ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_bk_dir")"
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
