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
    make_stub "$SB/bin" gitlab-backup 'if [ "$1" = restore ]; then exit "${STUB_RESTORE_RC:-0}"; fi; [ "${STUB_BACKUP_RC:-0}" -eq 0 ] || exit "$STUB_BACKUP_RC"; : >"'"$SB"'/data/1776235587_2026_04_15_18.7.6_gitlab_backup.tar"'
    make_stub "$SB/bin" gitlab-ctl 'if [ "$1" = reconfigure ]; then cp "$GITLAB_RB" "$SNAP"; exit "${STUB_RECONF_RC:-0}"; fi; if [ "$1" = backup-etc ]; then [ "${STUB_ETC_RC:-0}" -eq 0 ] || exit "$STUB_ETC_RC"; : >"'"$SB"'/cfg/gitlab_config_1776235587_2026_04_15.tar"; fi'
    # docker 假指令（手寫，只有 exec 才記錄到 STUB_LOG，探測不記錄）：
    # 預設回報「沒有容器」，所以不受開發機上真實 docker 影響；STUB_DOCKER_RUNNING 切換情境：
    #   1 名為 gitlab 的容器執行中；stopped 已停止；runner 只有名為 gitlab-runner 的容器；down docker 本身失敗。
    export STUB_SB="$SB"
    cat >"$SB/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    inspect)
        name="${*: -1}"
        case "${STUB_DOCKER_RUNNING:-}" in
            1) [ "$name" = gitlab ] && { echo true; exit 0; } ;;
            stopped) [ "$name" = gitlab ] && { echo false; exit 0; } ;;
            runner) [ "$name" = gitlab-runner ] && { echo true; exit 0; } ;;
        esac
        exit 1 ;;
    exec)
        echo "docker $*" >>"${STUB_LOG:-/dev/null}"
        case "$3 $4" in
            "gitlab-backup create")
                [ "${STUB_BACKUP_RC:-0}" -eq 0 ] || exit "$STUB_BACKUP_RC"
                : >"$STUB_SB/data/1776235587_2026_04_15_18.7.6_gitlab_backup.tar" ;;
            "gitlab-ctl backup-etc")
                [ "${STUB_ETC_RC:-0}" -eq 0 ] || exit "$STUB_ETC_RC"
                : >"$STUB_SB/cfg/gitlab_config_1776235587_2026_04_15.tar" ;;
        esac
        exit 0 ;;
esac
exit 1
STUB
    chmod +x "$SB/bin/docker"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" dpkg-query 'if [ -n "${STUB_NOPKG:-}" ]; then exit 1; fi; echo "${STUB_PKG_VERSION:-18.7.6-ce.0}"'
    make_stub "$SB/bin" chown 'exit "${STUB_CHOWN_RC:-0}"'
    make_stub "$SB/bin" gitlab-rake 'case " ${STUB_RAKE_FAIL:-} " in *" $1 "*) exit 1 ;; esac; exit 0'
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

# ── 容器模式（PR-DKR-40、41、42）──
# 純函式：模式判斷與 docker exec 組裝（沙箱的假 docker）
setup_sandbox mode
mode_of() { ( PATH="$SB/bin:$PATH" STUB_DOCKER_RUNNING="$1" gitlab_mode ); }
assert_eq "container" "$(mode_of 1)" "gitlab_mode：gitlab 容器執行中 → container"
assert_eq "deb" "$(mode_of '')" "gitlab_mode：沒有容器 → deb"
assert_eq "deb" "$(mode_of stopped)" "gitlab_mode：容器已停止 → deb"
assert_eq "deb" "$(mode_of runner)" "gitlab_mode：只有 gitlab-runner 容器 → deb"
assert_eq "deb" "$(mode_of down)" "gitlab_mode：docker 失敗 → deb"
nodocker="$T_TMP/emptybin"; mkdir -p "$nodocker"
assert_eq "deb" "$( PATH="$nodocker" gitlab_mode )" "gitlab_mode：沒有 docker 指令 → deb"
assert_eq "docker"$'\n'"exec"$'\n'"gitlab"$'\n'"gitlab-backup"$'\n'"create"$'\n'"CRON=1" \
    "$( PATH="$SB/bin:$PATH" STUB_DOCKER_RUNNING=1 gitlab_exec_args gitlab-backup create CRON=1 )" "gitlab_exec_args：容器模式加 docker exec gitlab 前綴"
