#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# docker.sh 移除舊 deb 套件（ISSUE-006）：接縫 A 純函式、接縫 B 階段函式（假 docker／apt）、接縫 C 選單。
# 期望值一律寫死字面值，不用被測程式重算。
# 未驗證：真實 `apt purge gitlab-ce` 對掛載目錄的影響（spec Open question 2）需 WSL／VM 實測，這裡只用假指令。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
dkr="$here/../docker.sh"
. "$dkr"

# ══ 接縫 A：純函式 ════════════════════════════════════════════════════════════

# ── docker_verify_fresh：驗證剛通過 ──
assert_status 0 "戳記在時限內：剛通過" docker_verify_fresh 1000 1500 600
assert_status 0 "剛好等於時限仍算" docker_verify_fresh 1000 1600 600
assert_status 1 "戳記逾時" docker_verify_fresh 1000 1601 600
assert_status 1 "戳記在未來（時鐘錯亂）" docker_verify_fresh 2000 1500 600
assert_status 1 "戳記為空" docker_verify_fresh "" 1500 600
assert_status 1 "戳記非數字" docker_verify_fresh abc 1500 600

# ── docker_dirs_lost：掛載目錄內容仍在 ──
before='/etc/gitlab/gitlab.rb
/etc/gitlab/gitlab-secrets.json
/var/opt/gitlab/git-data'
assert_eq "" "$(docker_dirs_lost "$before" "$before")" "全都還在：輸出空"
assert_eq "" "$(docker_dirs_lost "$before" "$before
/var/opt/gitlab/new")" "多出來的項目不算消失"
assert_eq "/etc/gitlab/gitlab-secrets.json
/var/opt/gitlab/git-data" "$(docker_dirs_lost "$before" "/etc/gitlab/gitlab.rb")" "列出消失的項目"
assert_eq "" "$(docker_dirs_lost "" "")" "purge 前就是空：無從比較，輸出空"
assert_status 1 "purge 前是空時 docker_dirs_lost_check 拒絕（不能把空當作安全）" docker_dirs_lost_check "" ""
assert_status 0 "有項目且都在：通過" docker_dirs_lost_check "$before" "$before"
assert_status 1 "有項目消失：不通過" docker_dirs_lost_check "$before" "/etc/gitlab/gitlab.rb"

# ══ 接縫 B：階段函式（PATH 放假 docker／apt；真實 apt purge 不在此驗證）══════════════

# 假指令的行為由環境變數注入：
#   HEALTH_OUT=<輸出> 容器 State／Health（預設 "running healthy"）；RESTART_OUT=<輸出> 重啟政策與狀態（預設 "always running"）；
#   RAKE_RC=<碼> gitlab:check 結束碼；CURL_CODE=<碼>；APT_RC=<碼> apt 結束碼；APT_WIPE=1 apt 時把掛載目錄內容刪光（模擬 purge 動到資料）。
setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/mnt/etc" "$SB/mnt/var" "$SB/mnt/log" "$SB/opt"
    echo cfg >"$SB/mnt/etc/gitlab.rb"
    mkdir -p "$SB/mnt/var/git-data"
    echo x >"$SB/mnt/var/git-data/r1"
    echo log >"$SB/mnt/log/a.log"
    export HOME="$SB" STUB_LOG="$SB/stub.log" OPS_ENV_FILE="$SB/ops.env" GITLAB_RB="$SB/gitlab.rb"
    export GITLAB_OPT_DIR="$SB/opt" OPS_FAKE_UID=0
    export GLC_MOUNT_DIRS="$SB/mnt/etc $SB/mnt/var $SB/mnt/log"
    export GLC_HEALTH_INTERVAL=0 GLC_HEALTH_MAX=2
    : >"$STUB_LOG"
    unset HEALTH_OUT RESTART_OUT RAKE_RC CURL_CODE APT_RC APT_WIPE
    printf '%s\n' "external_url 'https://10.0.0.5'" >"$GITLAB_RB"
    make_stub "$SB/bin" apt '[ "${APT_WIPE:-}" = 1 ] && rm -rf "$SB_MNT"/*/*; echo "apt output line"; exit "${APT_RC:-0}"'
    make_stub "$SB/bin" gitlab-ctl 'exit 0'
    make_stub "$SB/bin" docker '
