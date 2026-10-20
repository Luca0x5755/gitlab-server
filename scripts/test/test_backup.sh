#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# backup.sh 的純函式（接縫 B）與 backup.sh／backup_auto.sh 的行程層級行為（接縫 C）。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
bk="$here/../backup.sh"
auto="$here/../backup_auto.sh"
repo="$(cd "$here/../.." && pwd)"

. "$bk"

# ══ 純函式 ════════════════════════════════════════════════════════════════════

# ── valid_cron_schedule ──
for s in "0 2 * * *" "*/5 * * * *" "30 3 * * 1-5" "0 0,12 * * *" "0  2  *  *  *"; do assert_status 0 "排程合法：$s" valid_cron_schedule "$s"; done
for s in "" "0 2 * *" "0 2 * * * *" "@daily" "0 2 * * mon" '0 2 * * *;id' '0 2 % * *' $'0 2 * * *\n* * * * *' "0 2 * * \$(id)"; do
    assert_nonzero "排程非法：[$s]" valid_cron_schedule "$s"
done

# ── render_cron_line ──
want="0 2 * * * /bin/bash /opt/ops/scripts/backup_auto.sh >> /var/log/gitlab_backup.log 2>&1 # gitlab-ops:backup_auto"
assert_eq "$want" "$(render_cron_line "0 2 * * *" /opt/ops/scripts/backup_auto.sh /var/log/gitlab_backup.log)" "cron 行格式"
assert_eq "$want" "$(render_cron_line "0   2 * * *" /opt/ops/scripts/backup_auto.sh /var/log/gitlab_backup.log)" "排程空白正規化為單一空格"
assert_nonzero "腳本路徑含空白被拒" render_cron_line "0 2 * * *" "/opt/my ops/backup_auto.sh" /var/log/x.log
assert_nonzero "腳本路徑含分號被拒" render_cron_line "0 2 * * *" "/opt/a;rm/backup_auto.sh" /var/log/x.log
assert_nonzero "日誌路徑非絕對被拒" render_cron_line "0 2 * * *" /opt/ops/backup_auto.sh "x.log"
assert_nonzero "排程非法被拒" render_cron_line "bad" /opt/ops/backup_auto.sh /var/log/x.log

# ── crontab 全文處理（PR-BAK-10：重複註冊不產生重複項目）──
line="$want"
assert_eq "$line" "$(cron_apply "" "$line")" "空 crontab：只有新行"
base=$'MAILTO=root\n0 5 * * * /usr/bin/other-job'
once="$(cron_apply "$base" "$line")"
assert_eq "$base"$'\n'"$line" "$once" "既有項目原樣保留、新行追加在後"
twice="$(cron_apply "$once" "$line")"
assert_eq "$once" "$twice" "重複註冊：結果與一次相同"
assert_eq "1" "$(grep -c 'gitlab-ops:backup_auto' <<<"$twice")" "重複註冊：帶標記的行恰一行"
newline="${line/0 2/30 4}"
assert_eq "1" "$(cron_apply "$once" "$newline" | grep -c 'gitlab-ops:backup_auto')" "改排程再註冊：舊行被取代而非並存"
assert_contains "$(cron_apply "$once" "$newline")" "30 4 * * *" "改排程再註冊：新排程生效"
cron_has_entry "$once" && r=yes || r=no
assert_eq "yes" "$r" "cron_has_entry：有標記行"
cron_has_entry "$base" && r=yes || r=no
assert_eq "no" "$r" "cron_has_entry：沒有標記行"
cron_has_entry "" && r=yes || r=no
assert_eq "no" "$r" "cron_has_entry：空 crontab"
assert_eq "$base" "$(cron_strip "$once")" "cron_strip：移除標記行、其餘不變"
assert_eq "" "$(cron_strip "$line")" "cron_strip：只有標記行時得到空"
assert_eq "" "$(cron_strip "")" "cron_strip：空輸入"
# 使用者自己寫的、剛好含 backup_auto.sh 但沒有標記的行不被動到
mine='5 1 * * * /home/me/backup_auto.sh'
assert_eq "$mine" "$(cron_strip "$mine")" "沒有標記的行不被移除"

