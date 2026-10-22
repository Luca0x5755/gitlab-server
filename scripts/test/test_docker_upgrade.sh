#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034
# docker.sh 逐站升級（ISSUE-007）：接縫 A 純函式、接縫 B 階段函式（假 docker）、接縫 C 選單。
# 期望值一律寫死字面值。
# 未驗證：真實 docker 升級（含 18.11 的 PostgreSQL 自動升級）無法無人值守，這裡只用假指令，
# 沒有任何真實環境驗證。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
dkr="$here/../docker.sh"
. "$dkr"

# ══ 接縫 A：純函式 ════════════════════════════════════════════════════════════

# ── docker_upgrade_plan：只升比目前高的，數值比較 ──
loaded="18.10.3-ce.0
19.5.1-ce.0
18.11.13-ce.0
19.2.9-ce.0"
assert_eq "18.11.13-ce.0
19.2.9-ce.0
19.5.1-ce.0" "$(docker_upgrade_plan 18.10.3-ce.0 "$loaded" 2>/dev/null)" "略過不高於目前的版本，其餘由小到大"
assert_eq "19.5.1-ce.0" "$(docker_upgrade_plan 19.2.9-ce.0 "$loaded" 2>/dev/null)" "目前在中間站：只剩更高者"
assert_eq "" "$(docker_upgrade_plan 19.5.1-ce.0 "$loaded" 2>/dev/null)" "已在最高：沒有要升的"
assert_eq "18.10.3-ce.0" "$(docker_upgrade_plan 18.9.0-ce.0 "18.10.3-ce.0
18.9.0-ce.0" 2>/dev/null)" "18.10 比 18.9 高（不是字串排序）"
err="$(docker_upgrade_plan 18.11.13-ce.0 "$loaded" 2>&1 >/dev/null)"
assert_contains "$err" "18.10.3-ce.0" "略過者在 stderr 說明"
assert_not_contains "$err" "19.5.1-ce.0" "未略過者不出現在略過說明"
assert_status 1 "目前版本非法" docker_upgrade_plan abc "$loaded"
assert_status 1 "清單含非法項" docker_upgrade_plan 18.10.3-ce.0 "19.2.9-ce.0
bogus"
assert_eq "" "$(docker_upgrade_plan 18.10.3-ce.0 "19.2.9-ce.0
bogus" 2>/dev/null)" "清單非法：不輸出任何 tag"

# ── tag 與映像參照往返 ──
assert_eq "gitlab/gitlab-ce:18.11.13-ce.0" "$(docker_image_ref 18.11.13-ce.0)" "tag 組成映像參照"
assert_eq "18.11.13-ce.0" "$(docker_tag_from_image gitlab/gitlab-ce:18.11.13-ce.0)" "由映像參照取出 tag"
assert_status 1 "非 gitlab-ce 映像不取 tag" docker_tag_from_image redis:7

# ── 18.11 站的觸發條件 ──
assert_status 0 "18.11.13 是 PostgreSQL 升級站" docker_station_needs_pg_warning 18.11.13-ce.0
assert_status 1 "18.10.3 不是" docker_station_needs_pg_warning 18.10.3-ce.0
assert_status 1 "19.2.9 不是" docker_station_needs_pg_warning 19.2.9-ce.0
assert_status 1 "18.1.0 不是（不可用前綴比對）" docker_station_needs_pg_warning 18.1.0-ce.0

# ── 剩餘空間 ──
df_out='Filesystem     1024-blocks      Used Available Capacity Mounted on
/dev/sda1         103080888  51540444  51540444      50% /'
assert_eq "49.2 GiB" "$(docker_free_space_line "$df_out")" "由 df -Pk 輸出取剩餘空間"
assert_status 1 "df 輸出讀不到" docker_free_space_line ""

# ── parse_queued_count（共用於 common.sh）──
assert_eq "7" "$(printf 'warn: x\n7\n' | parse_queued_count)" "取最後一個純數字行"
assert_eq "0" "$(printf '5\nwarn\n0\n' | parse_queued_count)" "最後一個數字行為準"
assert_status 1 "沒有數字行" bash -c ". '$here/../lib/common.sh'; echo nothing | parse_queued_count"

# ══ 接縫 B：階段函式（PATH 放假 docker；不跑真實升級）═══════════════════════════