assert_eq "gitlab-ctl"$'\n'"backup-etc" "$( PATH="$SB/bin:$PATH" gitlab_exec_args gitlab-ctl backup-etc )" "gitlab_exec_args：deb 模式只有指令本身"

# backup_auto.sh：容器模式沙箱（沒有 /opt/gitlab、宿主機沒有 gitlab-backup／gitlab-ctl）
setup_container() { # setup_container <名稱>
    setup_sandbox "$1"
    rmdir "$SB/opt"
    rm -f "$SB/bin/gitlab-backup" "$SB/bin/gitlab-ctl"
    export STUB_DOCKER_RUNNING=1
}
setup_container c_ok
out="$(env_run '' "$auto")"; rc=$?
assert_eq "0" "$rc" "容器模式備份成功：結束碼 0"
assert_eq "docker exec gitlab gitlab-backup create CRON=1" "$(sed -n 1p "$STUB_LOG")" "容器模式：先 docker exec 資料備份"
assert_eq "docker exec gitlab gitlab-ctl backup-etc" "$(sed -n 2p "$STUB_LOG")" "容器模式：再 docker exec 設定備份"
assert_eq "2" "$(wc -l <"$STUB_LOG" | tr -d ' ')" "容器模式：只有這兩個 docker 呼叫"
assert_contains "$(cat "$SB/backup.log")" "備份完成" "容器模式：日誌記錄完成"

setup_container c_data_fail
env_run '' "$auto" STUB_BACKUP_RC=1 >/dev/null; rc=$?
assert_eq "1" "$rc" "容器模式資料備份失敗：結束碼 1"
assert_eq "1" "$(count_log '^docker exec gitlab gitlab-backup create CRON=1')" "容器模式資料備份失敗：確實走 docker exec"
assert_eq "0" "$(count_log 'backup-etc')" "容器模式資料備份失敗：不做設定備份"
setup_container c_etc_fail
env_run '' "$auto" STUB_ETC_RC=1 >/dev/null; rc=$?
assert_eq "2" "$rc" "容器模式設定備份失敗：結束碼 2"

setup_container c_prune
: >"$SB/cfg/gitlab_config_1000_2026_01_01.tar"
: >"$SB/cfg/gitlab_config_3000_2026_10_15.tar"
: >"$SB/data/1111_2025_01_01_18.0.0_gitlab_backup.tar"
touch -d "8 days ago" "$SB/cfg/gitlab_config_1000_2026_01_01.tar"
touch -d "6 days ago" "$SB/cfg/gitlab_config_3000_2026_10_15.tar"
touch -d "10 days ago" "$SB/data/1111_2025_01_01_18.0.0_gitlab_backup.tar"
env_run '' "$auto" >/dev/null
assert_eq "no" "$([ -e "$SB/cfg/gitlab_config_1000_2026_01_01.tar" ] && echo yes || echo no)" "容器模式：8 天前的設定備份被清理"
assert_eq "yes" "$([ -e "$SB/cfg/gitlab_config_3000_2026_10_15.tar" ] && echo yes || echo no)" "容器模式：6 天前的設定備份保留"
assert_eq "yes" "$([ -e "$SB/data/1111_2025_01_01_18.0.0_gitlab_backup.tar" ] && echo yes || echo no)" "容器模式：資料備份不歸本腳本清理"

