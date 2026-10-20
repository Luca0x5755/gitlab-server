#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# nginx.sh 後半（ISSUE-010）：停用內建、憑證、反向代理、驗證、回切。純函式＋行程層級。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
ngx="$here/../nginx.sh"

. "$ngx"

# ══ 純函式 ════════════════════════════════════════════════════════════════════

# ── detect_nginx_user（PR-NGX-03、PR-COM-10）──
conf="$T_TMP/nginx.conf"
printf 'user  nginx;\nworker_processes  auto;\n' >"$conf"
assert_eq "nginx" "$(detect_nginx_user "$conf")" "官方套件：user nginx;"
printf '# user root;\nuser www-data;\nevents {}\n' >"$conf"
assert_eq "www-data" "$(detect_nginx_user "$conf")" "略過註解行，取 www-data"
printf 'user nginx nginx;\n' >"$conf"
assert_eq "nginx" "$(detect_nginx_user "$conf")" "user 後有 group：只取使用者"
printf 'user   deploy_1 ;   # comment\n' >"$conf"
assert_eq "deploy_1" "$(detect_nginx_user "$conf")" "空白與行尾註解"
printf '\tuser\twww-data;\n' >"$conf"
assert_eq "www-data" "$(detect_nginx_user "$conf")" "Tab 分隔"
printf 'user nginx; worker_processes 2;\n' >"$conf"
assert_eq "nginx" "$(detect_nginx_user "$conf")" "同一行有多個指令"
printf 'worker_processes auto;\nevents {}\n' >"$conf"
assert_nonzero "沒有 user 指令回非 0" detect_nginx_user "$conf"
printf '# user nginx;\n' >"$conf"
assert_nonzero "只有註解的 user 回非 0" detect_nginx_user "$conf"
printf 'username nginx;\n' >"$conf"
assert_nonzero "username 不是 user 指令" detect_nginx_user "$conf"
printf 'user ng$inx;\n' >"$conf"
assert_nonzero "不合法名稱不採用" detect_nginx_user "$conf"
assert_nonzero "檔案不存在回非 0" detect_nginx_user "$T_TMP/none.conf"
printf 'user nginx;' >"$conf"
assert_eq "nginx" "$(detect_nginx_user "$conf")" "無結尾換行"

# ── render_external_block ──
assert_eq $'nginx[\'enable\'] = false\nweb_server[\'external_users\'] = [\'nginx\']' "$(render_external_block nginx)" "外部 Nginx 區塊（nginx）"
assert_eq $'nginx[\'enable\'] = false\nweb_server[\'external_users\'] = [\'www-data\']' "$(render_external_block www-data)" "外部 Nginx 區塊（www-data）"
for u in "" "a'b" "a b" 'a;b' '1abc'; do assert_nonzero "區塊拒絕使用者：[$u]" render_external_block "$u"; done

# ── render_nginx_conf（PR-NGX-05）──
https="$(render_nginx_conf https 192.168.9.129 /etc/nginx/ssl/192.168.9.129.crt /etc/nginx/ssl/192.168.9.129.key)"
assert_contains "$https" "server_name 192.168.9.129;" "HTTPS：server_name 來自參數"
assert_eq "2" "$(grep -c 'server_name 192.168.9.129;' <<<"$https")" "HTTPS：80 與 443 兩個 server 都帶入"
assert_contains "$https" "ssl_certificate     /etc/nginx/ssl/192.168.9.129.crt;" "HTTPS：憑證路徑"
assert_contains "$https" "ssl_certificate_key /etc/nginx/ssl/192.168.9.129.key;" "HTTPS：私鑰路徑"
assert_contains "$https" 'return 301 https://$host$request_uri;' "HTTPS：HTTP 導向（\$host 不被 shell 展開）"
assert_contains "$https" 'proxy_set_header Host              $http_host;' "nginx 變數 \$http_host 原樣保留"
assert_contains "$https" 'proxy_set_header Upgrade    $http_upgrade;' "nginx 變數 \$http_upgrade 原樣保留"
assert_contains "$https" 'map $http_upgrade $connection_upgrade {' "map 區塊原樣保留"
assert_contains "$https" "client_max_body_size 0;" "413 對策：client_max_body_size 0"
assert_contains "$https" "proxy_read_timeout    3600;" "push/pull 對策：timeout 3600"
assert_contains "$https" "server unix:/var/opt/gitlab/gitlab-workhorse/sockets/socket fail_timeout=0;" "upstream 指向 Workhorse socket"
assert_contains "$https" "listen 443 ssl;" "HTTPS：listen 443 ssl"
assert_not_contains "$https" "@@" "HTTPS：沒有殘留佔位符"
http="$(render_nginx_conf http gitlab.example.com)"
assert_contains "$http" "server_name gitlab.example.com;" "HTTP：server_name 來自參數"
assert_not_contains "$http" "listen 443" "HTTP：沒有 443"
assert_not_contains "$http" "ssl_certificate" "HTTP：沒有憑證"
assert_contains "$http" 'proxy_set_header X-Forwarded-Proto $scheme;' "HTTP：\$scheme 原樣保留"
assert_not_contains "$http" "@@" "HTTP：沒有殘留佔位符"
# 括號平衡（粗略的語法保險）
for t in "$https" "$http"; do
    o="$(grep -o '{' <<<"$t" | wc -l)"; c="$(grep -o '}' <<<"$t" | wc -l)"
    assert_eq "$o" "$c" "大括號成對（$o）"
