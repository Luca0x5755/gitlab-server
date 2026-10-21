#!/usr/bin/env bash
# GitLab 備份選單腳本：立即備份、列出備份、設定資料備份保留 7 天、註冊／移除 crontab、
# 複製設定備份離機、還原與還原後驗證。只有互動選單，不收參數。
# 說明與排查內容見選單項目。
# 真正做備份的是 backup_auto.sh（cron、升級前、本選單共用同一份）。
#
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得函式而不啟動選單。
#
# 可由環境變數覆寫的路徑（供測試用，預設為正式路徑；它們不是命令列參數）：
#   GITLAB_RB、GITLAB_BACKUP_DIR、GITLAB_CONFIG_BACKUP_DIR、BACKUP_AUTO_LOG、GITLAB_OPT_DIR、
#   GITLAB_RESTORE_ROOT（設定備份解開的根目錄，預設 /）。

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

# ── 還原（純函式）────────────────────────────────────────────────────────────

# 資料備份檔名 → 備份 ID（還原時 BACKUP= 後面接的字串）。
# 取 basename（不含路徑），去掉 _gitlab_backup.tar 後綴；剩下必須是
# <時間戳>_<YYYY>_<MM>_<DD>_<版本>，版本可帶 -ce／-ee。不符回非 0 且不輸出。
backup_id_from_name() {
    local base="${1##*/}" id re='^[0-9]+_[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+)?$'
    [[ $base == *_gitlab_backup.tar ]] || return 1
    id="${base%_gitlab_backup.tar}"
    [[ $id =~ $re ]] || return 1
    printf '%s\n' "$id"
}

