#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# upgrade.sh 的純函式（接縫 B）與行程層級行為（接縫 C）。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
upg="$here/../upgrade.sh"

. "$upg"

# ══ 純函式 ════════════════════════════════════════════════════════════════════

deb() { echo "/d/gitlab-ce_$1_amd64.deb"; }

# ── select_upgrade_debs（PR-UPG-02、PR-COM-10）──
# 檔案刻意用字串排序會出錯的順序：18.10.0 字典序在 18.7.6 之前
sel="$(printf '%s\n' "$(deb 18.10.0-ce.0)" "$(deb 18.7.6-ce.0)" "$(deb 17.11.2-ce.0)" "$(deb 18.9.0-ce.0)" | select_upgrade_debs 17.0.0-ce.0 amd64 2>/dev/null)"
assert_eq "$(deb 17.11.2-ce.0)"$'\n'"$(deb 18.7.6-ce.0)"$'\n'"$(deb 18.9.0-ce.0)"$'\n'"$(deb 18.10.0-ce.0)" "$sel" "依版本數值由小到大（18.7 < 18.9 < 18.10）"
sel="$(printf '%s\n' "$(deb 18.10.0-ce.0)" "$(deb 18.7.6-ce.0)" "$(deb 17.11.2-ce.0)" | select_upgrade_debs 18.7.6-ce.0 amd64 2>/dev/null)"
assert_eq "$(deb 18.10.0-ce.0)" "$sel" "已裝版本（含）以下略過：只剩 18.10.0"
err="$(printf '%s\n' "$(deb 18.7.6-ce.0)" "$(deb 17.11.2-ce.0)" "$(deb 18.10.0-ce.0)" | select_upgrade_debs 18.7.6-ce.0 amd64 2>&1 >/dev/null)"
assert_contains "$err" "略過 gitlab-ce_18.7.6-ce.0_amd64.deb" "略過等於已裝版本的檔案並說明"
assert_contains "$err" "略過 gitlab-ce_17.11.2-ce.0_amd64.deb" "略過低於已裝版本的檔案並說明"
assert_eq "" "$(printf '%s\n' "$(deb 18.7.6-ce.0)" | select_upgrade_debs 18.7.6-ce.0 amd64 2>/dev/null)" "全部略過：無輸出"
assert_status 0 "全部略過：仍回 0" bash -c ". '$upg'; printf '/d/gitlab-ce_18.7.6-ce.0_amd64.deb\n' | select_upgrade_debs 18.7.6-ce.0 amd64"
assert_eq "" "$(printf '' | select_upgrade_debs 18.7.6-ce.0 amd64 2>/dev/null)" "空輸入：無輸出"
assert_eq "$(deb 18.7.7-ce.0)" "$(printf '%s\n' "$(deb 18.7.7-ce.0)" | select_upgrade_debs 18.7.6-ce.0 amd64 2>/dev/null)" "修訂號 +1 要裝"
assert_eq "$(deb 18.7.6-ce.1)" "$(printf '%s\n' "$(deb 18.7.6-ce.1)" | select_upgrade_debs 18.7.6-ce.0 amd64 2>/dev/null)" "同版本 -ce.1 比 -ce.0 新，要裝"
assert_eq "$(deb 18.7.6-ce.0)"$'\n'"$(deb 18.7.6-ce.1)" "$(printf '%s\n' "$(deb 18.7.6-ce.1)" "$(deb 18.7.6-ce.0)" | select_upgrade_debs 18.7.5-ce.0 amd64 2>/dev/null)" "-ce.0 排在 -ce.1 前"
# 非 .deb 檔案忽略
assert_eq "$(deb 18.8.0-ce.0)" "$(printf '%s\n' /d/README.txt "$(deb 18.8.0-ce.0)" /d/notes.md | select_upgrade_debs 18.7.6-ce.0 amd64 2>/dev/null)" "非 .deb 的檔案直接忽略"
# 錯誤：不輸出任何路徑
out="$(printf '%s\n' "$(deb 18.8.0-ce.0)" /d/gitlab-ee_18.9.0-ee.0_amd64.deb | select_upgrade_debs 18.7.6-ce.0 amd64 2>"$T_TMP/err")" && r=0 || r=$?
assert_eq "1" "$r" "不認得的 .deb 檔名：回 1"
assert_eq "" "$out" "不認得的 .deb 檔名：不輸出任何路徑"
assert_contains "$(cat "$T_TMP/err")" "gitlab-ee_18.9.0-ee.0_amd64.deb" "不認得的 .deb 檔名：點名"
out="$(printf '%s\n' "$(deb 18.8.0-ce.0)" /d/gitlab-ce_18.9.0-ce.0_arm64.deb | select_upgrade_debs 18.7.6-ce.0 amd64 2>"$T_TMP/err")" && r=0 || r=$?
assert_eq "1" "$r" "架構不符：回 1"
assert_eq "" "$out" "架構不符：不輸出"
assert_contains "$(cat "$T_TMP/err")" "架構不符" "架構不符：說明"
out="$(printf '%s\n' "$(deb 18.8.0-ce.0)" /e/gitlab-ce_18.8.0-ce.0_amd64.deb | select_upgrade_debs 18.7.6-ce.0 amd64 2>"$T_TMP/err")" && r=0 || r=$?
assert_eq "1" "$r" "同一版本兩份：回 1"
assert_eq "" "$out" "同一版本兩份：不輸出"
assert_nonzero "已裝版本格式不符" bash -c ". '$upg'; echo x | select_upgrade_debs garbage amd64"
assert_nonzero "檔名含注入字元" bash -c ". '$upg'; printf '/d/gitlab-ce_18.8.0-ce.0;id_amd64.deb\n' | select_upgrade_debs 18.7.6-ce.0 amd64"