done
assert_nonzero "拒絕非法 server_name" render_nginx_conf https 'a;b' /a.crt /a.key
assert_nonzero "拒絕 server_name 含換行" render_nginx_conf http $'a\nb'
assert_nonzero "拒絕非法憑證路徑" render_nginx_conf https 1.2.3.4 '/a b.crt' /a.key
assert_nonzero "拒絕非絕對憑證路徑" render_nginx_conf https 1.2.3.4 a.crt /a.key
assert_nonzero "https 缺憑證參數" render_nginx_conf https 1.2.3.4
assert_nonzero "拒絕未知協定" render_nginx_conf ftp 1.2.3.4
assert_eq "" "$(render_nginx_conf https 'a;b' /a.crt /a.key 2>/dev/null)" "非法輸入不輸出"

# ── listeners_80_443（PR-NGX-07）── 手抄的 ss -Hltnp 樣式，非實機擷取
ss_free='LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=14))
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=2,fd=3))
LISTEN 0 511 127.0.0.1:8080 0.0.0.0:* users:(("puma",pid=3,fd=7))'
ss_busy="$ss_free
LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:((\"nginx\",pid=9,fd=6))
LISTEN 0 511 [::]:443 [::]:* users:((\"nginx\",pid=9,fd=7))"
assert_eq "" "$(listeners_80_443 <<<"$ss_free")" "沒有 80／443 監聽者：空（8080、22 不算）"
assert_eq "2" "$(listeners_80_443 <<<"$ss_busy" | wc -l | tr -d ' ')" "80（IPv4）與 443（IPv6）都偵測到"

# ══ 行程層級 ══════════════════════════════════════════════════════════════════

setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/opt" "$SB/home" "$SB/tmp" "$SB/confd" "$SB/nssl" "$SB/gssl" "$SB/sock"
    STUB_LOG="$SB/stub.log"
    SNAP="$SB/snap"
    : >"$STUB_LOG"
    export STUB_LOG SNAP
    printf "external_url 'GENERATED_EXTERNAL_URL'\n# nginx['enable'] = true\n" >"$SB/gitlab.rb"
    cp "$SB/gitlab.rb" "$SB/gitlab.rb.orig"
    printf 'user  nginx;\nworker_processes  auto;\n' >"$SB/nginx.conf"
    printf '%s\n' "$ss_free" >"$SB/ss.txt"
    rm -f "$OPS_ENV_FILE"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" gitlab-ctl 'case "$1" in reconfigure) cp "$GITLAB_RB" "$SNAP"; exit "${STUB_RECONF_RC:-0}" ;; status) echo "run: nginx"; exit "${STUB_GLSTATUS_RC:-0}" ;; esac'
    make_stub "$SB/bin" nginx 'if [ "$1" = -t ]; then echo "nginx: configuration file test"; exit "${STUB_NGINX_T_RC:-0}"; fi'
    make_stub "$SB/bin" systemctl 'case "$1" in is-active) exit "${STUB_ACTIVE_RC:-3}" ;; restart) exit "${STUB_RESTART_RC:-0}" ;; status) echo "● nginx.service"; exit "${STUB_STATUS_RC:-0}" ;; esac'
    make_stub "$SB/bin" ss 'cat "'"$SB"'/ss.txt"'
    make_stub "$SB/bin" ufw 'exit "${STUB_UFW_RC:-0}"'
    make_stub "$SB/bin" curl 'exit "${STUB_CURL_RC:-0}"'
}
run_ngx() { # run_ngx <stdin> [KEY=VAL…]
    local input="$1"
    shift
    printf '%b' "$input" | env -u SUDO_USER PATH="$SB/bin:$PATH" HOME="$SB/home" TMPDIR="$SB/tmp" OPS_FAKE_UID=0 \
        GITLAB_OPT_DIR="$SB/opt" GITLAB_RB="$SB/gitlab.rb" NGINX_CONF="$SB/nginx.conf" NGINX_CONF_D="$SB/confd" \
        NGINX_SSL_DIR="$SB/nssl" GITLAB_SSL_DIR="$SB/gssl" WORKHORSE_SOCKET="$SB/sock/socket" "$@" bash "$ngx" 2>&1
}
log_has() { grep -qF -- "$1" "$STUB_LOG"; }
count_log() { grep -cE -- "$1" "$STUB_LOG" || true; }
yn() { "$@" && echo yes || echo no; }
mksock() { # 建立真正的 Unix socket（[ -S ] 需要）；沒有 python3 回非 0，呼叫端略過
    have_cmd python3 || return 1
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"
}

BLOCK_WANT() { # BLOCK_WANT <使用者>：原檔＋nginx_external 區塊
    { cat "$SB/gitlab.rb.orig"; printf '# >>> gitlab-ops:nginx_external BEGIN 腳本維護，重跑整段取代，請勿手改\nnginx['"'"'enable'"'"'] = false\nweb_server['"'"'external_users'"'"'] = ['"'"'%s'"'"']\n# <<< gitlab-ops:nginx_external END\n' "$1"; } >"$SB/want"
}

# ── 選單 4：停用內建（PR-NGX-03）──
setup_sandbox dis_ok
mksock "$SB/sock/socket" && have_sock=1 || have_sock=0
out="$(run_ngx '4\nq\n')"
BLOCK_WANT nginx
assert_file_eq "$SB/want" "$SB/gitlab.rb" "區塊追加在檔尾，external_users 取自 nginx.conf（nginx）"
assert_file_eq "$SB/want" "$SNAP" "reconfigure 當下 gitlab.rb 已含區塊"
assert_eq "1" "$(count_log '^gitlab-ctl reconfigure')" "reconfigure 一次"
assert_contains "$out" "nginx" "輸出指出偵測到的使用者"
if [ "$have_sock" = 1 ]; then
    assert_contains "$out" "Workhorse socket 存在" "socket 存在：確認訊息"
    assert_not_contains "$out" "動作未完成" "socket 存在：成功"
fi
setup_sandbox dis_wwwdata
printf 'user www-data;\n' >"$SB/nginx.conf"
out="$(run_ngx '4\nq\n')"
BLOCK_WANT www-data
assert_file_eq "$SB/want" "$SB/gitlab.rb" "nginx.conf 是 www-data：區塊跟著變（不寫死）"
assert_not_contains "$(cat "$SB/gitlab.rb")" "['nginx']" "沒有寫死 nginx"
out="$(run_ngx '4\n4\nq\n')"
assert_eq "1" "$(grep -c 'gitlab-ops:nginx_external BEGIN' "$SB/gitlab.rb")" "重跑仍只有一段"
setup_sandbox dis_nosock
out="$(run_ngx '4\nq\n')"
assert_contains "$out" "找不到 Workhorse socket" "socket 不存在：警告"
assert_contains "$out" "動作未完成" "socket 不存在：回報未完成"
setup_sandbox dis_nouser
printf 'worker_processes 1;\n' >"$SB/nginx.conf"
out="$(run_ngx '4\nq\n')"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "讀不到 user：gitlab.rb 不動"
assert_eq "0" "$(count_log '^gitlab-ctl')" "讀不到 user：不 reconfigure"
assert_contains "$out" "選單 3" "讀不到 user：指向選單 3"
setup_sandbox dis_fail_yes
out="$(run_ngx '4\nyes\nq\n' STUB_RECONF_RC=1)"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "reconfigure 失敗＋yes：還原"
setup_sandbox dis_nonroot
out="$(run_ngx '4\nq\n' OPS_FAKE_UID=1000)"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "非 root：gitlab.rb 不動"
setup_sandbox dis_nogl
rmdir "$SB/opt"
out="$(run_ngx '4\nq\n')"
assert_contains "$out" "【GitLab 伺服器】" "未裝 GitLab：指向【GitLab 伺服器】"
# 與 install.sh 的 install_https 區塊並存：互不影響
setup_sandbox dis_with_https
printf "# >>> gitlab-ops:install_https BEGIN 腳本維護，重跑整段取代，請勿手改\nexternal_url 'https://1.2.3.4'\nnginx['redirect_http_to_https'] = true\n# <<< gitlab-ops:install_https END\n" >>"$SB/gitlab.rb"
cp "$SB/gitlab.rb" "$SB/gitlab.rb.orig"
out="$(run_ngx '4\nq\n')"
assert_eq "1" "$(grep -c 'gitlab-ops:install_https BEGIN' "$SB/gitlab.rb")" "install_https 區塊原封保留"
assert_eq "1" "$(grep -c 'gitlab-ops:nginx_external BEGIN' "$SB/gitlab.rb")" "nginx_external 區塊另立"

# ── 選單 5：憑證（PR-NGX-04）──
setup_sandbox cert_gen
out="$(run_ngx '5\n192.168.9.129\n\nq\n')"
assert_eq "yes" "$(yn test -f "$SB/nssl/192.168.9.129.crt" -a -f "$SB/nssl/192.168.9.129.key")" "產生 crt／key 在 NGINX_SSL_DIR"
assert_contains "$(openssl x509 -in "$SB/nssl/192.168.9.129.crt" -noout -text)" "IP Address:192.168.9.129" "共用函式：含 IP SAN"
assert_eq "600" "$(stat -c %a "$SB/nssl/192.168.9.129.key")" "私鑰 600"
assert_contains "$(cat "$OPS_ENV_FILE")" "NGX_SERVER_NAME=192.168.9.129" "server_name 存入參數檔"
setup_sandbox cert_dns
out="$(run_ngx '5\ngitlab.example.com\ngenerate\nq\n')"
assert_contains "$(openssl x509 -in "$SB/nssl/gitlab.example.com.crt" -noout -text)" "DNS:gitlab.example.com" "網域：DNS SAN"
setup_sandbox cert_copy
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$SB/gssl/10.0.0.5.key" -out "$SB/gssl/10.0.0.5.crt" -subj "/CN=10.0.0.5" 2>/dev/null
out="$(run_ngx '5\n10.0.0.5\ncopy\nq\n')"
assert_file_eq "$SB/gssl/10.0.0.5.crt" "$SB/nssl/10.0.0.5.crt" "複製既有憑證（crt 逐位元相同）"
assert_file_eq "$SB/gssl/10.0.0.5.key" "$SB/nssl/10.0.0.5.key" "複製既有憑證（key 逐位元相同）"
assert_eq "600" "$(stat -c %a "$SB/nssl/10.0.0.5.key")" "複製後私鑰 600"
setup_sandbox cert_copy_missing
out="$(run_ngx '5\n10.0.0.5\ncopy\nq\n')"
assert_eq "no" "$(yn test -e "$SB/nssl/10.0.0.5.crt")" "來源不存在：不產生檔案"
assert_contains "$out" "動作未完成" "來源不存在：回報失敗"
setup_sandbox cert_exists
run_ngx '5\n10.0.0.6\n\nq\n' >/dev/null
cp "$SB/nssl/10.0.0.6.crt" "$SB/before.crt"
out="$(run_ngx '5\n10.0.0.6\n\nno\nq\n')"
assert_file_eq "$SB/before.crt" "$SB/nssl/10.0.0.6.crt" "已有憑證回答 no：不覆蓋"
out="$(run_ngx '5\n10.0.0.6\n\nyes\nq\n')"
assert_eq "no" "$(cmp -s "$SB/before.crt" "$SB/nssl/10.0.0.6.crt" && echo same || echo no)" "已有憑證回答 yes：覆蓋"
setup_sandbox cert_bad
out="$(run_ngx '5\na;b\n')"
assert_eq "no" "$(yn test -n "$(ls -A "$SB/nssl")")" "非法主機：不產生任何檔案"

# ── 選單 6：反向代理（PR-NGX-05、06、07）──
ready_proxy() { # ready_proxy <名稱> [host]：停用內建的區塊＋憑證都備妥
    local h="${2:-192.168.9.129}"
    setup_sandbox "$1"
    { cat "$SB/gitlab.rb.orig"; printf '# >>> gitlab-ops:nginx_external BEGIN 腳本維護，重跑整段取代，請勿手改\nnginx['"'"'enable'"'"'] = false\nweb_server['"'"'external_users'"'"'] = ['"'"'nginx'"'"']\n# <<< gitlab-ops:nginx_external END\n'; } >"$SB/gitlab.rb.new"
    mv "$SB/gitlab.rb.new" "$SB/gitlab.rb"
    openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$SB/nssl/$h.key" -out "$SB/nssl/$h.crt" -subj "/CN=$h" 2>/dev/null
}
ready_proxy px_ok
printf 'server { listen 80 default_server; server_name localhost; }\n' >"$SB/confd/default.conf"
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n')"
assert_eq "yes" "$(yn test -f "$SB/confd/gitlab.conf")" "寫出 gitlab.conf"
assert_contains "$(cat "$SB/confd/gitlab.conf")" "server_name 192.168.9.129;" "gitlab.conf 的 server_name"
assert_contains "$(cat "$SB/confd/gitlab.conf")" "ssl_certificate     $SB/nssl/192.168.9.129.crt;" "gitlab.conf 的憑證路徑來自參數"
assert_contains "$(cat "$SB/confd/gitlab.conf")" 'proxy_set_header Host              $http_host;' "gitlab.conf 的 nginx 變數未被展開"
assert_eq "no" "$(yn test -e "$SB/confd/default.conf")" "預設站台 default.conf 已移除"
assert_eq "yes" "$(yn test -n "$(ls "$SB"/confd/default.conf.bak-* 2>/dev/null)")" "預設站台留有改名備份（可復原）"
assert_eq "1" "$(count_log '^nginx -t')" "執行 nginx -t"
assert_eq "1" "$(count_log '^systemctl restart nginx')" "systemctl restart nginx"
assert_eq "1" "$(count_log '^systemctl enable nginx')" "systemctl enable nginx"
assert_eq "1" "$(count_log '^ufw allow 80/tcp')" "ufw allow 80/tcp"
assert_eq "1" "$(count_log '^ufw allow 443/tcp')" "ufw allow 443/tcp"
# nginx -t 先於 restart
assert_eq "yes" "$([ "$(grep -n '^nginx -t' "$STUB_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^systemctl restart' "$STUB_LOG" | head -1 | cut -d: -f1)" ] && echo yes || echo no)" "nginx -t 在 restart 之前"
assert_contains "$out" "外部 Nginx 已啟用" "成功訊息"
assert_contains "$(cat "$OPS_ENV_FILE")" "NGX_SCHEME=https" "協定存入參數檔"

ready_proxy px_http
out="$(run_ngx '6\n192.168.9.129\nhttp\nq\n')"
assert_not_contains "$(cat "$SB/confd/gitlab.conf")" "listen 443" "HTTP 模式：沒有 443"
assert_contains "$(cat "$SB/confd/gitlab.conf")" "server_name 192.168.9.129;" "HTTP 模式：server_name"
assert_eq "1" "$(count_log '^systemctl restart nginx')" "HTTP 模式：也會啟動"

ready_proxy px_dns gitlab.example.com
out="$(run_ngx '6\ngitlab.example.com\nhttps\nq\n')"
assert_contains "$(cat "$SB/confd/gitlab.conf")" "server_name gitlab.example.com;" "網域 server_name"

# nginx -t 失敗：還原舊設定，不重啟（PR-NGX-06）
ready_proxy px_t_fail_old
printf '# 舊的 gitlab.conf\n' >"$SB/confd/gitlab.conf"
printf 'server { listen 80 default_server; }\n' >"$SB/confd/default.conf"
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n' STUB_NGINX_T_RC=1)"
assert_eq "# 舊的 gitlab.conf" "$(cat "$SB/confd/gitlab.conf")" "nginx -t 失敗：還原舊的 gitlab.conf"
assert_eq "0" "$(count_log '^systemctl restart')" "nginx -t 失敗：不重啟 nginx"
assert_eq "yes" "$(yn test -f "$SB/confd/default.conf")" "nginx -t 失敗：default.conf 原封不動"
assert_eq "0" "$(count_log '^ufw')" "nginx -t 失敗：不動防火牆"
assert_contains "$out" "動作未完成" "nginx -t 失敗：回報失敗"
ready_proxy px_t_fail_new
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n' STUB_NGINX_T_RC=1)"
assert_eq "no" "$(yn test -e "$SB/confd/gitlab.conf")" "nginx -t 失敗且原本沒有設定：不留下新檔"
assert_eq "0" "$(count_log '^systemctl restart')" "nginx -t 失敗且原本沒有設定：不重啟"

# 重跑：舊設定備份
ready_proxy px_rerun
run_ngx '6\n192.168.9.129\nhttps\nq\n' >/dev/null
out="$(run_ngx '6\n192.168.9.129\nhttp\nq\n')"
assert_eq "yes" "$(yn test -n "$(ls "$SB"/confd/gitlab.conf.bak-* 2>/dev/null)")" "重跑：舊 gitlab.conf 留備份"

# 80／443 未釋放（PR-NGX-07）
ready_proxy px_busy
printf '%s\n' "$ss_busy" >"$SB/ss.txt"
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n')"
assert_eq "no" "$(yn test -e "$SB/confd/gitlab.conf")" "80／443 被佔用：不寫設定"
assert_eq "0" "$(count_log '^systemctl restart')" "80／443 被佔用：不啟動 nginx"
assert_contains "$out" "仍被佔用" "80／443 被佔用：說明"
assert_contains "$out" "選單 4" "80／443 被佔用：指向選單 4"
ready_proxy px_busy_self
printf '%s\n' "$ss_busy" >"$SB/ss.txt"
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n' STUB_ACTIVE_RC=0)"
assert_eq "1" "$(count_log '^systemctl restart nginx')" "外部 nginx 自己在跑：不算衝突，照常重啟"

# 前置條件
setup_sandbox px_noblock
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$SB/nssl/192.168.9.129.key" -out "$SB/nssl/192.168.9.129.crt" -subj "/CN=x" 2>/dev/null
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n')"
assert_eq "no" "$(yn test -e "$SB/confd/gitlab.conf")" "尚未停用內建：不寫設定"
assert_contains "$out" "選單 4" "尚未停用內建：指向選單 4"
ready_proxy px_nocert
rm -f "$SB/nssl/"*
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n')"
assert_eq "no" "$(yn test -e "$SB/confd/gitlab.conf")" "沒有憑證：不寫設定"
assert_contains "$out" "選單 5" "沒有憑證：指向選單 5"
ready_proxy px_badname
out="$(run_ngx '6\na;b\n')"
assert_eq "no" "$(yn test -e "$SB/confd/gitlab.conf")" "server_name 非法：不寫設定"
ready_proxy px_nonroot
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n' OPS_FAKE_UID=1000)"
assert_eq "no" "$(yn test -e "$SB/confd/gitlab.conf")" "非 root：不寫設定"
ready_proxy px_ufw_fail
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n' STUB_UFW_RC=1)"
assert_contains "$out" "手動放行" "ufw 失敗：提示手動放行"
assert_not_contains "$out" "動作未完成" "ufw 失敗：不算動作失敗"
ready_proxy px_restart_fail
out="$(run_ngx '6\n192.168.9.129\nhttps\nq\n' STUB_RESTART_RC=1)"
assert_contains "$out" "動作未完成" "restart 失敗：回報失敗"
assert_not_contains "$out" "外部 Nginx 已啟用" "restart 失敗：不宣稱成功"

# ── 選單 7：驗證（PR-NGX-08）──
ready_proxy ver_ok
env_set NGX_SERVER_NAME 192.168.9.129
env_set NGX_SCHEME https
out="$(run_ngx '7\nq\n')"
assert_eq "1" "$(count_log '^systemctl status nginx')" "systemctl status nginx"
assert_eq "1" "$(count_log '^gitlab-ctl status')" "gitlab-ctl status"
assert_eq "1" "$(count_log '^curl -kI -sS -m 10 https://192.168.9.129')" "curl -kI https://<IP>"
assert_contains "$out" "驗證通過" "全部通過：成功訊息"
assert_not_contains "$out" "動作未完成" "全部通過：不報失敗"
ready_proxy ver_http
env_set NGX_SERVER_NAME 192.168.9.129
env_set NGX_SCHEME http
out="$(run_ngx '7\nq\n')"
assert_eq "1" "$(count_log '^curl -kI -sS -m 10 http://192.168.9.129')" "HTTP 模式：curl http://"
for f in STUB_STATUS_RC STUB_GLSTATUS_RC STUB_CURL_RC; do
    ready_proxy "ver_$f"
    env_set NGX_SERVER_NAME 192.168.9.129
    out="$(run_ngx '7\nq\n' "$f=1")"
    assert_contains "$out" "動作未完成" "驗證：$f 失敗整體回報失敗"
    assert_not_contains "$out" "驗證通過" "驗證：$f 失敗不宣稱通過"
    assert_eq "1" "$(count_log '^curl ')" "驗證：$f 失敗仍把三項都跑完"
done
ready_proxy ver_noname
out="$(run_ngx '7\nq\n')"
assert_contains "$out" "選單 6" "沒設定過 server_name：指向選單 6"

# ── 選單 8：切回內建（PR-NGX-09）──
ready_proxy rev_ok
out="$(run_ngx '8\nyes\nq\n')"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "移除區塊後 gitlab.rb 回到原檔"
assert_eq "1" "$(count_log '^systemctl stop nginx')" "停用外部 nginx"
assert_eq "1" "$(count_log '^systemctl disable nginx')" "關閉外部 nginx 自動啟動"
assert_eq "1" "$(count_log '^gitlab-ctl reconfigure')" "reconfigure"
assert_eq "yes" "$([ "$(grep -n '^systemctl stop nginx' "$STUB_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^gitlab-ctl reconfigure' "$STUB_LOG" | head -1 | cut -d: -f1)" ] && echo yes || echo no)" "先停外部 nginx 才 reconfigure（釋放 80／443）"
assert_contains "$out" "已切回內建 Nginx" "成功訊息"
ready_proxy rev_no
out="$(run_ngx '8\nno\nq\n')"
assert_eq "0" "$(count_log '^systemctl')" "回答 no：不動 nginx"
assert_eq "0" "$(count_log '^gitlab-ctl')" "回答 no：不 reconfigure"
ready_proxy rev_eof
out="$(run_ngx '8\n')"
assert_eq "0" "$(count_log '^systemctl')" "EOF 視為否：不動 nginx"
setup_sandbox rev_noblock
out="$(run_ngx '8\nq\n')"
assert_contains "$out" "不需切換" "沒有區塊：不需切換"
assert_eq "0" "$(count_log '^systemctl')" "沒有區塊：不動 nginx"
assert_not_contains "$out" "動作未完成" "沒有區塊：不算失敗"
ready_proxy rev_fail
out="$(run_ngx '8\nyes\nyes\nq\n' STUB_RECONF_RC=1)"
assert_contains "$out" "動作未完成" "reconfigure 失敗：回報失敗"
ready_proxy rev_nonroot
out="$(run_ngx '8\nyes\nq\n' OPS_FAKE_UID=1000)"
assert_eq "0" "$(count_log '^systemctl')" "非 root：不動 nginx"
# 回切後再停用：循環可重複
ready_proxy rev_cycle
run_ngx '8\nyes\nq\n' >/dev/null
out="$(run_ngx '4\nq\n')"
assert_eq "1" "$(grep -c 'gitlab-ops:nginx_external BEGIN' "$SB/gitlab.rb")" "回切後可再次停用內建"

# ── 選單與說明排查（PR-COM-04、11）──
setup_sandbox menu
menu="$(run_ngx 'q\n')"
for n in 4 5 6 7 8; do assert_contains "$(grep "^  $n)" <<<"$menu")" "【GitLab 伺服器】" "選單第 $n 項標示【GitLab 伺服器】"; done
help="$(run_ngx '9\nq\n')"
for k in "external_url" "web_server['external_users']" "nginx.conf" "nginx -t" "ufw allow 80/tcp" "curl -kI" "切換回內建 Nginx"; do
    assert_contains "$help" "$k" "說明含：$k"
done
fix="$(run_ngx '10\nq\n')"
for k in "選單 4" "選單 6" "nginx -t 失敗" "Workhorse socket" "切回內建後"; do assert_contains "$fix" "$k" "排查含：$k"; done