# backup.sh 選單：容器模式下立即備份與 crontab 註冊／移除
setup_container c_menu_now
out="$(run_bk '1\nq\n')"
assert_eq "docker exec gitlab gitlab-backup create CRON=1" "$(sed -n 1p "$STUB_LOG")" "容器模式選單 1：docker exec 資料備份"
assert_contains "$out" "備份完成" "容器模式選單 1：成功訊息"
setup_container c_menu_cron
run_bk '4\n\nq\n' >/dev/null
run_bk '4\n\nq\n' >/dev/null
assert_eq "1" "$(grep -c 'gitlab-ops:backup_auto' "$CRON_FILE")" "容器模式選單 4：重複註冊只有一筆"
run_bk '5\nq\n' >/dev/null
assert_eq "0" "$(grep -c 'gitlab-ops:backup_auto' "$CRON_FILE" || true)" "容器模式選單 5：移除"
unset STUB_DOCKER_RUNNING

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
help="$(run_bk '9\nq\n')"
for k in "Object Storage" Mattermost Redis "server hooks" 不同 "604800" "gitlab-ctl backup-etc" "/etc/gitlab/config_backup" crontab; do
    assert_contains "$help" "$k" "說明含：$k"
done
fix="$(run_bk '10\nq\n')"
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

# ══ ISSUE-007 還原（PR-BAK-05～09）══

# ── backup_id_from_name：含路徑、含後綴、含版本號（文件強調的常見出錯點）──
ID=1776235587_2026_04_15_18.7.6
assert_eq "$ID" "$(backup_id_from_name 1776235587_2026_04_15_18.7.6_gitlab_backup.tar)" "純檔名 → ID"
assert_eq "$ID" "$(backup_id_from_name /var/opt/gitlab/backups/1776235587_2026_04_15_18.7.6_gitlab_backup.tar)" "含絕對路徑 → ID 不含路徑"
assert_eq "$ID" "$(backup_id_from_name ./dl/sub/1776235587_2026_04_15_18.7.6_gitlab_backup.tar)" "含相對路徑 → ID 不含路徑"
assert_eq "1493107454_2018_04_25_10.6.4-ce" "$(backup_id_from_name 1493107454_2018_04_25_10.6.4-ce_gitlab_backup.tar)" "版本帶 -ce 時保留"
assert_not_contains "$(backup_id_from_name /x/$ID'_gitlab_backup.tar')" "gitlab_backup" "ID 不含 _gitlab_backup.tar 後綴"
assert_not_contains "$(backup_id_from_name /x/$ID'_gitlab_backup.tar')" "/" "ID 不含斜線"
for n in "" foo.tar "${ID}_gitlab_backup.tar.gz" "${ID}.tar" "${ID}_gitlab_backup.tar.bak" "abc_2026_04_15_18.7.6_gitlab_backup.tar" "1776235587_2026_04_15_gitlab_backup.tar" "1776235587_2026_4_15_18.7.6_gitlab_backup.tar" "gitlab_backup.tar" "${ID};id_gitlab_backup.tar" "1776235587_2026_04_15_18.7_gitlab_backup.tar"; do
    assert_nonzero "非法備份檔名：[$n]" backup_id_from_name "$n"
done
assert_eq "18.7.6" "$(backup_id_version $ID)" "ID → 版本"
assert_eq "10.6.4-ce" "$(backup_id_version 1493107454_2018_04_25_10.6.4-ce)" "ID → 版本（帶 -ce）"
assert_nonzero "非法 ID 取不到版本" backup_id_version "nonsense"