# ── path_within ──
path_within /var/opt/gitlab/backups /var/opt/gitlab/backups && r=yes || r=no; assert_eq yes "$r" "path_within：等於"
path_within /var/opt/gitlab/backups/ /var/opt/gitlab/backups && r=yes || r=no; assert_eq yes "$r" "path_within：結尾斜線"
path_within /var/opt/gitlab/backups/sub /var/opt/gitlab/backups && r=yes || r=no; assert_eq yes "$r" "path_within：位於其下"
path_within /var/opt/gitlab/backups-offsite /var/opt/gitlab/backups && r=yes || r=no; assert_eq no "$r" "path_within：同前綴但不同目錄"
path_within /mnt/nas /var/opt/gitlab/backups && r=yes || r=no; assert_eq no "$r" "path_within：無關路徑"

assert_eq "gitlab_rails['backup_keep_time'] = 604800" "$(render_keep_time_block)" "保留 7 天 = 604800 秒"

# ══ 行程層級 ══════════════════════════════════════════════════════════════════

RB_DEFAULT="$T_TMP/default.rb"
printf "## GitLab configuration settings\nexternal_url 'http://x'\n" >"$RB_DEFAULT"

setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/opt" "$SB/data" "$SB/cfg" "$SB/home" "$SB/tmp"
    STUB_LOG="$SB/stub.log"
    CRON_FILE="$SB/crontab.txt"
    SNAP="$SB/snap"
    : >"$STUB_LOG"
    export STUB_LOG CRON_FILE SNAP
    cp "$RB_DEFAULT" "$SB/gitlab.rb"
    cp "$SB/gitlab.rb" "$SB/gitlab.rb.orig"
    rm -f "$OPS_ENV_FILE"
    make_stub "$SB/bin" gitlab-backup '[ "${STUB_BACKUP_RC:-0}" -eq 0 ] || exit "$STUB_BACKUP_RC"; : >"'"$SB"'/data/1776235587_2026_04_15_18.7.6_gitlab_backup.tar"'
    make_stub "$SB/bin" gitlab-ctl 'if [ "$1" = reconfigure ]; then cp "$GITLAB_RB" "$SNAP"; exit "${STUB_RECONF_RC:-0}"; fi; if [ "$1" = backup-etc ]; then [ "${STUB_ETC_RC:-0}" -eq 0 ] || exit "$STUB_ETC_RC"; : >"'"$SB"'/cfg/gitlab_config_1776235587_2026_04_15.tar"; fi'
    make_stub "$SB/bin" apt 'exit 0'
    # crontab 假指令：-l 讀檔（無檔時照真的 crontab 輸出 no crontab 並回 1），- 由 stdin 寫檔
    make_stub "$SB/bin" crontab 'case "$1" in -l) if [ -n "${STUB_CRON_ERR:-}" ]; then echo "$STUB_CRON_ERR" >&2; exit 1; fi; if [ -f "$CRON_FILE" ]; then cat "$CRON_FILE"; else echo "no crontab for root" >&2; exit 1; fi ;; -) cat >"$CRON_FILE" ;; esac'
}
env_run() { # env_run <stdin> <腳本> [KEY=VAL…]
    local input="$1" script="$2"
    shift 2
    printf '%b' "$input" | env PATH="$SB/bin:$PATH" GITLAB_RB="$SB/gitlab.rb" GITLAB_OPT_DIR="$SB/opt" \
        GITLAB_BACKUP_DIR="$SB/data" GITLAB_CONFIG_BACKUP_DIR="$SB/cfg" BACKUP_AUTO_LOG="$SB/backup.log" \
        OPS_FAKE_UID=0 HOME="$SB/home" TMPDIR="$SB/tmp" "$@" bash "$script" 2>&1
}
run_bk() { local i="$1"; shift; env_run "$i" "$bk" "$@"; }
log_has() { grep -qF -- "$1" "$STUB_LOG"; }
count_log() { grep -cE -- "$1" "$STUB_LOG" || true; }