# ── parse_queued_count ──
assert_eq "0" "$(printf '0\n' | parse_queued_count)" "佇列 0"
assert_eq "12" "$(printf '12\n' | parse_queued_count)" "佇列 12"
assert_eq "0" "$(printf 'warning: something\n0\n' | parse_queued_count)" "前面有警告行：取最後的數字"
assert_eq "3" "$(printf '0\nnoise\n3\r\n' | parse_queued_count)" "取最後一個數字行（容忍 CR）"
assert_nonzero "沒有數字行" bash -c ". '$upg'; printf 'error: boom\n' | parse_queued_count"
assert_nonzero "空輸出" bash -c ". '$upg'; printf '' | parse_queued_count"
assert_nonzero "含數字的雜訊不算" bash -c ". '$upg'; printf 'queued: 0\n' | parse_queued_count"

# ══ 行程層級 ══════════════════════════════════════════════════════════════════

setup_sandbox() { # setup_sandbox <名稱> [已裝版本]
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/opt" "$SB/data" "$SB/cfg" "$SB/home" "$SB/tmp" "$SB/debs"
    STUB_LOG="$SB/stub.log"
    : >"$STUB_LOG"
    export STUB_LOG
    echo "${2:-18.7.6-ce.0}" >"$SB/pkgver"
    : >"$SB/queue"
    rm -f "$OPS_ENV_FILE"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" sleep 'exit 0'
    # dpkg -i 會把已裝版本更新成檔名中的版本（模擬真的升級，供「中斷後重跑」測試）
    make_stub "$SB/bin" dpkg 'case "$1" in
  --print-architecture) echo amd64 ;;
  -i) [ "${STUB_DPKG_RC:-0}" -eq 0 ] || exit "$STUB_DPKG_RC"
      f="${3:-$2}"; v="${f##*/gitlab-ce_}"; v="${v%_*}"; echo "$v" >"'"$SB"'/pkgver" ;;
esac'
    make_stub "$SB/bin" dpkg-query 'cat "'"$SB"'/pkgver"'
    make_stub "$SB/bin" gitlab-ctl 'case "$1" in
  reconfigure) exit "${STUB_RECONF_RC:-0}" ;;
  stop) [ -z "${STUB_STOP_FAIL:-}" ] || exit 1 ;;
  restart) exit "${STUB_RESTART_RC:-0}" ;;
esac'
    make_stub "$SB/bin" gitlab-backup 'exit "${STUB_BACKUP_RC:-0}"'
    make_stub "$SB/bin" gitlab-rails 'f="'"$SB"'/queue"