# 假指令行為由環境變數注入：
#   CUR_TAG=<tag> 初始容器版本（docker run 後會改成新 tag）；LOADED="<tag…>" docker images 的輸出；
#   HEALTH_OUT 容器 State／Health（預設 "running healthy"）；QUEUED_OUT 背景遷移查詢的輸出（預設 0）；
#   RAKE_RC gitlab:check 結束碼；RUN_RC docker run 結束碼。
# 備份用覆寫 docker_run_backup（BACKUP_RC 控制結束碼），並記進 STUB_LOG。
setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/mnt/etc" "$SB/mnt/var" "$SB/mnt/log"
    echo cfg >"$SB/mnt/etc/gitlab.rb"
    echo x >"$SB/mnt/var/data"
    export HOME="$SB" STUB_LOG="$SB/stub.log" OPS_ENV_FILE="$SB/ops.env" OPS_FAKE_UID=0
    export GLC_MOUNT_DIRS="$SB/mnt/etc $SB/mnt/var $SB/mnt/log" GLC_DATA_DIR="$SB/mnt/var"
    export GLC_HEALTH_INTERVAL=0 GLC_HEALTH_MAX=2 UPG_POLL_INTERVAL=0 UPG_POLL_MAX=2
    : >"$STUB_LOG"
    unset HEALTH_OUT QUEUED_OUT RAKE_RC RUN_RC BACKUP_RC
    export CUR_TAG="18.10.3-ce.0" LOADED=""
    echo "$CUR_TAG" >"$SB/cur"
    export SB_CUR="$SB/cur"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 103080888 51540444 51540444 50%% /\n"'
    make_stub "$SB/bin" docker '
case "$1" in
    inspect)
        case "$*" in
            *Config.Image*) echo "gitlab/gitlab-ce:$(cat "$SB_CUR")" ;;
            *) echo "${HEALTH_OUT:-running healthy}" ;;
        esac; exit 0 ;;
    images) printf "%s\n" $LOADED; exit 0 ;;
    run) [ "${RUN_RC:-0}" = 0 ] && eval "echo \"\${$#}\"" | sed "s#gitlab/gitlab-ce:##" >"$SB_CUR"; exit "${RUN_RC:-0}" ;;
    exec)
        case "$*" in
            *runner*) printf "%b\n" "${QUEUED_OUT:-0}" ;;
            *) exit "${RAKE_RC:-0}" ;;
        esac; exit 0 ;;
    *) exit 0 ;;
esac'
    export SB PATH="$SB/bin:$PATH"
    docker_run_backup() { echo "BACKUP" >>"$STUB_LOG"; return "${BACKUP_RC:-0}"; }
}
log() { cat "$STUB_LOG"; }
nth() { grep -n -- "$1" "$STUB_LOG" | head -n1 | cut -d: -f1; } # 第一次出現的行號