# ── backup_auto.sh（PR-BAK-01、02、12）──
setup_sandbox auto_ok
out="$(env_run '' "$auto")"; rc=$?
assert_eq "0" "$rc" "backup_auto 成功：結束碼 0"
assert_eq "gitlab-backup create CRON=1" "$(sed -n 1p "$STUB_LOG")" "先資料備份"
assert_eq "gitlab-ctl backup-etc" "$(sed -n 2p "$STUB_LOG")" "再設定備份"
assert_eq "2" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "只呼叫這兩個指令"
assert_contains "$(cat "$SB/backup.log")" "備份完成" "日誌記錄完成"

setup_sandbox auto_data_fail
env_run '' "$auto" STUB_BACKUP_RC=1 >/dev/null; rc=$?
assert_eq "1" "$rc" "資料備份失敗：結束碼 1"
assert_eq "0" "$(count_log '^gitlab-ctl backup-etc')" "資料備份失敗：不做設定備份"
assert_contains "$(cat "$SB/backup.log")" "資料備份失敗" "資料備份失敗：日誌有記錄"

setup_sandbox auto_etc_fail
env_run '' "$auto" STUB_ETC_RC=1 >/dev/null; rc=$?
assert_eq "2" "$rc" "設定備份失敗：結束碼 2（非 0）"
assert_eq "1" "$(count_log '^gitlab-backup create')" "設定備份失敗：資料備份已做"

# 清理：只刪超過 7 天的 gitlab_config_*.tar；其餘不動；資料備份不歸本腳本清理
setup_sandbox auto_prune
: >"$SB/cfg/gitlab_config_1000_2026_01_01.tar"
: >"$SB/cfg/gitlab_config_2000_2026_01_02.tar"
: >"$SB/cfg/gitlab_config_3000_2026_10_15.tar"
: >"$SB/cfg/notes.txt"
: >"$SB/data/1111_2025_01_01_18.0.0_gitlab_backup.tar"
touch -d "10 days ago" "$SB/cfg/gitlab_config_1000_2026_01_01.tar" "$SB/cfg/notes.txt" "$SB/data/1111_2025_01_01_18.0.0_gitlab_backup.tar"
touch -d "8 days ago" "$SB/cfg/gitlab_config_2000_2026_01_02.tar"
touch -d "6 days ago" "$SB/cfg/gitlab_config_3000_2026_10_15.tar"
env_run '' "$auto" >/dev/null
assert_eq "no" "$([ -e "$SB/cfg/gitlab_config_1000_2026_01_01.tar" ] && echo yes || echo no)" "10 天前的設定備份被清理"
assert_eq "no" "$([ -e "$SB/cfg/gitlab_config_2000_2026_01_02.tar" ] && echo yes || echo no)" "8 天前的設定備份被清理"
assert_eq "yes" "$([ -e "$SB/cfg/gitlab_config_3000_2026_10_15.tar" ] && echo yes || echo no)" "6 天前的設定備份保留"
assert_eq "yes" "$([ -e "$SB/cfg/notes.txt" ] && echo yes || echo no)" "非 gitlab_config_*.tar 的檔案不動"
assert_eq "yes" "$([ -e "$SB/data/1111_2025_01_01_18.0.0_gitlab_backup.tar" ] && echo yes || echo no)" "舊資料備份不歸本腳本清理"
assert_eq "yes" "$([ -e "$SB/cfg/gitlab_config_1776235587_2026_04_15.tar" ] && echo yes || echo no)" "剛產生的設定備份保留"