# 備份 ID → 版本部分（例 1776235587_2026_04_15_18.7.6 → 18.7.6；帶 -ce／-ee 時保留）。
backup_id_version() {
    local re='^[0-9]+_[0-9]{4}_[0-9]{2}_[0-9]{2}_(.+)$'
    [[ $1 =~ $re ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# 已裝套件版本（dpkg 的 Version，例 18.7.6-ce.0）是否與備份 ID 的版本一致（PR-BAK-05）。
# 只比 主.次.修；已裝必須是 CE（-ce.N）；備份 ID 帶 -ee 即視為不同類型。不一致回非 0 並在 stderr 說明。
restore_version_check() { # restore_version_check <備份 ID> <已裝套件版本>
    local bver core re='^([0-9]+\.[0-9]+\.[0-9]+)-ce\.[0-9]+$'
    bver="$(backup_id_version "$1")" || { echo "✗ 備份 ID 格式不符：$1" >&2; return 1; }
    if [[ $2 =~ $re ]]; then
        core="${BASH_REMATCH[1]}"
    else
        echo "✗ 已安裝的版本「$2」不是 GitLab CE（x.y.z-ce.N）。備份與目標的版本及類型 (CE/EE) 必須完全一致。" >&2
        return 1
    fi
    if [ "$bver" = "$core" ] || [ "$bver" = "$core-ce" ]; then
        return 0
    fi
    echo "✗ 版本不一致：備份是 $bver，這台已安裝 $2。請先安裝與備份相同的 GitLab 版本（CE）再還原。" >&2
    return 1
}

# 設定備份 tar 的內容列表（stdin，一行一條目）是否安全：每條都必須在 etc/gitlab 之下，
# 不得絕對路徑、不得含 .. 。空列表視為不安全。
config_tar_entries_ok() {
    local line n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line#./}"
        [[ $line == "etc/gitlab" || $line == etc/gitlab/* ]] || return 1
        [[ /$line/ != */../* ]] || return 1
    done
    [ "$n" -gt 0 ]
}

# 還原後的五項驗證（依序）：每行「說明<TAB>rake 參數…」。
restore_verify_tasks() {
    printf '%s\t%s\n' \
        "gitlab:check" "gitlab:check SANITIZE=true" \
        "gitlab:doctor:secrets" "gitlab:doctor:secrets" \
        "gitlab:artifacts:check" "gitlab:artifacts:check" \
        "gitlab:lfs:check" "gitlab:lfs:check" \
        "gitlab:uploads:check" "gitlab:uploads:check"
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

# 已裝的 gitlab-ce 套件版本；獨立成函式讓測試能換掉。
installed_gitlab_pkg_version() { dpkg-query -W -f='${Version}\n' gitlab-ce; }

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

還原（選單 7）——前置條件：
  - 目標主機的 GitLab 版本與類型 (CE/EE) 必須與備份時完全一致（腳本會比對已裝版本與
    資料備份檔名中的版本，不符即中止）。
  - 目標主機已安裝 GitLab，且至少執行過一次 sudo gitlab-ctl reconfigure。
  - 目標主機不應有既有的正式資料：還原會覆蓋（資料庫、儲存庫、附件，以及 /etc/gitlab 的設定與金鑰）。
  - 準備好資料備份檔（*_gitlab_backup.tar）與設定備份檔（gitlab_config_*.tar）。
  還原依序執行：還原設定備份並 reconfigure → 資料備份放入 /var/opt/gitlab/backups 並
  chown git:git → 停 puma 與 sidekiq → gitlab-backup restore BACKUP=<備份 ID> →
  reconfigure 與 start → 驗證。備份 ID 由檔名自動取出，只含 <時間戳>_<日期>_<版本>：
    備份檔名：1776235587_2026_04_15_18.7.6_gitlab_backup.tar
    備份 ID ：1776235587_2026_04_15_18.7.6   （不含路徑、不含 _gitlab_backup.tar）
  還原前須輸入 yes。選單 8 可單獨重跑還原後驗證（gitlab:check SANITIZE=true、
  gitlab:doctor:secrets、gitlab:artifacts:check、gitlab:lfs:check、gitlab:uploads:check）。
  驗證之外，還請：登入 Web 介面確認帳號與專案存在、隨機 clone 一個專案確認 Git 資料完整、
  確認 CI/CD 變數與 Runner 等設定正常。

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
  還原（選單 7）排查：
    「版本不一致」：先安裝與備份相同版本的 gitlab-ce（install.sh 或 dpkg -i），再重跑。
    「備份 ID 格式不符」：檔名須為 <時間戳>_<日期>_<版本>_gitlab_backup.tar，不要改檔名。
    gitlab-backup restore 說找不到備份：確認檔案在 /var/opt/gitlab/backups、擁有者 git:git，
      且 BACKUP= 只填 ID（不含路徑、不含 _gitlab_backup.tar）。
    設定備份被拒絕：內容必須全在 etc/gitlab 之下（backup-etc 產生的才符合）。
    還原中途失敗：puma 與 sidekiq 此時是停止的；排除原因後可重跑選單 7，
      或手動 sudo gitlab-ctl start 恢復服務。
    驗證 gitlab:doctor:secrets 失敗：設定備份與資料備份不是同一時間的一組，
      gitlab-secrets.json 解不開資料；請改用同一次備份的設定備份。
    驗證 gitlab:check 有 FAILED：照其輸出修正；剛 reconfigure 完幾分鐘內的暫時失敗可重跑選單 8。
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

# 在資料備份／設定備份目錄裡找最新的檔案（預設值用）；沒有回空。
newest_file() { # newest_file <目錄> <樣式>
    find "$1" -maxdepth 1 -type f -name "$2" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-
}

# 還原後驗證：五項各自執行並彙總，不因單項失敗而中止。任一失敗回非 0。
verify_restore() {
    local label args ok=() bad=() line rc
    require_machine server
    have_cmd gitlab-rake || die "找不到 gitlab-rake。"
    while IFS=$'\t' read -r label args; do
        echo "── gitlab-rake $args ──"
        rc=0
        # shellcheck disable=SC2086  # args 是固定的任務名稱加 SANITIZE=true，需要依空白拆開
        gitlab-rake $args || rc=$?
        if [ "$rc" -eq 0 ]; then ok+=("$label"); else bad+=("$label"); fi
    done < <(restore_verify_tasks)
    echo "── 驗證彙總 ──"
    for line in "${ok[@]}"; do echo "  ✓ $line"; done
    for line in "${bad[@]}"; do echo "  ✗ $line"; done
    if [ "${#bad[@]}" -gt 0 ]; then
        echo "✗ ${#bad[@]} 項驗證失敗，見上方輸出與「常見問題排查」。" >&2
        return 1
    fi
    echo "✓ 五項驗證全部通過。請再登入 Web 介面、clone 專案、確認 CI/CD 變數與 Runner。"
}

restore_backup() {
    local data conf id pkg_ver dest root f
    require_machine server
    require_root
    have_cmd gitlab-backup || die "找不到 gitlab-backup。"
    have_cmd gitlab-ctl || die "找不到 gitlab-ctl。"
    have_cmd dpkg-query || die "找不到 dpkg-query。"
    have_cmd tar || die "找不到 tar。"
    conf="$(ask_param RST_CONFIG_TAR "設定備份檔完整路徑（gitlab_config_*.tar）" "$(newest_file "$(config_backup_dir)" 'gitlab_config_*.tar')" valid_local_path)"
    data="$(ask_param RST_DATA_TAR "資料備份檔完整路徑（*_gitlab_backup.tar）" "$(newest_file "$(data_backup_dir)" '*_gitlab_backup.tar')" valid_local_path)"
    [ -f "$conf" ] || die "找不到設定備份檔：$conf"
    [ -f "$data" ] || die "找不到資料備份檔：$data"
    id="$(backup_id_from_name "$data")" \
        || die "資料備份檔名不符（須為 <時間戳>_<日期>_<版本>_gitlab_backup.tar）：${data##*/}。請勿改檔名。"
    pkg_ver="$(installed_gitlab_pkg_version)" || die "讀不到已安裝的 gitlab-ce 版本。請先安裝與備份相同版本的 GitLab CE。"
    restore_version_check "$id" "$pkg_ver" || die "版本檢查未通過，未做任何變更。"
    tar -tf "$conf" | config_tar_entries_ok \
        || die "設定備份檔內容不安全或不是 backup-etc 的產物（條目須全在 etc/gitlab 之下）：$conf"

    cat <<TXT
即將還原（備份 ID：$id，已安裝版本 $pkg_ver，版本一致）：
  設定備份：$conf
  資料備份：$data
⚠ 這會覆蓋這台主機上：
  - /etc/gitlab 的設定與金鑰（gitlab.rb、gitlab-secrets.json、ssl、trusted-certs…）
  - GitLab 的全部資料：資料庫、儲存庫、附件、Wiki…
  目標主機不應有需要保留的正式資料。
TXT
    confirm "確定要還原？" || { echo "已取消，未做任何變更。"; return 0; }

    root="${GITLAB_RESTORE_ROOT:-/}"
    echo "── ① 還原設定與金鑰 ──"
    if [ -f "$(gitlab_rb_file)" ]; then backup_gitlab_rb || die "備份現有 gitlab.rb 失敗，中止。"; fi
    tar -xvf "$conf" -C "$root" || die "解開設定備份失敗。"
    gitlab_reconfigure || die "設定備份還原後 reconfigure 失敗，中止（資料備份尚未還原）。"

    echo "── ② 放入備份目錄並 chown git:git ──"
    dest="$(data_backup_dir)"
    mkdir -p "$dest" || die "無法建立 $dest。"
    f="$dest/${data##*/}"
    if [ "$data" -ef "$f" ]; then
        echo "  備份檔已在 $dest，不需複製。"
    else
        cp -- "$data" "$f" || die "複製資料備份到 $dest 失敗。"
    fi
    chown git:git -- "$f" || die "chown git:git 失敗：$f"

    echo "── ③ 停止寫入相關服務 ──"
    gitlab-ctl stop puma || die "停止 puma 失敗。"
    gitlab-ctl stop sidekiq || die "停止 sidekiq 失敗。"
    gitlab-ctl status || true

    echo "── ④ 執行還原（BACKUP=$id）──"
    if ! gitlab-backup restore "BACKUP=$id" force=yes; then
        echo "✗ gitlab-backup restore 失敗。puma 與 sidekiq 目前是停止的；排除原因後可重跑本項，" >&2
        echo "  或執行 sudo gitlab-ctl start 恢復服務。" >&2
        return 1
    fi

    echo "── ⑤ reconfigure 與啟動 ──"
    gitlab_reconfigure || die "reconfigure 失敗。"
    gitlab-ctl start || die "gitlab-ctl start 失敗。"
    gitlab-ctl status || true

    echo "── ⑥ 驗證 ──"
    verify_restore
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
  7) 還原（會覆蓋現有資料）           【GitLab 伺服器】
  8) 還原後驗證（五項 rake 檢查）     【GitLab 伺服器】
  9) 說明
  10) 常見問題排查
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
        7) restore_backup ;;
        8) verify_restore ;;
        9) show_help ;;
        10) show_troubleshooting ;;
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