if [ -s "$f" ]; then n="$(head -n1 "$f")"; tail -n +2 "$f" >"$f.tmp"; mv "$f.tmp" "$f"; else n="${STUB_QUEUE_DEFAULT:-0}"; fi
echo "$n"'
    make_stub "$SB/bin" gitlab-rake 'case "$1" in gitlab:check) exit "${STUB_CHECK_RC:-0}" ;; esac; exit 0'
}
run_upg() { # run_upg <stdin> [KEY=VAL…]
    local input="$1"
    shift
    printf '%b' "$input" | env PATH="$SB/bin:$PATH" GITLAB_OPT_DIR="$SB/opt" GITLAB_BACKUP_DIR="$SB/data" \
        GITLAB_CONFIG_BACKUP_DIR="$SB/cfg" BACKUP_AUTO_LOG="$SB/backup.log" OPS_FAKE_UID=0 HOME="$SB/home" \
        TMPDIR="$SB/tmp" UPG_POLL_INTERVAL=0 UPG_POLL_MAX=5 "$@" bash "$upg" 2>&1
}
log_has() { grep -qF -- "$1" "$STUB_LOG"; }
count_log() { grep -cE -- "$1" "$STUB_LOG" || true; }
yn() { "$@" && echo yes || echo no; }
mkdebs() { local v; for v in "$@"; do : >"$SB/debs/gitlab-ce_${v}_amd64.deb"; done; }
seq_of() { grep -E '^(gitlab-ctl|gitlab-backup|gitlab-rake|gitlab-rails|dpkg -i)' "$STUB_LOG" | sed -E 's#^(dpkg -i) -- .*/gitlab-ce_([^_]+)_.*#\1 \2#' | tr '\n' '|'; }

# ── 選單骨架 ──
setup_sandbox menu
assert_status 2 "帶參數即拒絕" env PATH="$SB/bin:$PATH" bash "$upg" foo
assert_status 2 "空字串參數也拒絕" env PATH="$SB/bin:$PATH" bash "$upg" ""
assert_status 0 "q 離開結束碼 0" bash -c "printf 'q\n' | env PATH='$SB/bin:$PATH' bash '$upg'"
assert_status 0 "stdin EOF 離開結束碼 0" bash -c "env PATH='$SB/bin:$PATH' bash '$upg' </dev/null"
menu="$(run_upg 'q\n')"
assert_contains "$menu" "說明" "選單含「說明」"
assert_contains "$menu" "常見問題排查" "選單含「常見問題排查」"
bad=0
while IFS= read -r line; do
    [[ $line =~ ^\ +[0-9]+\) ]] || continue
    [[ $line == *"說明"* || $line == *"常見問題排查"* ]] && continue
    [[ $line == *"【有網路的電腦】"* || $line == *"【GitLab 伺服器】"* ]] || { bad=1; echo "未標示：$line" >&2; }
done <<<"$menu"
assert_eq "0" "$bad" "每個動作項目都標示機器"

# ── 1 顯示目前版本（PR-UPG-01）──
setup_sandbox ver
out="$(run_upg '1\nq\n')"
assert_eq "1" "$(count_log '^gitlab-rake gitlab:env:info')" "gitlab-rake gitlab:env:info"
setup_sandbox ver_nogl
rmdir "$SB/opt"
out="$(run_upg '1\nq\n')"
assert_eq "0" "$(count_log '^gitlab-rake')" "沒裝 GitLab：不執行"
assert_contains "$out" "【GitLab 伺服器】" "沒裝 GitLab：指向【GitLab 伺服器】"