# ── restore_version_check（PR-BAK-05）──
assert_status 0 "版本一致" restore_version_check "$ID" 18.7.6-ce.0
assert_status 0 "版本一致（-ce.1 修訂不影響）" restore_version_check "$ID" 18.7.6-ce.1
assert_status 0 "ID 帶 -ce 且一致" restore_version_check 1493107454_2018_04_25_10.6.4-ce 10.6.4-ce.0
assert_nonzero "修訂號不同" restore_version_check "$ID" 18.7.7-ce.0
assert_nonzero "次版本不同" restore_version_check "$ID" 18.8.6-ce.0
assert_nonzero "主版本不同" restore_version_check "$ID" 17.7.6-ce.0
assert_nonzero "18.7.6 不等於 18.7.60" restore_version_check "$ID" 18.7.60-ce.0
assert_nonzero "ID 是 -ee：與 CE 不符" restore_version_check 1493107454_2018_04_25_10.6.4-ee 10.6.4-ce.0
assert_nonzero "已裝是 EE" restore_version_check "$ID" 18.7.6-ee.0
assert_nonzero "已裝版本格式怪異" restore_version_check "$ID" "garbage"
assert_nonzero "ID 非法" restore_version_check "bad" 18.7.6-ce.0
assert_contains "$(restore_version_check "$ID" 17.0.0-ce.0 2>&1)" "17.0.0-ce.0" "不一致訊息列出已裝版本"
assert_contains "$(restore_version_check "$ID" 17.0.0-ce.0 2>&1)" "18.7.6" "不一致訊息列出備份版本"

# ── config_tar_entries_ok ──
assert_status 0 "etc/gitlab 之下全部 OK" bash -c ". '$bk'; printf 'etc/gitlab/\netc/gitlab/gitlab.rb\netc/gitlab/trusted-certs/\netc/gitlab/ssl/a.crt\n' | config_tar_entries_ok"
assert_status 0 "./ 開頭也 OK" bash -c ". '$bk'; printf './etc/gitlab/gitlab.rb\n' | config_tar_entries_ok"
assert_nonzero "絕對路徑被拒" bash -c ". '$bk'; printf '/etc/gitlab/gitlab.rb\n' | config_tar_entries_ok"
assert_nonzero "含 .. 被拒" bash -c ". '$bk'; printf 'etc/gitlab/../passwd\n' | config_tar_entries_ok"
assert_nonzero "etc/gitlab 之外被拒" bash -c ". '$bk'; printf 'etc/gitlab/a\netc/shadow\n' | config_tar_entries_ok"
assert_nonzero "etc/gitlab-evil 被拒" bash -c ". '$bk'; printf 'etc/gitlab-evil/x\n' | config_tar_entries_ok"
assert_nonzero "空列表被拒" bash -c ". '$bk'; printf '' | config_tar_entries_ok"
assert_nonzero ".. 結尾被拒" bash -c ". '$bk'; printf 'etc/gitlab/..\n' | config_tar_entries_ok"

# ── restore_verify_tasks：五項、順序固定 ──
assert_eq $'gitlab:check\tgitlab:check SANITIZE=true\ngitlab:doctor:secrets\tgitlab:doctor:secrets\ngitlab:artifacts:check\tgitlab:artifacts:check\ngitlab:lfs:check\tgitlab:lfs:check\ngitlab:uploads:check\tgitlab:uploads:check' "$(restore_verify_tasks)" "五項驗證依序"

# ── 行程層級 ──
CFGNAME=gitlab_config_1776235587_2026_04_15.tar
mk_fixtures() { # 在 $SB/in 放設定備份與資料備份
    mkdir -p "$SB/in" "$SB/stage/etc/gitlab/trusted-certs" "$SB/root"
    printf "external_url 'http://restored'\n" >"$SB/stage/etc/gitlab/gitlab.rb"
    printf '{"restored":true}\n' >"$SB/stage/etc/gitlab/gitlab-secrets.json"
    tar -cf "$SB/in/$CFGNAME" -C "$SB/stage" etc/gitlab
    : >"$SB/in/${ID}_gitlab_backup.tar"
}
rst_in() { printf '7\\n%s\\n%s\\n%s\\n' "$SB/in/$CFGNAME" "$SB/in/${ID}_gitlab_backup.tar" "$1"; }   # 字面 \n：$(…) 會吃掉結尾換行，交給 run_bk 的 printf %b 展開
run_rst() { # run_rst <stdin> [KEY=VAL…]
    local input="$1"
    shift
    run_bk "$input" GITLAB_RESTORE_ROOT="$SB/root" "$@"
}
seq_of() { grep -E '^(gitlab-ctl|gitlab-backup|gitlab-rake|chown)' "$STUB_LOG" | tr '\n' '|'; }

