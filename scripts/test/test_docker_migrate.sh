#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# docker.sh 遷移流程（ISSUE-004）：接縫 A 純函式、接縫 B 階段函式（假 docker 等）、接縫 C 全流程。
# 期望值一律寫死字面值，不用被測程式重算。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
dkr="$here/../docker.sh"
. "$dkr"

# ══ 接縫 A：純函式 ════════════════════════════════════════════════════════════

# ── docker_run_args：PR-DKR-15 ──
exp_args='-d
--name
gitlab
--restart
always
--shm-size
256m
-p
80:80
-p
443:443
-p
2222:22
-v
/etc/gitlab:/etc/gitlab
-v
/var/opt/gitlab:/var/opt/gitlab
-v
/var/log/gitlab:/var/log/gitlab
gitlab/gitlab-ce:18.10.3-ce.0'
assert_eq "$exp_args" "$(docker_run_args gitlab/gitlab-ce:18.10.3-ce.0)" "docker run 參數：名稱、重啟、shm、三個埠、三個掛載、映像"
assert_not_contains $'
'"$(docker_run_args gitlab/gitlab-ce:18.10.3-ce.0)" $'
'"22:22" "不發佈宿主機 22"
assert_nonzero "映像參照為空拒絕" docker_run_args ""
assert_eq "-v
/etc/gitlab:/etc/gitlab
-v
/var/opt/gitlab:/var/opt/gitlab
-v
/var/log/gitlab:/var/log/gitlab" "$(docker_mount_args)" "三個掛載目錄，宿主機與容器路徑相同"

# ── docker_migrate_rb_content：PR-DKR-12 ──
rb="$T_TMP/gitlab.rb"
printf '%s\n' "external_url 'https://10.0.0.5'" "# 手寫設定" \
    "# >>> gitlab-ops:nginx_external BEGIN 腳本維護，重跑整段取代，請勿手改" \
    "nginx['enable'] = false" "web_server['external_users'] = ['www-data']" \
    "# <<< gitlab-ops:nginx_external END" "gitlab_rails['backup_keep_time'] = 604800" >"$rb"
exp_rb="external_url 'https://10.0.0.5'
# 手寫設定
gitlab_rails['backup_keep_time'] = 604800
# >>> gitlab-ops:docker_ssh_port BEGIN 腳本維護，重跑整段取代，請勿手改
gitlab_rails['gitlab_shell_ssh_port'] = 2222
# <<< gitlab-ops:docker_ssh_port END"
assert_eq "$exp_rb" "$(docker_migrate_rb_content "$rb")" "移除 nginx_external 區塊、加 2222 區塊，其餘手寫內容不動"
docker_migrate_rb_content "$rb" >"$T_TMP/rb1"
cp "$T_TMP/rb1" "$rb"
assert_file_eq <(docker_migrate_rb_content "$rb") "$T_TMP/rb1" "重跑結果相同（冪等）"
printf '%s\n' "# >>> gitlab-ops:nginx_external BEGIN x" "nginx['enable'] = false" >"$rb"
assert_nonzero "標記毀損拒絕" docker_migrate_rb_content "$rb"
assert_nonzero "檔案不存在拒絕" docker_migrate_rb_content "$T_TMP/none.rb"

# ── docker_busy_listeners：PR-DKR-13 ──
ss_out='LISTEN 0 511 0.0.0.0:80 0.0.0.0:*
LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
LISTEN 0 511 [::]:443 [::]:*
LISTEN 0 4096 127.0.0.1:2222 0.0.0.0:*
LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*
LISTEN 0 128 0.0.0.0:12222 0.0.0.0:*'
assert_eq 'LISTEN 0 511 0.0.0.0:80 0.0.0.0:*
LISTEN 0 511 [::]:443 [::]:*
LISTEN 0 4096 127.0.0.1:2222 0.0.0.0:*' "$(docker_busy_listeners <<<"$ss_out")" "只列出占用 80／443／2222 的行（22、8080、12222 不算）"
assert_eq "" "$(docker_busy_listeners <<<"LISTEN 0 128 0.0.0.0:22 0.0.0.0:*")" "沒有占用時輸出空"