setup_sandbox auto_args
env PATH="$SB/bin:$PATH" bash "$auto" foo >/dev/null 2>&1; rc=$?
assert_eq "2" "$rc" "帶參數即拒絕"
assert_eq "0" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "帶參數：不做任何備份"
setup_sandbox auto_nonroot
env_run '' "$auto" OPS_FAKE_UID=1000 >/dev/null; rc=$?
assert_nonzero_rc() { [ "$1" -ne 0 ] && echo yes || echo no; }
assert_eq "yes" "$(assert_nonzero_rc "$rc")" "非 root：非 0"
assert_eq "0" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "非 root：不做任何備份"
setup_sandbox auto_nogl
rmdir "$SB/opt"
out="$(env_run '' "$auto")"
assert_eq "0" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "沒裝 GitLab：不做任何備份"
assert_contains "$out" "【GitLab 伺服器】" "沒裝 GitLab：指向【GitLab 伺服器】"

# ── backup.sh 選單 ──
setup_sandbox menu
assert_status 2 "帶參數即拒絕" env PATH="$SB/bin:$PATH" bash "$bk" foo
assert_status 0 "stdin EOF 離開結束碼 0" bash -c "env PATH='$SB/bin:$PATH' bash '$bk' </dev/null"
menu="$(run_bk 'q\n')"
assert_contains "$menu" "說明" "選單含「說明」"
assert_contains "$menu" "常見問題排查" "選單含「常見問題排查」"
bad=0
while IFS= read -r line; do
    [[ $line =~ ^\ +[0-9]+\) ]] || continue
    [[ $line == *"說明"* || $line == *"常見問題排查"* ]] && continue
    [[ $line == *"【有網路的電腦】"* || $line == *"【GitLab 伺服器】"* ]] || { bad=1; echo "未標示：$line" >&2; }
done <<<"$menu"
assert_eq "0" "$bad" "每個動作項目都標示機器"
help="$(run_bk '7\nq\n')"
for k in "Object Storage" Mattermost Redis "server hooks" 不同 "604800" "gitlab-ctl backup-etc" "/etc/gitlab/config_backup" crontab; do
    assert_contains "$help" "$k" "說明含：$k"
done
fix="$(run_bk '8\nq\n')"
for k in 空間 backup-etc crontab backup_keep_time /var/log/gitlab_backup.log; do
    assert_contains "$fix" "$k" "排查含：$k"
done

# 立即備份（PR-BAK-01）
setup_sandbox now_ok
out="$(run_bk '1\nq\n')"
assert_eq "gitlab-backup create CRON=1" "$(sed -n 1p "$STUB_LOG")" "選單 1：呼叫 backup_auto.sh，先資料備份"
assert_eq "gitlab-ctl backup-etc" "$(sed -n 2p "$STUB_LOG")" "選單 1：再設定備份"
assert_contains "$out" "備份完成" "選單 1：成功訊息"
setup_sandbox now_fail
out="$(run_bk '1\nq\n' STUB_BACKUP_RC=1)"
assert_contains "$out" "資料備份失敗" "選單 1：資料備份失敗有訊息"
assert_contains "$out" "動作未完成" "選單 1：資料備份失敗回報失敗"
assert_not_contains "$out" "備份完成" "選單 1：資料備份失敗不宣稱完成"

# 列出（PR-BAK-04）
setup_sandbox list
: >"$SB/data/1776235587_2026_04_15_18.7.6_gitlab_backup.tar"
: >"$SB/data/1776999999_2026_04_16_18.7.6_gitlab_backup.tar"
: >"$SB/data/unrelated.txt"
: >"$SB/cfg/gitlab_config_1776235587_2026_04_15.tar"
out="$(run_bk '2\nq\n')"
assert_contains "$out" "1776235587_2026_04_15_18.7.6_gitlab_backup.tar" "列出資料備份"
assert_contains "$out" "1776999999_2026_04_16_18.7.6_gitlab_backup.tar" "列出多個資料備份"
assert_contains "$out" "gitlab_config_1776235587_2026_04_15.tar" "列出設定備份"
assert_not_contains "$out" "unrelated.txt" "不列出無關檔案"
setup_sandbox list_empty
out="$(run_bk '2\nq\n')"
assert_contains "$out" "（沒有）" "沒有備份：顯示（沒有）"
assert_not_contains "$out" "動作未完成" "沒有備份不算錯誤"