# ── 2 預覽（PR-UPG-02、03）──
setup_sandbox prev
mkdebs 18.10.0-ce.0 18.7.6-ce.0 17.11.2-ce.0 18.9.0-ce.0 18.8.1-ce.0
out="$(run_upg "2\n$SB/debs\nq\n")"
n1="$(grep -n '1\. 18.8.1' <<<"$out" | head -1 | cut -d: -f1)"
n2="$(grep -n '2\. 18.9.0' <<<"$out" | head -1 | cut -d: -f1)"
n3="$(grep -n '3\. 18.10.0' <<<"$out" | head -1 | cut -d: -f1)"
assert_eq "yes" "$([ -n "$n1" ] && [ -n "$n2" ] && [ -n "$n3" ] && [ "$n1" -lt "$n2" ] && [ "$n2" -lt "$n3" ] && echo yes || echo no)" "預覽：依 18.8.1、18.9.0、18.10.0 排序列出"
assert_not_contains "$out" "共 4 版" "預覽：已裝版本 18.7.6 以下不計入"
assert_contains "$out" "共 3 版" "預覽：共 3 版"
assert_contains "$out" "略過 gitlab-ce_18.7.6-ce.0_amd64.deb" "預覽：說明略過的檔案"
assert_contains "$out" "僅預覽" "預覽：宣告未做變更"
assert_eq "0" "$(count_log '^(dpkg -i|gitlab-ctl|gitlab-backup)')" "預覽：不安裝、不備份、不動服務"
assert_contains "$(cat "$OPS_ENV_FILE")" "UPG_DEB_DIR=$SB/debs" "資料夾存入參數檔"
setup_sandbox prev_none
mkdebs 18.7.6-ce.0 17.0.0-ce.0
out="$(run_upg "2\n$SB/debs\nq\n")"
assert_contains "$out" "不需要升級" "沒有更新的版本：說明"
assert_not_contains "$out" "動作未完成" "沒有更新的版本：不算失敗"
setup_sandbox prev_badname
mkdebs 18.8.0-ce.0
: >"$SB/debs/gitlab-ee_18.9.0-ee.0_amd64.deb"
out="$(run_upg "2\n$SB/debs\nq\n")"
assert_contains "$out" "動作未完成" "有不認得的 .deb：失敗"
assert_contains "$out" "gitlab-ee_18.9.0-ee.0_amd64.deb" "有不認得的 .deb：點名"
setup_sandbox prev_nodir
out="$(run_upg "2\n$SB/nodir\nq\n")"
assert_contains "$out" "找不到資料夾" "資料夾不存在：說明"
setup_sandbox prev_relative
out="$(run_upg "2\nrel/dir\n")"
assert_eq "0" "$(count_log '^dpkg')" "相對路徑被驗證擋下"

# ── 3 逐版升級（PR-UPG-03～07）──
setup_sandbox run_ok
mkdebs 18.10.0-ce.0 18.9.0-ce.0 17.0.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n")"
want='gitlab-backup create CRON=1|gitlab-ctl backup-etc|gitlab-rails runner -e production puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count|'
step() { printf 'gitlab-ctl stop puma|gitlab-ctl stop sidekiq|dpkg -i %s|gitlab-ctl reconfigure|gitlab-ctl start|gitlab-ctl status|gitlab-rails runner -e production puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count|' "$1"; }
want+="$(step 18.9.0-ce.0)$(step 18.10.0-ce.0)gitlab-ctl restart|gitlab-rake gitlab:check SANITIZE=true|"
assert_eq "$want" "$(seq_of)" "完整順序：備份→先確認遷移→(停 puma/sidekiq→dpkg→reconfigure→start→status→等遷移)×2→restart→gitlab:check"
assert_contains "$out" "升級完成：18.7.6-ce.0 → 18.10.0-ce.0" "完成訊息"
assert_not_contains "$out" "動作未完成" "成功：不報失敗"
assert_eq "18.10.0-ce.0" "$(cat "$SB/pkgver")" "最後已裝版本是 18.10.0"
assert_contains "$out" "1. 18.9.0-ce.0" "開跑前印出順序（第 1 版）"
assert_contains "$out" "2. 18.10.0-ce.0" "開跑前印出順序（第 2 版）"
assert_contains "$out" "Upgrade Path" "開跑前提醒查升級路徑"

# 須 yes（PR-UPG-03）
for ans in no y YES ""; do
    setup_sandbox "run_deny_$ans"
    mkdebs 18.8.0-ce.0
    out="$(run_upg "3\n$SB/debs\n$ans\nq\n")"
    assert_eq "" "$(seq_of)" "回答「$ans」：沒有任何備份或安裝動作"
    assert_eq "0" "$(count_log '^dpkg -i')" "回答「$ans」：沒有 dpkg -i"