# ── docker_upgrade_wait_migrations ──
setup_sandbox wm_zero
( docker_upgrade_wait_migrations ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "佇列為 0：成功"
assert_contains "$(log)" "docker exec gitlab gitlab-rails runner" "在容器內以 gitlab-rails runner 查詢"
assert_contains "$(log)" "BatchedMigration.queued.count" "查的是 BatchedMigration.queued.count"
setup_sandbox wm_warn
( export QUEUED_OUT='warning: foo\n0'; docker_upgrade_wait_migrations ) >/dev/null 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "輸出前面混有警告行：仍取最後的純數字"
setup_sandbox wm_stuck
( export QUEUED_OUT=3; docker_upgrade_wait_migrations ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "佇列一直不為 0：逾時失敗"
assert_contains "$(cat "$SB/o.txt")" "sidekiq" "逾時指向 sidekiq 日誌"
setup_sandbox wm_unread
( export QUEUED_OUT='no digits'; docker_upgrade_wait_migrations ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "讀不到數字：逾時失敗，不當作 0"

# ── docker_upgrade_station ──
setup_sandbox st_ok
( docker_upgrade_station 18.11.13-ce.0 ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "一站成功"
L="$(log)"
assert_contains "$L" "docker stop" "停止舊容器"
assert_contains "$L" "docker rm gitlab" "移除舊容器"
assert_contains "$L" "docker run -d --name gitlab --restart always --shm-size 256m -p 80:80 -p 443:443 -p 2222:22 -v $SB/mnt/etc:$SB/mnt/etc -v $SB/mnt/var:$SB/mnt/var -v $SB/mnt/log:$SB/mnt/log gitlab/gitlab-ce:18.11.13-ce.0" "以新 tag 與同一組參數重建"
b="$(nth BACKUP)"; s="$(nth 'docker stop')"; m="$(nth 'docker rm')"; u="$(nth 'docker run')"; q="$(nth 'gitlab-rails runner')"
assert_eq "1" "$([ "$b" -lt "$s" ] && [ "$s" -lt "$m" ] && [ "$m" -lt "$u" ] && [ "$u" -lt "$q" ] && echo 1)" "順序：備份 → stop → rm → run → 等背景遷移"
assert_eq "cfg" "$(cat "$SB/mnt/etc/gitlab.rb")" "掛載目錄內容未被動到"
assert_not_contains "$L" "rm -rf" "不刪任何目錄"
assert_not_contains "$L" "volume" "不動 volume"

setup_sandbox st_backup_fail
( export BACKUP_RC=1; docker_upgrade_station 18.11.13-ce.0 ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "備份失敗：中止"
assert_not_contains "$(log)" "docker stop" "備份失敗：不停舊容器"
assert_not_contains "$(log)" "docker rm" "備份失敗：不移除舊容器"
assert_contains "$(cat "$SB/o.txt")" "備份" "訊息說明是備份失敗"

setup_sandbox st_run_fail
( export RUN_RC=1; docker_upgrade_station 18.11.13-ce.0 ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "docker run 失敗：中止"
assert_not_contains "$(log)" "gitlab-rails runner" "docker run 失敗：不進入等背景遷移"

setup_sandbox st_unhealthy
( export HEALTH_OUT="running unhealthy"; docker_upgrade_station 18.11.13-ce.0 ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "容器不健康：停止"
assert_contains "$(cat "$SB/o.txt")" "docker logs gitlab" "指向 docker logs gitlab"
assert_not_contains "$(log)" "gitlab-rails runner" "不健康：不等背景遷移"

setup_sandbox st_stuck
( export QUEUED_OUT=2; docker_upgrade_station 18.11.13-ce.0 ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "背景遷移逾時：停止"
assert_contains "$(cat "$SB/o.txt")" "sidekiq" "指向 sidekiq 日誌"

# ── docker_upgrade（入口）──
ALL="18.10.3-ce.0 18.11.13-ce.0 19.2.9-ce.0 19.5.1-ce.0"
run_up() { # run_up <stdin 文字>（輸出寫入 $SB/o.txt）
    printf '%b' "$1" | ( docker_upgrade ) >"$SB/o.txt" 2>&1
}

setup_sandbox up_ok
export LOADED="$ALL"
run_up "yes\nyes\n" && r=0 || r=$?
O="$(cat "$SB/o.txt")"
assert_eq "0" "$r" "全程成功：0"
L="$(log)"
assert_eq "3" "$(grep -c '^docker run' "$STUB_LOG")" "從 18.10.3 起共升三站"
assert_eq "3" "$(grep -c '^BACKUP' "$STUB_LOG")" "每一站升級前都備份"
assert_contains "$L" "gitlab/gitlab-ce:18.11.13-ce.0" "升到 18.11.13"
assert_contains "$L" "gitlab/gitlab-ce:19.2.9-ce.0" "升到 19.2.9"
assert_contains "$L" "gitlab/gitlab-ce:19.5.1-ce.0" "升到 19.5.1"
assert_not_contains "$L" "gitlab/gitlab-ce:18.10.3-ce.0" "不重裝目前版本"
a="$(nth 'gitlab-ce:18.11.13')"; b2="$(nth 'gitlab-ce:19.2.9')"; c="$(nth 'gitlab-ce:19.5.1')"
assert_eq "1" "$([ "$a" -lt "$b2" ] && [ "$b2" -lt "$c" ] && echo 1)" "站的順序由小到大"
assert_contains "$L" "docker exec gitlab gitlab-rake gitlab:check SANITIZE=true" "全部完成後跑 gitlab:check SANITIZE=true"
last="$(grep -n 'gitlab:check' "$STUB_LOG" | tail -n1 | cut -d: -f1)"
assert_eq "1" "$([ "$last" -gt "$c" ] && echo 1)" "gitlab:check 在最後一站之後"
assert_contains "$O" "19.5.1-ce.0" "顯示最終版本"
assert_contains "$O" "PostgreSQL" "進 18.11 前提示 PostgreSQL 自動升級"
assert_contains "$O" "49.2 GiB" "顯示 /var/opt/gitlab 所在磁碟剩餘空間"

# 開跑前確認
setup_sandbox up_cancel
export LOADED="$ALL"
for inp in "" "no\n" ; do
    run_up "$inp" && r=0 || r=$?
    assert_eq "0" "$r" "開跑前未輸入 yes（[$inp]）：取消、結束 0"
    assert_not_contains "$(log)" "BACKUP" "未輸入 yes：不備份"
    assert_not_contains "$(log)" "docker stop" "未輸入 yes：不動容器"
done
assert_contains "$(cat "$SB/o.txt")" "18.11.13-ce.0" "開跑前印出版本順序"

# 進 18.11 前拒絕：第一站備份與重建都不發生
setup_sandbox up_pg_no
export LOADED="$ALL"
run_up "yes\nno\n" && r=0 || r=$?
assert_eq "0" "$r" "PostgreSQL 警告回答非 yes：取消"
assert_not_contains "$(log)" "docker stop" "PostgreSQL 警告被拒：不動容器"
assert_not_contains "$(log)" "BACKUP" "PostgreSQL 警告被拒：不備份"

# 不高於目前版本者略過並說明；已在 18.11 以上不再提示 PostgreSQL
setup_sandbox up_skip
export LOADED="$ALL" CUR_TAG=19.2.9-ce.0
echo 19.2.9-ce.0 >"$SB_CUR"
run_up "yes\n" && r=0 || r=$?
O="$(cat "$SB/o.txt")"
assert_eq "0" "$r" "目前 19.2.9：只升 19.5.1"
assert_eq "1" "$(grep -c '^docker run' "$STUB_LOG")" "只升一站"
assert_contains "$O" "略過 18.11.13-ce.0" "已載入但不高於目前版本者略過並說明"
assert_not_contains "$O" "PostgreSQL" "不經過 18.11 站：不提示"

setup_sandbox up_none
export LOADED="$ALL"
echo 19.5.1-ce.0 >"$SB_CUR"
run_up "yes\n" && r=0 || r=$?
assert_eq "0" "$r" "已是最新：結束 0"
assert_contains "$(cat "$SB/o.txt")" "沒有" "說明沒有可升的映像"
assert_not_contains "$(log)" "docker stop" "已是最新：不動容器"
assert_contains "$(log)" "gitlab:check SANITIZE=true" "已是最新：仍補跑最終檢查（接續上次中斷的最後一站）"

# 最後一站中斷後重跑：沒有更高的映像，但目前容器的背景遷移未歸零，不可宣稱完成
setup_sandbox up_last_pending
export LOADED="$ALL" QUEUED_OUT=4
echo 19.5.1-ce.0 >"$SB_CUR"
run_up "" && r=0 || r=$?
assert_eq "1" "$r" "最後一站背景遷移未歸零：重跑時失敗"
assert_not_contains "$(log)" "gitlab:check" "背景遷移未歸零：不跑最終檢查"
assert_not_contains "$(cat "$SB/o.txt")" "升級完成" "背景遷移未歸零：不宣稱完成"

# 站失敗即停，後續站不執行，也不跑 gitlab:check
setup_sandbox up_fail
export LOADED="$ALL" RUN_RC=1
run_up "yes\nyes\n" && r=0 || r=$?
assert_eq "1" "$r" "第一站 docker run 失敗：整體失敗"
assert_eq "1" "$(grep -c '^docker run' "$STUB_LOG")" "失敗後不再升下一站"
assert_not_contains "$(log)" "gitlab:check" "失敗後不跑 gitlab:check"

# 中斷後重跑：目前容器（上次升到的站）的背景遷移還沒歸零，不可直接進下一站
setup_sandbox up_resume_pending
export LOADED="$ALL" QUEUED_OUT=4
echo 18.11.13-ce.0 >"$SB_CUR"
run_up "yes\nyes\n" && r=0 || r=$?
assert_eq "1" "$r" "目前容器背景遷移未歸零：失敗"
assert_not_contains "$(log)" "BACKUP" "背景遷移未歸零：不備份"
assert_not_contains "$(log)" "docker stop" "背景遷移未歸零：不動容器"
assert_contains "$(cat "$SB/o.txt")" "sidekiq" "指向 sidekiq 日誌"

setup_sandbox up_check_fail
export LOADED="$ALL" RAKE_RC=1
run_up "yes\nyes\n" && r=0 || r=$?
assert_eq "1" "$r" "gitlab:check 失敗：非 0"
assert_not_contains "$(cat "$SB/o.txt")" "升級完成" "gitlab:check 失敗不宣稱完成"

# ══ 接縫 C：選單 ══════════════════════════════════════════════════════════════
menu="$(show_menu)"
assert_contains "$(grep '逐站升級' <<<"$menu")" "【GitLab 伺服器】" "選單有「逐站升級」且標示【GitLab 伺服器】"
out="$(bash -c ". '$dkr'; docker_upgrade() { echo UPGRADE-CALLED; }; dispatch 7")"
assert_eq "UPGRADE-CALLED" "$out" "選項 7 派發到 docker_upgrade"