# ── docker_external_url ──
printf '%s\n' "# external_url 'http://old'" "external_url \"https://10.0.0.5:8443\"" "external_url_other 'x'" >"$rb"
assert_eq "https://10.0.0.5:8443" "$(docker_external_url "$rb")" "取未註解的 external_url"
printf '%s\n' "# external_url 'http://old'" >"$rb"
assert_nonzero "只有註解行：找不到" docker_external_url "$rb"

# ── docker_version_matches：PR-DKR-10 ──
assert_status 0 "deb 版本等於 tag" docker_version_matches 18.10.3-ce.0 18.10.3-ce.0
assert_status 1 "版本不同" docker_version_matches 18.7.6-ce.0 18.10.3-ce.0
assert_status 1 "非法版本不算相符" docker_version_matches "" 18.10.3-ce.0

# ── format_bytes ──
assert_eq "0 B" "$(format_bytes 0)" "0 位元組"
assert_eq "1023 B" "$(format_bytes 1023)" "不到 1 KiB"
assert_eq "1.0 KiB" "$(format_bytes 1024)" "1 KiB"
assert_eq "2.5 GiB" "$(format_bytes 2684354560)" "2.5 GiB"

# ── http_status_ok：PR-DKR-17 ──
assert_status 0 "200 通過" http_status_ok 200
assert_status 0 "302 通過" http_status_ok 302
assert_status 1 "502 不通過" http_status_ok 502
assert_status 1 "000（連不上）不通過" http_status_ok 000
assert_status 1 "非數字不通過" http_status_ok abc

# ══ 接縫 B：階段函式（PATH 放假指令；真實 docker／systemctl 動作不在此驗證）══════════

# 佈置沙箱。假指令的行為由環境變數注入：
#   NO_IMAGE=1 映像未載入；HAS_CONTAINER=1 已有名為 gitlab 的容器；FAIL_RUN=1 docker run 失敗；
#   HEALTH_OUT=<輸出> docker inspect 的回傳（預設 "running healthy"）；RAKE_RC=<碼> gitlab-rake 的結束碼；
#   CURL_CODE=<碼> curl 印出的 HTTP 狀態碼；SS_OUT=<文字> ss 的輸出；FAIL_CTL=1 gitlab-ctl 失敗。
setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/data/git-data/repositories" "$SB/bk/data" "$SB/bk/etc"
    export HOME="$SB"
    export STUB_LOG="$SB/stub.log"
    : >"$STUB_LOG"
    export OPS_ENV_FILE="$SB/ops.env"
    export GITLAB_RB="$SB/gitlab.rb"
    export GLC_DATA_DIR="$SB/data"
    export GITLAB_BACKUP_DIR="$SB/bk/data"
    export GITLAB_CONFIG_BACKUP_DIR="$SB/bk/etc"
    export GITLAB_OPT_DIR="$SB/opt"
    mkdir -p "$SB/opt"
    unset NO_IMAGE HAS_CONTAINER FAIL_RUN HEALTH_OUT RAKE_RC CURL_CODE SS_OUT FAIL_CTL
    export GLC_HEALTH_INTERVAL=0 GLC_HEALTH_MAX=2
    export OPS_FAKE_UID=0
    printf '%s\n' "external_url 'https://10.0.0.5'" \
        "# >>> gitlab-ops:nginx_external BEGIN 腳本維護，重跑整段取代，請勿手改" \
        "nginx['enable'] = false" "# <<< gitlab-ops:nginx_external END" >"$GITLAB_RB"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" docker '
case "$1" in
    image) [ "${NO_IMAGE:-}" = 1 ] && exit 1; exit 0 ;;
    ps) [ "${HAS_CONTAINER:-}" = 1 ] && echo gitlab; exit 0 ;;
    run) [ "${FAIL_RUN:-}" = 1 ] && exit 1; exit 0 ;;
    inspect) echo "${HEALTH_OUT:-running healthy}"; exit 0 ;;
    exec) exit "${RAKE_RC:-0}" ;;