done
setup_sandbox run_eof
mkdebs 18.8.0-ce.0
out="$(run_upg "3\n$SB/debs\n")"
assert_eq "" "$(seq_of)" "stdin EOF 視為否"

# 備份失敗即中止（PR-UPG-04）
setup_sandbox run_backup_fail
mkdebs 18.8.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n" STUB_BACKUP_RC=1)"
assert_eq "0" "$(count_log '^dpkg -i')" "備份失敗：不安裝"
assert_eq "0" "$(count_log '^gitlab-ctl stop')" "備份失敗：不停服務"
assert_contains "$out" "備份失敗" "備份失敗：說明"
assert_contains "$out" "動作未完成" "備份失敗：回報失敗"
assert_eq "18.7.6-ce.0" "$(cat "$SB/pkgver")" "備份失敗：版本不變"

# 背景遷移（PR-UPG-06）：非 0 時等待，歸零才進下一版
setup_sandbox run_wait
mkdebs 18.8.0-ce.0 18.9.0-ce.0
printf '0\n5\n3\n0\n0\n' >"$SB/queue"   # 預檢 0；第一版後 5、3、0；第二版後 0
out="$(run_upg "3\n$SB/debs\nyes\nq\n")"
assert_contains "$out" "仍有 5 個" "輪詢：顯示佇列中的數量"
assert_contains "$out" "仍有 3 個" "輪詢：持續等待"
assert_eq "yes" "$([ "$(count_log '^gitlab-rails runner')" -eq 5 ] && echo yes || echo no)" "輪詢次數 = 預檢 1 + 第一版 3 + 第二版 1"
# 第二版的 dpkg 必須在第一版輪詢到 0 之後
l_third_poll="$(grep -n '^gitlab-rails runner' "$STUB_LOG" | sed -n 4p | cut -d: -f1)"
l_second_dpkg="$(grep -n '^dpkg -i' "$STUB_LOG" | sed -n 2p | cut -d: -f1)"
assert_eq "yes" "$([ "$l_third_poll" -lt "$l_second_dpkg" ] && echo yes || echo no)" "第一版的遷移歸零後，才安裝第二版"
assert_contains "$out" "升級完成" "最終完成"

# 逾時即停止並指向 sidekiq 日誌
setup_sandbox run_timeout
mkdebs 18.8.0-ce.0 18.9.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n" STUB_QUEUE_DEFAULT=7)"
assert_contains "$out" "等了 5 次仍未歸零" "預檢逾時：說明"
assert_contains "$out" "sidekiq" "逾時：指向 sidekiq 日誌"
assert_contains "$out" "/var/log/gitlab/sidekiq/current" "逾時：給出日誌路徑"
assert_eq "0" "$(count_log '^dpkg -i')" "預檢逾時：一版都不裝"
setup_sandbox run_timeout2
mkdebs 18.8.0-ce.0 18.9.0-ce.0
printf '0\n' >"$SB/queue"
out="$(run_upg "3\n$SB/debs\nyes\nq\n" STUB_QUEUE_DEFAULT=7)"
assert_eq "1" "$(count_log '^dpkg -i')" "第一版後逾時：只裝了第一版"
assert_eq "18.8.0-ce.0" "$(cat "$SB/pkgver")" "第一版後逾時：已裝版本是 18.8.0"
assert_not_contains "$out" "升級完成" "逾時：不宣稱完成"
assert_eq "0" "$(count_log '^gitlab-ctl restart')" "逾時：不進入收尾"
assert_contains "$out" "動作未完成" "逾時：回報失敗"
# 中斷後重跑：從已裝版本之後接續
out="$(run_upg "3\n$SB/debs\nyes\nq\n")"
assert_contains "$out" "共 1 版" "重跑：只剩第二版"
assert_contains "$out" "略過 gitlab-ce_18.8.0-ce.0_amd64.deb" "重跑：已裝的版本略過"
assert_eq "2" "$(count_log '^dpkg -i')" "重跑：共兩次 dpkg（第一版一次、第二版一次）"
assert_eq "18.9.0-ce.0" "$(cat "$SB/pkgver")" "重跑後已裝版本是 18.9.0"
assert_contains "$out" "升級完成：18.8.0-ce.0 → 18.9.0-ce.0" "重跑：完成"
# 無法讀取佇列也算未歸零
setup_sandbox run_unreadable
mkdebs 18.8.0-ce.0
make_stub "$SB/bin" gitlab-rails 'echo "error: could not connect"; exit 1'
out="$(run_upg "3\n$SB/debs\nyes\nq\n")"
assert_eq "0" "$(count_log '^dpkg -i')" "讀不到佇列：不安裝"
assert_contains "$out" "讀不到佇列數量" "讀不到佇列：說明"