case "$1" in
    inspect)
        case "$*" in
            *RestartPolicy*) echo "${RESTART_OUT:-always running}" ;;
            *) echo "${HEALTH_OUT:-running healthy}" ;;
        esac; exit 0 ;;
    exec) exit "${RAKE_RC:-0}" ;;
    *) exit 0 ;;
esac'
    make_stub "$SB/bin" curl 'echo "${CURL_CODE:-302}"'
    export SB_MNT="$SB/mnt" PATH="$SB/bin:$PATH"
    docker_deb_version() { echo "18.10.3-ce.0"; }
    glc_now_epoch() { echo 10000; }
}

# 以假的「現在 = 10000」寫入驗證戳記。
stamp() { env_set GLC_VERIFIED_AT "$1"; }
run_purge() { # run_purge <stdin 文字>（輸出寫入 $SB/o.txt）
    printf '%b' "$1" | ( docker_purge_deb ) >"$SB/o.txt" 2>&1
}
PH="$GLC_PURGE_PHRASE"

# ── docker_verify：成功才寫戳記 ──
setup_sandbox vf_ok
( docker_verify ) >/dev/null 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "驗證通過"
assert_eq "10000" "$(env_get GLC_VERIFIED_AT)" "驗證通過時寫入戳記（現在的 epoch 秒）"
setup_sandbox vf_fail
( export RAKE_RC=1; docker_verify ) >/dev/null 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "gitlab:check 失敗"
assert_eq "" "$(env_get GLC_VERIFIED_AT)" "驗證失敗不寫戳記"
setup_sandbox vf_fail_curl
( export CURL_CODE=502; docker_verify ) >/dev/null 2>&1 && r=0 || r=$?
assert_eq "" "$(env_get GLC_VERIFIED_AT)" "curl 失敗不寫戳記"

# ── docker_dir_listing ──
setup_sandbox ls
exp="$SB/mnt/etc/gitlab.rb
$SB/mnt/log/a.log
$SB/mnt/var/git-data
$SB/mnt/var/git-data/r1"
assert_eq "$exp" "$(docker_dir_listing | sort)" "列出三個掛載目錄內（兩層）的項目"

# ── 閘門：docker_purge_deb 入口 ──
gate_case() { # gate_case <名稱> <說明片段>（呼叫前已佈置）
    run_purge "yes\n$PH\n" && r=0 || r=$?
    assert_eq "1" "$r" "$1：非 0"
    assert_contains "$(cat "$SB/o.txt")" "$2" "$1：說明原因"
    assert_not_contains "$(cat "$STUB_LOG")" "apt" "$1：apt 未被呼叫"
    assert_not_contains "$(cat "$SB/o.txt")" "不可逆" "$1：沒有進到確認流程"
}
setup_sandbox gate_nostamp
gate_case "沒有驗證戳記" "驗證"
setup_sandbox gate_old
stamp 1
gate_case "戳記逾時" "驗證"
setup_sandbox gate_unhealthy
stamp 9990
HEALTH_OUT="running unhealthy" gate_case "容器不健康" "healthy"
setup_sandbox gate_exited
stamp 9990
HEALTH_OUT="exited none" gate_case "容器已結束" "healthy"

# ── 確認流程 ──
confirm_case() { # confirm_case <名稱> <stdin>
    run_purge "$2" && r=0 || r=$?
    assert_eq "0" "$r" "$1：取消、不算失敗（結束碼 0，與遷移的取消一致）"
    assert_not_contains "$(cat "$STUB_LOG")" "apt" "$1：apt 未被呼叫"
}
setup_sandbox cf_eof
stamp 9990
confirm_case "stdin EOF" ""
assert_contains "$(cat "$SB/o.txt")" "不可逆" "說明這一步不可逆"
assert_contains "$(cat "$SB/o.txt")" "機外備份" "說明之後只剩機外備份"
setup_sandbox cf_noyes
stamp 9990
confirm_case "只給確認字串、沒輸入 yes" "no\n$PH\n"
setup_sandbox cf_badphrase
stamp 9990
confirm_case "yes 但字串錯" "yes\nwrong\n"
setup_sandbox cf_yes_eof
stamp 9990
confirm_case "yes 後 EOF" "yes\n"