esac'
    make_stub "$SB/bin" gitlab-ctl '[ "${FAIL_CTL:-}" = 1 ] && exit 1; exit 0'
    make_stub "$SB/bin" systemctl 'exit 0'
    make_stub "$SB/bin" ss 'printf "%s\n" "${SS_OUT:-}"'
    make_stub "$SB/bin" curl 'echo "${CURL_CODE:-302}"'
    export PATH="$SB/bin:$PATH"
    docker_deb_version() { echo "18.10.3-ce.0"; }
    # 假備份：把沙箱裡「2000」那組備份的 mtime 設成未來，模擬「這次剛產生」；舊的「1000」組不動。
    docker_run_backup() {
        echo "backup ran" >>"$STUB_LOG"
        touch -c -d "1 minute" "$SB"/bk/data/2000_* "$SB"/bk/etc/gitlab_config_2000_* 2>/dev/null
        return "${BACKUP_RC:-0}"
    }
    gitlab_reconfigure() { echo "RECONFIGURE" >>"$STUB_LOG"; }
    now_stamp() { echo 20260101000000; }
    TAG=18.10.3-ce.0
}

# ── docker_preflight：PR-DKR-10 ──
setup_sandbox pre_ok
( docker_preflight "$TAG" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "前置檢查全部符合：通過"
assert_contains "$(cat "$STUB_LOG")" "docker image inspect gitlab/gitlab-ce:18.10.3-ce.0" "檢查映像是否已載入"

setup_sandbox pre_ver
docker_deb_version() { echo "18.7.6-ce.0"; }
( docker_preflight "$TAG" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "deb 版本與 tag 不符：中止"
assert_contains "$(cat "$SB/o.txt")" "18.7.6-ce.0" "版本不符訊息點名 deb 版本"

setup_sandbox pre_noimg
NO_IMAGE=1 bash -c ". '$dkr'; docker_deb_version() { echo $TAG; }; docker_preflight $TAG" >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "映像未載入：中止"
assert_contains "$(cat "$SB/o.txt")" "載入" "映像未載入訊息指向載入映像包"

setup_sandbox pre_cont
HAS_CONTAINER=1 bash -c ". '$dkr'; docker_deb_version() { echo $TAG; }; docker_preflight $TAG" >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "已有名為 gitlab 的容器：中止"

setup_sandbox pre_nodocker
( have_cmd() { [ "$1" != docker ]; }; docker_preflight "$TAG" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "Docker 未安裝：中止"

setup_sandbox pre_nodir
rmdir "$SB/data/git-data/repositories"
( docker_preflight "$TAG" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "git-data/repositories 不存在：中止"
ln -s "$SB/nowhere" "$SB/data/git-data/repositories"
( docker_preflight "$TAG" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "git-data/repositories 是壞掉的 symlink：中止"
assert_contains "$(cat "$SB/o.txt")" "repositories" "訊息點名 repositories"

# ── docker_backup_stage：PR-DKR-11 ──
mk_backups() { # 在沙箱放新舊各一份備份
    : >"$SB/bk/data/1000_2026_01_01_18.10.3_gitlab_backup.tar"
    head -c 2048 /dev/zero >"$SB/bk/data/2000_2026_01_02_18.10.3_gitlab_backup.tar"
    : >"$SB/bk/etc/gitlab_config_1000_2026_01_01.tar"
    head -c 3072 /dev/zero >"$SB/bk/etc/gitlab_config_2000_2026_01_02.tar"
    touch -d '2026-01-01' "$SB/bk/data/1000_2026_01_01_18.10.3_gitlab_backup.tar" "$SB/bk/etc/gitlab_config_1000_2026_01_01.tar"
    touch -d '2026-01-02' "$SB/bk/data/2000_2026_01_02_18.10.3_gitlab_backup.tar" "$SB/bk/etc/gitlab_config_2000_2026_01_02.tar"
}
setup_sandbox bk_ok
mk_backups
printf '%s\n' "$GLC_OFFSITE_PHRASE" | ( docker_backup_stage ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "備份成功且輸入確認字串：通過"
assert_contains "$(cat "$SB/o.txt")" "$SB/bk/data/2000_2026_01_02_18.10.3_gitlab_backup.tar" "列出最新資料備份的路徑"
assert_contains "$(cat "$SB/o.txt")" "2.0 KiB" "列出資料備份的大小"
assert_contains "$(cat "$SB/o.txt")" "$SB/bk/etc/gitlab_config_2000_2026_01_02.tar" "列出最新設定備份的路徑"
assert_contains "$(cat "$SB/o.txt")" "3.0 KiB" "列出設定備份的大小"
assert_not_contains "$(cat "$SB/o.txt")" "1000_2026" "不列出舊的備份"

setup_sandbox bk_wrong
mk_backups
printf '%s\n' "yes" | ( docker_backup_stage ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "輸入錯誤的確認字串：中止"
assert_contains "$(cat "$SB/o.txt")" "備份" "中止訊息說明"
setup_sandbox bk_eof
mk_backups
( docker_backup_stage ) </dev/null >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "stdin EOF 視為未確認：中止"
assert_eq "" "$(grep -E '^(gitlab-ctl|systemctl)' "$STUB_LOG" || true)" "未確認時不動 deb 版（沒有呼叫 gitlab-ctl／systemctl）"

setup_sandbox bk_fail
mk_backups
bash -c ". '$dkr'; docker_run_backup() { return 3; }; echo '$GLC_OFFSITE_PHRASE' | docker_backup_stage" >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "備份失敗：中止"
assert_contains "$(cat "$SB/o.txt")" "備份失敗" "備份失敗訊息"
assert_not_contains "$(cat "$SB/o.txt")" "已複製到機外" "備份失敗時不進入機外確認"

setup_sandbox bk_nofile
printf '%s\n' "$GLC_OFFSITE_PHRASE" | ( docker_backup_stage ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "備份成功卻找不到備份檔：中止"

# ── docker_edit_gitlab_rb：PR-DKR-12 ──
setup_sandbox rb_ok
cp "$GITLAB_RB" "$SB/rb.before"
( docker_edit_gitlab_rb ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "改 gitlab.rb 成功"
assert_eq "external_url 'https://10.0.0.5'
# >>> gitlab-ops:docker_ssh_port BEGIN 腳本維護，重跑整段取代，請勿手改
gitlab_rails['gitlab_shell_ssh_port'] = 2222
# <<< gitlab-ops:docker_ssh_port END" "$(cat "$GITLAB_RB")" "外部 Nginx 區塊移除、加入 2222 區塊"
assert_file_eq "$SB/rb.before" "$SB/gitlab.rb.bak-20260101000000" "改前備份為 gitlab.rb.bak-<時間戳>（內容為改前原文）"
assert_eq "1" "$(ls "$SB"/gitlab.rb.bak-* | wc -l | tr -d ' ')" "只備份一次"
assert_not_contains "$(cat "$STUB_LOG")" "RECONFIGURE" "不在宿主機 reconfigure（交給容器啟動）"

setup_sandbox rb_bad
printf '%s\n' "# >>> gitlab-ops:nginx_external BEGIN x" "nginx['enable'] = false" >"$GITLAB_RB"
cp "$GITLAB_RB" "$SB/rb.before"
( docker_edit_gitlab_rb ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "標記毀損：中止"
assert_file_eq "$SB/rb.before" "$GITLAB_RB" "標記毀損時 gitlab.rb 原樣不動"
assert_eq "0" "$(ls "$SB"/gitlab.rb.bak-* 2>/dev/null | wc -l | tr -d ' ')" "標記毀損時不產生備份"

# ── docker_stop_deb：PR-DKR-13 ──
setup_sandbox stop_ok
( docker_stop_deb ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "停 deb 版且埠空閒：通過"
assert_eq "gitlab-ctl stop
systemctl disable --now gitlab-runsvdir
ss -Hltn" "$(cat "$STUB_LOG")" "依序：gitlab-ctl stop、停用開機服務、檢查埠"

setup_sandbox stop_busy
( export SS_OUT='LISTEN 0 511 0.0.0.0:443 0.0.0.0:*'; docker_stop_deb ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "443 被占用：中止"
assert_contains "$(cat "$SB/o.txt")" "443" "訊息點名被占用的埠"

setup_sandbox stop_ctlfail
( export FAIL_CTL=1; docker_stop_deb ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "gitlab-ctl stop 失敗：中止"
assert_not_contains "$(cat "$STUB_LOG")" "systemctl" "gitlab-ctl 失敗後不繼續"

# ── docker_align_permissions：PR-DKR-14 ──
setup_sandbox perm_ok
ref=gitlab/gitlab-ce:18.10.3-ce.0
( docker_align_permissions "$ref" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "對齊權限成功"
assert_eq "docker run --rm -v /etc/gitlab:/etc/gitlab -v /var/opt/gitlab:/var/opt/gitlab -v /var/log/gitlab:/var/log/gitlab $ref update-permissions" "$(cat "$STUB_LOG")" "暫時容器掛三個掛載目錄並執行 update-permissions"
setup_sandbox perm_fail
( export FAIL_RUN=1; docker_align_permissions "$ref" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "update-permissions 失敗：中止"
assert_contains "$(cat "$SB/o.txt")" "權限" "訊息說明權限步驟"
assert_eq "" "$(grep -E '(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?chown([[:space:]]|$)' "$dkr" || true)" "docker.sh 沒有執行 chown 指令（不得把宿主機目錄 chown 成 root:root）"

# ── docker_start_container：PR-DKR-15 ──
setup_sandbox run_ok
( docker_start_container "$ref" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "啟動容器成功"
assert_eq "docker run -d --name gitlab --restart always --shm-size 256m -p 80:80 -p 443:443 -p 2222:22 -v /etc/gitlab:/etc/gitlab -v /var/opt/gitlab:/var/opt/gitlab -v /var/log/gitlab:/var/log/gitlab $ref" "$(cat "$STUB_LOG")" "docker run 參數完全等於組裝結果"
setup_sandbox run_fail
( export FAIL_RUN=1; docker_start_container "$ref" ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "docker run 失敗：中止"
assert_not_contains "$(cat "$dkr")" "sshd_config" "docker.sh 不引用 sshd_config（宿主機 sshd 不被修改）"

# ── docker_wait_healthy：PR-DKR-16 ──
setup_sandbox hl_ok
( docker_wait_healthy ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "容器 healthy：成功"
setup_sandbox hl_starting
( export HEALTH_OUT="running starting"; docker_wait_healthy ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "一直 starting：逾時失敗"
assert_contains "$(cat "$SB/o.txt")" "docker logs gitlab" "逾時訊息指向 docker logs gitlab"
setup_sandbox hl_exited
( export HEALTH_OUT="exited none"; docker_wait_healthy ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "容器已結束：失敗"
assert_contains "$(cat "$SB/o.txt")" "docker logs gitlab" "容器結束訊息指向 docker logs gitlab"
assert_eq "1" "$(grep -c '^docker inspect' "$STUB_LOG")" "容器已結束時不再多等"

# ── docker_verify：PR-DKR-17 ──
setup_sandbox vf_ok
( docker_verify ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "gitlab:check 與 curl 都通過"
assert_eq "docker exec gitlab gitlab-rake gitlab:check
curl -ksI --max-time 30 -o /dev/null -w %{http_code} https://10.0.0.5" "$(cat "$STUB_LOG")" "在容器內跑 gitlab:check，再 curl -kI external_url"
setup_sandbox vf_rake
( export RAKE_RC=1; docker_verify ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "gitlab:check 失敗：中止"
assert_not_contains "$(cat "$STUB_LOG")" "curl" "gitlab:check 失敗時不再 curl"
setup_sandbox vf_curl
( export CURL_CODE=502; docker_verify ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "curl 回 502：失敗"
assert_contains "$(cat "$SB/o.txt")" "502" "訊息含實際狀態碼"
setup_sandbox vf_nourl
printf '%s\n' "# nothing" >"$GITLAB_RB"
( docker_verify ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "gitlab.rb 讀不到 external_url：失敗"

# ══ 接縫 C：docker_migrate 全流程與選單 ════════════════════════════════════════

# 把每個階段換成只記錄名稱的函式；FAIL_STAGE=<函式名> 使該階段 die。
run_migrate() { # run_migrate <stdin 文字>  （輸出寫入 $SB/o.txt，回傳 docker_migrate 的結束碼）
    printf '%b' "$1" | bash -c "
        . '$dkr'
        stage() { echo \"\$1\" >>'$SB/order.log'; [ \"\${FAIL_STAGE:-}\" = \"\$1\" ] && die \"\$2失敗\"; return 0; }
        docker_preflight() { stage docker_preflight 前置檢查; }
        docker_backup_stage() { stage docker_backup_stage 備份; }
        docker_edit_gitlab_rb() { stage docker_edit_gitlab_rb gitlab.rb; }
        docker_stop_deb() { stage docker_stop_deb 停止; }
        docker_align_permissions() { stage docker_align_permissions 權限; }
        docker_start_container() { stage docker_start_container 啟動; }
        docker_wait_healthy() { stage docker_wait_healthy 健康; }
        docker_verify() { stage docker_verify 驗證; }
        docker_migrate
    " >"$SB/o.txt" 2>&1
}

setup_sandbox mig_ok
run_migrate '\nyes\n' && r=0 || r=$?
assert_eq "0" "$r" "全流程成功：結束碼 0"
assert_eq "docker_preflight
docker_backup_stage
docker_edit_gitlab_rb
docker_stop_deb
docker_align_permissions
docker_start_container
docker_wait_healthy
docker_verify" "$(cat "$SB/order.log")" "階段順序：前置檢查→備份→改 gitlab.rb→停 deb→權限→啟動→等健康→驗證"
assert_contains "$(cat "$OPS_ENV_FILE")" "GLC_START_TAG=18.10.3-ce.0" "起始 tag 存入參數檔，預設 18.10.3-ce.0"

setup_sandbox mig_noyes
run_migrate '\nno\n' && r=0 || r=$?
assert_eq "0" "$r" "不輸入 yes：取消（不算失敗）"
assert_eq "docker_preflight" "$(cat "$SB/order.log")" "未確認 yes 時只做完前置檢查，不備份、不動 deb"
setup_sandbox mig_eof
run_migrate '\n' && r=0 || r=$?
assert_eq "docker_preflight" "$(cat "$SB/order.log")" "EOF 視為否"

for st in docker_preflight docker_backup_stage docker_edit_gitlab_rb docker_stop_deb docker_align_permissions docker_start_container docker_wait_healthy docker_verify; do
    setup_sandbox "mig_fail_$st"
    ( export FAIL_STAGE=$st; run_migrate '\nyes\n' ) && r=0 || r=$?
    assert_eq "1" "$r" "$st 失敗：整體非 0"
    assert_eq "$st" "$(tail -n1 "$SB/order.log")" "$st 失敗後，後面的階段不再被呼叫"
    assert_contains "$(cat "$SB/o.txt")" "失敗" "$st 失敗：輸出說明失敗原因"
done


# ── 選單 ──
menu="$(show_menu)"
assert_contains "$(grep '遷移到 Docker' <<<"$menu")" "【GitLab 伺服器】" "選單有「遷移到 Docker」且標示【GitLab 伺服器】"
setup_sandbox menu_dispatch
out="$(bash -c ". '$dkr'; docker_migrate() { echo MIGRATE-CALLED; }; dispatch 5")"
assert_eq "MIGRATE-CALLED" "$out" "選項 5 派發到 docker_migrate"

setup_sandbox menu_noserver
rm -rf "$GITLAB_OPT_DIR"
out="$(printf '5\nq\n' | bash "$dkr" 2>&1)" && r=0 || r=$?
assert_contains "$out" "找不到 GitLab" "不是 GitLab 伺服器：require_machine server 中止並說明"
assert_not_contains "$(cat "$STUB_LOG")" "docker" "角色閘門先於任何 docker 動作"

setup_sandbox menu_server
out="$(printf '5\n\nq\n' | OPS_FAKE_UID=0 bash "$dkr" 2>&1)" && r=0 || r=$?
assert_not_contains "$out" "找不到 GitLab" "有 /opt/gitlab：通過角色閘門"
assert_contains "$out" "前置檢查失敗" "接著進入前置檢查（沙箱 deb 版本讀不到而在此中止）"

# ── 備份檔須比這次備份開始時新（舊備份不可冒充）──
setup_sandbox bk_stale
mk_backups
docker_run_backup() { return 0; }
printf '%s\n' "$GLC_OFFSITE_PHRASE" | ( docker_backup_stage ) >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "備份回 0 卻沒產生新檔（只有舊備份）：中止"
assert_contains "$(cat "$SB/o.txt")" "這次產生" "訊息說明找不到這次產生的備份"