# 保留 7 天（PR-BAK-03）
setup_sandbox keep
out="$(run_bk '3\nq\n')"
{ cat "$SB/gitlab.rb.orig"; printf '# >>> gitlab-ops:backup_keep_time BEGIN 腳本維護，重跑整段取代，請勿手改\ngitlab_rails['"'"'backup_keep_time'"'"'] = 604800\n# <<< gitlab-ops:backup_keep_time END\n'; } >"$SB/want"
assert_file_eq "$SB/want" "$SB/gitlab.rb" "管理區塊寫入 backup_keep_time = 604800，區塊外不變"
assert_file_eq "$SB/want" "$SNAP" "reconfigure 當下已含區塊"
assert_eq "1" "$(count_log '^gitlab-ctl reconfigure')" "reconfigure 一次"
out="$(run_bk '3\n3\nq\n')"
assert_eq "1" "$(grep -c 'gitlab-ops:backup_keep_time BEGIN' "$SB/gitlab.rb")" "重跑仍只有一段"
setup_sandbox keep_fail
out="$(run_bk '3\nyes\nq\n' STUB_RECONF_RC=1)"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "reconfigure 失敗＋yes：還原"
setup_sandbox keep_nonroot
out="$(run_bk '3\nq\n' OPS_FAKE_UID=1000)"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "非 root：gitlab.rb 不動"

# crontab 註冊／移除（PR-BAK-10）
setup_sandbox cron
out="$(run_bk '4\n\nq\n')"
assert_eq "1" "$(grep -c 'gitlab-ops:backup_auto' "$CRON_FILE")" "註冊：crontab 有一筆"
assert_contains "$(cat "$CRON_FILE")" "0 2 * * * /bin/bash $(cd "$here/.." && pwd)/backup_auto.sh >> $SB/backup.log 2>&1" "註冊：預設 02:00，指向本 repo 的 backup_auto.sh"
out="$(run_bk '4\n\n4\n\nq\n')"
assert_eq "1" "$(grep -c 'gitlab-ops:backup_auto' "$CRON_FILE")" "重複註冊：仍只有一筆"
out="$(run_bk '4\n30 4 * * 1\nq\n')"
assert_eq "1" "$(grep -c 'gitlab-ops:backup_auto' "$CRON_FILE")" "改排程再註冊：仍只有一筆"
assert_contains "$(cat "$CRON_FILE")" "30 4 * * 1 /bin/bash" "改排程再註冊：新排程生效"
assert_contains "$(cat "$OPS_ENV_FILE")" "BAK_CRON_SCHEDULE=30 4 * * 1" "排程存入參數檔"
printf 'MAILTO=root\n0 5 * * * /usr/bin/other\n' >"$CRON_FILE"
out="$(run_bk '4\n\nq\n')"
assert_contains "$(cat "$CRON_FILE")" "0 5 * * * /usr/bin/other" "註冊不動既有的 crontab 項目"
assert_contains "$(cat "$CRON_FILE")" "MAILTO=root" "註冊不動既有的環境行"
out="$(run_bk '5\nq\n')"
assert_eq "0" "$(grep -c 'gitlab-ops:backup_auto' "$CRON_FILE")" "移除：標記行消失"
assert_contains "$(cat "$CRON_FILE")" "0 5 * * * /usr/bin/other" "移除不動既有項目"
out="$(run_bk '5\nq\n')"
assert_contains "$out" "不需移除" "沒有可移除的：說明且不算失敗"
assert_not_contains "$out" "動作未完成" "沒有可移除的：不算失敗"
setup_sandbox cron_bad
out="$(run_bk '4\nbad\n0 2 * * *;id\n')"
assert_not_contains "$(cat "$CRON_FILE" 2>/dev/null)" ";id" "排程非法：不被寫入 crontab（EOF 後退回預設排程）"
setup_sandbox cron_readerr
printf '0 5 * * * keepme\n' >"$CRON_FILE"
out="$(run_bk '4\n\nq\n' STUB_CRON_ERR='crontab: permission denied')"
assert_eq "0 5 * * * keepme" "$(cat "$CRON_FILE")" "crontab 讀取出錯：不覆寫既有內容"
assert_contains "$out" "動作未完成" "crontab 讀取出錯：回報失敗"
setup_sandbox cron_nonroot
out="$(run_bk '4\n\nq\n' OPS_FAKE_UID=1000)"
assert_eq "no" "$([ -f "$CRON_FILE" ] && echo yes || echo no)" "非 root：不寫 crontab"