# ── 執行 ──
setup_sandbox ok
stamp 9990
run_purge "yes\n$PH\n" && r=0 || r=$?
assert_eq "0" "$r" "全部通過：0"
assert_contains "$(cat "$SB/o.txt")" "遷移完成" "印出遷移完成"
assert_contains "$(cat "$STUB_LOG")" "apt purge -y gitlab-ce" "執行 apt purge gitlab-ce"
assert_not_contains "$(cat "$STUB_LOG")" "cleanse" "從不呼叫 gitlab-ctl cleanse"
assert_contains "$(cat "$STUB_LOG")" "docker exec gitlab gitlab-rake gitlab:check" "purge 後重跑驗證"
assert_contains "$(cat "$SB/o.txt")" "apt output line" "apt 實際輸出貼給使用者"
assert_eq "10000" "$(env_get GLC_VERIFIED_AT)" "重跑驗證通過後戳記為新的"

setup_sandbox apt_rc
stamp 9990
APT_RC=100 run_purge "yes\n$PH\n" && r=0 || r=$?
assert_eq "0" "$r" "apt 回非 0 但掛載目錄與驗證都好：仍算完成"
assert_contains "$(cat "$SB/o.txt")" "apt output line" "apt 非 0 時仍貼出輸出"

setup_sandbox lost
stamp 9990
APT_WIPE=1 run_purge "yes\n$PH\n" && r=0 || r=$?
assert_eq "1" "$r" "purge 後掛載目錄內容消失：報錯"
assert_contains "$(cat "$SB/o.txt")" "消失" "訊息說明有項目消失"
assert_not_contains "$(cat "$SB/o.txt")" "遷移完成" "不宣稱完成"
assert_not_contains "$(cat "$STUB_LOG")" "gitlab:check" "掛載目錄已壞：不重跑驗證"
assert_eq "" "$(env_get GLC_VERIFIED_AT)" "purge 後戳記被清掉，不能沿用 purge 前的"

setup_sandbox reverify_fail
stamp 9990
RAKE_RC=1 run_purge "yes\n$PH\n" && r=0 || r=$?
assert_eq "1" "$r" "purge 後重跑驗證失敗：報錯"
assert_not_contains "$(cat "$SB/o.txt")" "遷移完成" "驗證失敗不宣稱完成"
assert_contains "$(cat "$SB/o.txt")" "gitlab:check" "訊息帶出驗證失敗原因"

setup_sandbox restore
stamp 9990
RESTART_OUT="unless-stopped running" APT_WIPE=1 run_purge "yes\n$PH\n" && r=0 || r=$?
assert_contains "$(cat "$STUB_LOG")" "docker inspect -f {{.HostConfig.RestartPolicy.Name}} {{.State.Status}} gitlab" "purge 前記下重啟政策與狀態"
assert_contains "$(cat "$STUB_LOG")" "docker update --restart unless-stopped gitlab" "失敗時把重啟政策還原成原樣"

setup_sandbox nodeb
stamp 9990
( docker_deb_version() { return 1; }; printf 'yes\n%s\n' "$PH" | docker_purge_deb ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "deb 已不在：沒東西可移除，不算失敗"
assert_not_contains "$(cat "$STUB_LOG")" "apt" "deb 已不在：不呼叫 apt"

# ══ 接縫 C：選單 ══════════════════════════════════════════════════════════════
menu="$(show_menu)"
assert_contains "$(grep '移除舊 deb 套件' <<<"$menu")" "【GitLab 伺服器】" "選單有「移除舊 deb 套件」且標示【GitLab 伺服器】"
out="$(bash -c ". '$dkr'; docker_purge_deb() { echo PURGE-CALLED; }; dispatch 6")"
assert_eq "PURGE-CALLED" "$out" "選項 6 派發到 docker_purge_deb"