setup_sandbox rst_ok
mk_fixtures
out="$(run_rst "$(rst_in yes)q\n")"
assert_eq "yes" "$(grep -q restored "$SB/root/etc/gitlab/gitlab.rb" && echo yes || echo no)" "① 設定備份已解開到根目錄"
assert_eq "yes" "$([ -f "$SB/root/etc/gitlab/gitlab-secrets.json" ] && echo yes || echo no)" "① 金鑰檔也還原"
want="gitlab-ctl reconfigure|chown git:git -- $SB/data/${ID}_gitlab_backup.tar|gitlab-ctl stop puma|gitlab-ctl stop sidekiq|gitlab-ctl status|gitlab-backup restore BACKUP=$ID force=yes|gitlab-ctl reconfigure|gitlab-ctl start|gitlab-ctl status|gitlab-rake gitlab:check SANITIZE=true|gitlab-rake gitlab:doctor:secrets|gitlab-rake gitlab:artifacts:check|gitlab-rake gitlab:lfs:check|gitlab-rake gitlab:uploads:check|"
assert_eq "$want" "$(seq_of)" "指令順序：設定→reconfigure→chown→停服務→restore→reconfigure→start→五項驗證"
assert_eq "yes" "$([ -f "$SB/data/${ID}_gitlab_backup.tar" ] && echo yes || echo no)" "② 資料備份已放入備份目錄"
assert_contains "$(cat "$STUB_LOG")" "BACKUP=$ID " "BACKUP= 只有 ID"
assert_not_contains "$(cat "$STUB_LOG")" "BACKUP=$SB" "BACKUP= 不含路徑"
assert_not_contains "$(cat "$STUB_LOG")" "_gitlab_backup.tar force" "BACKUP= 不含 _gitlab_backup.tar 後綴"
assert_contains "$out" "五項驗證全部通過" "成功彙總"
assert_eq "yes" "$(ls "$SB"/gitlab.rb.bak-* >/dev/null 2>&1 && echo yes || echo no)" "還原設定前先備份現有 gitlab.rb"
assert_contains "$out" "會覆蓋" "確認提示寫清楚會覆蓋什麼"
assert_contains "$out" "資料庫" "確認提示提到資料庫"
assert_contains "$out" "gitlab-secrets.json" "確認提示提到金鑰"

# 還原前須 yes（PR-BAK-07）
for ans in "no" "y" "YES" ""; do
    setup_sandbox "rst_deny_$ans"
    mk_fixtures
    out="$(run_rst "$(rst_in "$ans")q\n")"
    assert_eq "" "$(seq_of)" "回答「$ans」：沒有任何 gitlab 指令被執行"
    assert_eq "no" "$(grep -q restored "$SB/root/etc/gitlab/gitlab.rb" 2>/dev/null && echo yes || echo no)" "回答「$ans」：設定未被還原"
done
setup_sandbox rst_eof
mk_fixtures
out="$(run_rst "$(rst_in '')")"
assert_eq "" "$(seq_of)" "stdin EOF 視為否：沒有任何 gitlab 指令"