# 複製設定備份（PR-BAK-11）
setup_sandbox copy
mkdir -p "$SB/offsite"
: >"$SB/cfg/gitlab_config_1_2026_04_15.tar"
: >"$SB/cfg/gitlab_config_2_2026_04_16.tar"
chmod 600 "$SB/cfg"/gitlab_config_*.tar
out="$(run_bk "6\n$SB/offsite/cfgcopy\nq\n")"
assert_eq "yes" "$([ -f "$SB/offsite/cfgcopy/gitlab_config_1_2026_04_15.tar" ] && [ -f "$SB/offsite/cfgcopy/gitlab_config_2_2026_04_16.tar" ] && echo yes || echo no)" "兩個設定備份都複製"
assert_eq "600" "$(stat -c %a "$SB/offsite/cfgcopy/gitlab_config_1_2026_04_15.tar")" "複製後保留權限 600"
assert_eq "700" "$(stat -c %a "$SB/offsite/cfgcopy")" "新建的目的地目錄為 700"
assert_contains "$(cat "$OPS_ENV_FILE")" "BAK_COPY_DIR=$SB/offsite/cfgcopy" "目錄記入參數檔"
assert_contains "$out" "已複製 2 個" "報告複製個數"
out="$(run_bk "6\n\nq\n")"
assert_contains "$out" "已複製 0 個" "再次執行（預設沿用上次目錄）：沒有新檔可複製"
assert_contains "$out" "略過：2" "已存在的略過"
# 不覆蓋既有檔
echo keep >"$SB/offsite/cfgcopy/gitlab_config_1_2026_04_15.tar"
out="$(run_bk "6\n\nq\n")"
assert_eq "keep" "$(cat "$SB/offsite/cfgcopy/gitlab_config_1_2026_04_15.tar")" "不覆蓋目的地既有檔"
setup_sandbox copy_same
: >"$SB/cfg/gitlab_config_1_2026_04_15.tar"
out="$(run_bk "6\n$SB/data/offsite\nq\n")"
assert_contains "$out" "不能位於資料備份目錄" "目的地在資料備份目錄下：拒絕"
assert_eq "no" "$([ -d "$SB/data/offsite" ] && echo yes || echo no)" "拒絕時不建立目錄"
out="$(run_bk "6\n$SB/cfg\nq\n")"
assert_contains "$out" "設定備份目錄本身" "目的地是設定備份目錄：拒絕"
out="$(run_bk "6\nrelative/dir\n")"
assert_eq "no" "$([ -d relative ] && echo yes || echo no)" "相對路徑被驗證擋下"
setup_sandbox copy_nosrc
rmdir "$SB/cfg"
out="$(run_bk "6\n$SB/offsite\nq\n")"
assert_contains "$out" "立即備份" "沒有設定備份目錄：指向選單 1"
setup_sandbox copy_nonroot
: >"$SB/cfg/gitlab_config_1_2026_04_15.tar"
out="$(run_bk "6\n$SB/offsite\nq\n" OPS_FAKE_UID=1000)"
assert_eq "no" "$([ -d "$SB/offsite" ] && echo yes || echo no)" "非 root：不複製"

# README 與舊腳本
assert_eq "no" "$([ -e "$repo/scripts/gitlab_backup.sh" ] && echo yes || echo no)" "舊的 gitlab_backup.sh 已改名"
assert_eq "no" "$(grep -q 'gitlab_backup\.sh' "$repo/README.md" && echo yes || echo no)" "README 不再提 gitlab_backup.sh"
assert_contains "$(cat "$repo/README.md")" "backup_auto.sh" "README 指向 backup_auto.sh"