# 失敗路徑
setup_sandbox run_dpkg_fail
mkdebs 18.8.0-ce.0 18.9.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n" STUB_DPKG_RC=1)"
assert_contains "$out" "dpkg -i 失敗" "dpkg 失敗：說明"
assert_contains "$out" "動作未完成" "dpkg 失敗：回報失敗"
assert_eq "0" "$(count_log '^gitlab-ctl reconfigure')" "dpkg 失敗：不 reconfigure"
assert_eq "0" "$(count_log '^gitlab-ctl restart')" "dpkg 失敗：不進入收尾"
assert_eq "18.7.6-ce.0" "$(cat "$SB/pkgver")" "dpkg 失敗：已裝版本不變（重跑會重試同一版）"
setup_sandbox run_reconf_fail
mkdebs 18.8.0-ce.0 18.9.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n" STUB_RECONF_RC=1)"
assert_contains "$out" "reconfigure 失敗" "reconfigure 失敗：說明"
assert_eq "1" "$(count_log '^dpkg -i')" "reconfigure 失敗：不裝下一版"
setup_sandbox run_stop_fail
mkdebs 18.8.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n" STUB_STOP_FAIL=1)"
assert_eq "0" "$(count_log '^dpkg -i')" "停服務失敗：不 dpkg"
setup_sandbox run_check_fail
mkdebs 18.8.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n" STUB_CHECK_RC=1)"
assert_contains "$out" "gitlab:check 回報問題" "gitlab:check 失敗：說明"
assert_contains "$out" "動作未完成" "gitlab:check 失敗：回報失敗"
assert_not_contains "$out" "升級完成" "gitlab:check 失敗：不宣稱完成"
assert_eq "1" "$(count_log '^gitlab-ctl restart')" "gitlab:check 失敗前已 restart"
setup_sandbox run_nonroot
mkdebs 18.8.0-ce.0
out="$(run_upg "3\n$SB/debs\nyes\nq\n" OPS_FAKE_UID=1000)"
assert_eq "" "$(seq_of)" "非 root：沒有任何動作"
setup_sandbox run_nogl
mkdebs 18.8.0-ce.0
rmdir "$SB/opt"
out="$(run_upg "3\n$SB/debs\nyes\nq\n")"
assert_eq "" "$(seq_of)" "沒裝 GitLab：沒有任何動作"
assert_contains "$out" "【GitLab 伺服器】" "沒裝 GitLab：指向【GitLab 伺服器】"
setup_sandbox run_none
mkdebs 18.7.6-ce.0
out="$(run_upg "3\n$SB/debs\nq\n")"
assert_eq "" "$(seq_of)" "沒有更新版本：不備份也不升級"
assert_contains "$out" "不需要升級" "沒有更新版本：說明"

# ── 說明與排查（PR-COM-11）──
setup_sandbox doc
help="$(run_upg '4\nq\n')"
for k in "不可跨大版本" "Upgrade Path Tool" "gitlab-ctl stop puma" "stop sidekiq" "dpkg -i" "reconfigure" "gitlab-ctl start" "背景遷移" "queued.count" "SANITIZE=true" "backup_auto.sh" "yes"; do
    assert_contains "$help" "$k" "說明含：$k"
done
fix="$(run_upg '5\nq\n')"
for k in "背景遷移一直不是 0" "sidekiq" "/var/log/gitlab/sidekiq/current" "dpkg -i 失敗" "備份失敗" "gitlab:check"; do
    assert_contains "$fix" "$k" "排查含：$k"
done