# 版本不符即中止（PR-BAK-05）
setup_sandbox rst_ver
mk_fixtures
out="$(run_rst "$(rst_in yes)q\n" STUB_PKG_VERSION=18.8.0-ce.0)"
assert_eq "" "$(seq_of)" "版本不符：沒有任何 gitlab 指令"
assert_eq "no" "$(grep -q restored "$SB/root/etc/gitlab/gitlab.rb" 2>/dev/null && echo yes || echo no)" "版本不符：設定未被還原"
assert_contains "$out" "版本不一致" "版本不符：說明"
assert_contains "$out" "動作未完成" "版本不符：回報失敗"
setup_sandbox rst_nopkg
mk_fixtures
out="$(run_rst "$(rst_in yes)q\n" STUB_NOPKG=1)"
assert_eq "" "$(seq_of)" "讀不到已裝版本：沒有任何 gitlab 指令"

# 檔案與檔名檢查
setup_sandbox rst_badname
mk_fixtures
mv "$SB/in/${ID}_gitlab_backup.tar" "$SB/in/renamed.tar"
out="$(run_rst "7\n$SB/in/$CFGNAME\n$SB/in/renamed.tar\nyes\nq\n")"
assert_eq "" "$(seq_of)" "資料備份被改名：不還原"
assert_contains "$out" "請勿改檔名" "資料備份被改名：說明"
setup_sandbox rst_nofile
mk_fixtures
out="$(run_rst "7\n$SB/in/$CFGNAME\n$SB/in/9999_2026_01_01_18.7.6_gitlab_backup.tar\nyes\nq\n")"
assert_eq "" "$(seq_of)" "資料備份不存在：不還原"
setup_sandbox rst_evil_tar
mk_fixtures
mkdir -p "$SB/evil/etc/gitlab" "$SB/evil/etc/cron.d"
: >"$SB/evil/etc/cron.d/pwn"
tar -cf "$SB/in/$CFGNAME" -C "$SB/evil" etc/gitlab etc/cron.d
out="$(run_rst "$(rst_in yes)q\n")"
assert_eq "" "$(seq_of)" "設定備份含 etc/gitlab 以外的條目：不還原"
assert_eq "no" "$([ -e "$SB/root/etc/cron.d/pwn" ] && echo yes || echo no)" "惡意條目沒有被解開"
assert_contains "$out" "不安全" "設定備份不安全：說明"

# 已在備份目錄的資料備份：不重複複製
setup_sandbox rst_inplace
mk_fixtures
mv "$SB/in/${ID}_gitlab_backup.tar" "$SB/data/"
out="$(run_rst "7\n$SB/in/$CFGNAME\n$SB/data/${ID}_gitlab_backup.tar\nyes\nq\n")"
assert_contains "$out" "不需複製" "資料備份已在備份目錄：不複製"
assert_eq "1" "$(grep -c "^gitlab-backup restore" "$STUB_LOG")" "仍會執行還原"

# 失敗路徑
setup_sandbox rst_reconf1_fail
mk_fixtures
out="$(run_rst "$(rst_in yes)no\nq\n" STUB_RECONF_RC=1)"
assert_eq "0" "$(grep -c '^gitlab-backup restore' "$STUB_LOG")" "設定還原後 reconfigure 失敗：不進行資料還原"
assert_eq "0" "$(grep -c '^gitlab-ctl stop' "$STUB_LOG")" "設定還原後 reconfigure 失敗：不停服務"
setup_sandbox rst_chown_fail
mk_fixtures
out="$(run_rst "$(rst_in yes)q\n" STUB_CHOWN_RC=1)"
assert_eq "0" "$(grep -c '^gitlab-ctl stop' "$STUB_LOG")" "chown 失敗：不停服務"
assert_eq "0" "$(grep -c '^gitlab-backup restore' "$STUB_LOG")" "chown 失敗：不還原"
setup_sandbox rst_restore_fail
mk_fixtures
out="$(run_rst "$(rst_in yes)q\n" STUB_RESTORE_RC=1)"
assert_contains "$out" "gitlab-backup restore 失敗" "restore 失敗：說明"
assert_contains "$out" "gitlab-ctl start" "restore 失敗：告知如何恢復服務"
assert_contains "$out" "動作未完成" "restore 失敗：回報失敗"
assert_eq "0" "$(grep -c '^gitlab-rake' "$STUB_LOG")" "restore 失敗：不跑驗證"
assert_eq "0" "$(grep -c '^gitlab-ctl start' "$STUB_LOG")" "restore 失敗：不自動啟動服務"
setup_sandbox rst_nonroot
mk_fixtures
out="$(run_rst "$(rst_in yes)q\n" OPS_FAKE_UID=1000)"
assert_eq "" "$(seq_of)" "非 root：沒有任何 gitlab 指令"

# ── 還原後驗證（PR-BAK-08）──
setup_sandbox ver_ok
out="$(run_bk '8\nq\n')"
assert_eq "5" "$(grep -c '^gitlab-rake' "$STUB_LOG")" "五項驗證都執行"
assert_eq "gitlab-rake gitlab:check SANITIZE=true|gitlab-rake gitlab:doctor:secrets|gitlab-rake gitlab:artifacts:check|gitlab-rake gitlab:lfs:check|gitlab-rake gitlab:uploads:check|" "$(grep '^gitlab-rake' "$STUB_LOG" | tr '\n' '|')" "驗證順序"
assert_contains "$out" "五項驗證全部通過" "全部通過：彙總"
assert_not_contains "$out" "動作未完成" "全部通過：不報失敗"
setup_sandbox ver_some_fail
out="$(run_bk '8\nq\n' STUB_RAKE_FAIL="gitlab:doctor:secrets gitlab:lfs:check")"
assert_eq "5" "$(grep -c '^gitlab-rake' "$STUB_LOG")" "有失敗仍跑完五項"
assert_contains "$out" "✓ gitlab:check" "彙總：成功項"
assert_contains "$out" "✗ gitlab:doctor:secrets" "彙總：失敗項（secrets）"
assert_contains "$out" "✗ gitlab:lfs:check" "彙總：失敗項（lfs）"
assert_contains "$out" "2 項驗證失敗" "彙總：失敗個數"
assert_contains "$out" "動作未完成" "有失敗：整體回報失敗"
assert_not_contains "$out" "全部通過" "有失敗：不宣稱通過"
setup_sandbox rst_verify_fail
mk_fixtures
out="$(run_rst "$(rst_in yes)q\n" STUB_RAKE_FAIL="gitlab:uploads:check")"
assert_contains "$out" "✗ gitlab:uploads:check" "還原流程內的驗證失敗也彙總"
assert_contains "$out" "動作未完成" "還原流程驗證失敗：回報失敗"

# ── 選單、說明、排查 ──
setup_sandbox menu7
menu="$(run_bk 'q\n')"
assert_contains "$menu" "還原" "選單含還原"
bad=0
while IFS= read -r line; do
    [[ $line =~ ^\ +[0-9]+\) ]] || continue
    [[ $line == *"說明"* || $line == *"常見問題排查"* ]] && continue
    [[ $line == *"【有網路的電腦】"* || $line == *"【GitLab 伺服器】"* ]] || { bad=1; echo "未標示：$line" >&2; }
done <<<"$menu"
assert_eq "0" "$bad" "還原項目也標示機器"
help="$(run_bk '9\nq\n')"
for k in "版本與類型" "reconfigure" "不應有既有的正式資料" "chown git:git" "備份 ID" "gitlab:doctor:secrets" "gitlab:artifacts:check" "gitlab:lfs:check" "gitlab:uploads:check" "clone" "CI/CD" "Runner" "yes"; do
    assert_contains "$help" "$k" "說明含：$k"
done
fix="$(run_bk '10\nq\n')"
for k in "版本不一致" "備份 ID 格式不符" "BACKUP=" "gitlab-ctl start" "etc/gitlab"; do assert_contains "$fix" "$k" "排查含：$k"; done
