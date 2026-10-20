#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# lib/common.sh 的行為（接縫 A）：source 後直接呼叫函式。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
common="$here/../lib/common.sh"

# ── source 無副作用（PR-COM-02）──
before="$( (cd /; set +o; pwd) )"
after="$( (cd /; . "$common"; set +o; pwd) )"
assert_eq "$before" "$after" "source common.sh 不改 shell 選項也不 cd"

. "$common"

# ── confirm（PR-COM-03）──
assert_status 0 "輸入 yes 通過" bash -c ". '$common'; echo yes | confirm 確定嗎"
assert_nonzero "輸入 y 不通過" bash -c ". '$common'; echo y | confirm 確定嗎"
assert_nonzero "輸入 YES 不通過" bash -c ". '$common'; echo YES | confirm 確定嗎"
assert_nonzero "空行不通過" bash -c ". '$common'; echo | confirm 確定嗎"
assert_nonzero "stdin EOF 視為否" bash -c ". '$common'; confirm 確定嗎 </dev/null"

# ── reject_args（PR-COM-01）──
assert_status 0 "無參數放行" reject_args
assert_status 2 "有參數即拒絕並以 2 結束" bash -c ". '$common'; reject_args foo"
assert_status 2 "空字串參數也拒絕" bash -c ". '$common'; reject_args ''"
err="$(bash -c ". '$common'; reject_args foo" 2>&1)"
assert_contains "$err" "不收參數" "拒絕時說明原因"

# ── die ──
out="$(bash -c ". '$common'; die 壞了" 2>&1)"; rc=$?
assert_contains "$out" "壞了" "die 印出訊息"
assert_status 1 "die 以 1 結束" bash -c ". '$common'; die x"

# ── valid_ipv4（PR-NET-02、PR-COM-10）──
for ip in 0.0.0.0 1.2.3.4 192.168.1.100 255.255.255.255 10.0.0.1; do
    assert_status 0 "合法 IPv4：$ip" valid_ipv4 "$ip"
done
for ip in "" 256.1.1.1 1.2.3 1.2.3.4.5 1.2.3.04 01.2.3.4 a.b.c.d 1.2.3.4/24 " 1.2.3.4" "1.2.3.4 " 1..3.4 -1.2.3.4 1.2.3.999; do
    assert_nonzero "非法 IPv4：[$ip]" valid_ipv4 "$ip"
done

# ── ask_param（PR-COM-05）：值走 stdout、提示走 stderr ──
rm -f "$OPS_ENV_FILE"
v="$(echo "10.0.0.5" | ask_param NET_X "位址" "1.1.1.1" 2>/dev/null)"
assert_eq "10.0.0.5" "$v" "輸入新值則回傳新值"
assert_contains "$(cat "$OPS_ENV_FILE")" "NET_X=10.0.0.5" "答案存入參數檔"

v="$(echo "" | ask_param NET_X "位址" "1.1.1.1" 2>/dev/null)"
assert_eq "10.0.0.5" "$v" "Enter 沿用上次答案（優先於預設值）"

rm -f "$OPS_ENV_FILE"
v="$(echo "" | ask_param NET_Y "位址" "1.1.1.1" 2>/dev/null)"
assert_eq "1.1.1.1" "$v" "無舊值時 Enter 取預設值"

v="$(ask_param NET_Y "位址" "1.1.1.1" 2>/dev/null </dev/null)"
assert_eq "1.1.1.1" "$v" "stdin EOF 等同 Enter"

echo "a" | ask_param NET_Z "x" "" >/dev/null 2>&1
echo "b" | ask_param NET_Z "x" "" >/dev/null 2>&1
assert_eq "1" "$(grep -c '^NET_Z=' "$OPS_ENV_FILE")" "同一鍵重複寫入只留一行"
assert_contains "$(cat "$OPS_ENV_FILE")" "NET_Y=1.1.1.1" "其他鍵不受影響"

# 驗證函式：不合格重問，只存有效值
rm -f "$OPS_ENV_FILE"
v="$(printf 'bad\n300.1.1.1\n10.1.1.1\n' | ask_param NET_V "ip" "" valid_ipv4 2>/dev/null)"
assert_eq "10.1.1.1" "$v" "驗證不過就重問，直到合格"
assert_eq "NET_V=10.1.1.1" "$(grep '^NET_V=' "$OPS_ENV_FILE")" "只存合格的值"
rm -f "$OPS_ENV_FILE"
assert_nonzero "EOF 且仍不合格則回非 0" bash -c ". '$common'; ask_param K p '' valid_ipv4 </dev/null"
assert_eq "no" "$([ -f "$OPS_ENV_FILE" ] && echo yes || echo no)" "不合格時不建立參數檔"
assert_nonzero "拒絕不合法的鍵名" bash -c ". '$common'; echo x | ask_param 'a b' p"

# 參數檔不被當程式執行
printf 'NET_E=$(touch %s/pwned)\n' "$T_TMP" >"$OPS_ENV_FILE"
v="$(echo "" | ask_param NET_E "x" "" 2>/dev/null)"
assert_eq 'no' "$([ -e "$T_TMP/pwned" ] && echo yes || echo no)" "讀參數檔不會執行其內容"

# ── require_machine（PR-COM-04）：檢查走可覆寫的 have_cmd／gitlab_installed ──
# 在子 shell 內重新定義兩個探測函式，模擬各種機器。
rm_run() { # rm_run <有哪些指令，空白分隔> <有無 gitlab：yes|no> <require_machine 參數…>
    local have="$1" gl="$2"
    shift 2
    (
        have_cmd() { case " $have " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
        gitlab_installed() { [ "$gl" = yes ]; }
        require_machine "$@"
    ) 2>&1
}
out="$(rm_run "apt" no online)"
assert_eq "" "$out" "online：有 apt 即放行（無輸出）"
out="$(rm_run "" no online)" || true
assert_contains "$out" "【有網路的電腦】" "online：缺 apt 時指向有網路的電腦"
assert_nonzero "online：缺 apt 時中止" rm_run "" no online

assert_status 0 "server：有 apt 與 gitlab 放行" rm_run "apt" yes server
assert_nonzero "server：缺 /opt/gitlab 中止" rm_run "apt" no server
out="$(rm_run "apt" no server)" || true
assert_contains "$out" "【GitLab 伺服器】" "server：缺 gitlab 時指向 GitLab 伺服器"
assert_nonzero "server：缺 apt 中止" rm_run "" yes server

assert_status 0 "ubuntu：只要有 apt，不要求 /opt/gitlab" rm_run "apt" no ubuntu
out="$(rm_run "" no ubuntu)" || true
assert_contains "$out" "【GitLab 伺服器】" "ubuntu：缺 apt 時說明該在 GitLab 伺服器執行"
assert_contains "$out" "尚未安裝" "ubuntu：說明 GitLab 可能尚未安裝"
assert_status 0 "ubuntu：額外指令齊備放行" rm_run "apt netplan ip" no ubuntu netplan ip
out="$(rm_run "apt ip" no ubuntu netplan ip)" || true
assert_contains "$out" "netplan" "ubuntu：缺額外指令時點名該指令"
assert_nonzero "未知角色中止" rm_run "apt" yes bogus

# 預設的 have_cmd／gitlab_installed 走真實 PATH 與 GITLAB_OPT_DIR
assert_status 0 "have_cmd 找得到 bash" have_cmd bash
assert_nonzero "have_cmd 找不到不存在的指令" have_cmd no-such-cmd-xyz
mkdir "$T_TMP/optgl"
assert_status 0 "gitlab_installed 看 GITLAB_OPT_DIR" env GITLAB_OPT_DIR="$T_TMP/optgl" bash -c ". '$common'; gitlab_installed"
assert_nonzero "GITLAB_OPT_DIR 不存在即未安裝" env GITLAB_OPT_DIR="$T_TMP/none" bash -c ". '$common'; gitlab_installed"

# ── require_root：測試入口 OPS_FAKE_UID ──
assert_status 0 "uid 0 放行" env OPS_FAKE_UID=0 bash -c ". '$common'; require_root"
assert_nonzero "非 root 中止" env OPS_FAKE_UID=1000 bash -c ". '$common'; require_root"
out="$(OPS_FAKE_UID=1000 bash -c ". '$common'; require_root" 2>&1)" || true
assert_contains "$out" "sudo" "非 root 時提示用 sudo"

# ── menu_loop（PR-COM-01 選單骨架）──
menu_run() { # menu_run <stdin 內容>：假的 show_menu／dispatch，dispatch 把選項記進檔案
    printf '%b' "$1" | bash -c "
        . '$common'
        show_menu() { echo '== 選單 =='; }
        dispatch() { echo \"\$1\" >>'$T_TMP/dispatched'; [ \"\$1\" = boom ] && die 動作壞了; [ \"\$1\" = done ] && echo 完成動作; return 0; }
        menu_loop
    " 2>&1
}
rm -f "$T_TMP/dispatched"
out="$(menu_run '1\n2\nq\n')"; rc=$?
assert_eq "1 2" "$(tr '\n' ' ' <"$T_TMP/dispatched" | sed 's/ $//')" "依序把選項交給 dispatch"
assert_contains "$out" "== 選單 ==" "每輪顯示選單"
assert_status 0 "q 離開結束碼 0" bash -c "printf 'q\n' | bash -c \". '$common'; show_menu() { :; }; dispatch() { :; }; menu_loop\""
assert_status 0 "stdin EOF 離開結束碼 0" bash -c "bash -c \". '$common'; show_menu() { :; }; dispatch() { :; }; menu_loop\" </dev/null"
rm -f "$T_TMP/dispatched"
out="$(menu_run 'boom\ndone\nq\n')"
assert_contains "$out" "動作壞了" "動作內 die 顯示訊息"
assert_contains "$out" "完成動作" "動作內 die 後選單繼續，下一項照跑"

# menu_loop 不改變呼叫端原本的 -e 狀態
out="$(printf '1\nq\n' | bash -c ". '$common'; show_menu() { :; }; dispatch() { :; }; menu_loop >/dev/null; case \$- in *e*) echo has-e ;; *) echo no-e ;; esac")"
assert_eq "no-e" "$out" "menu_loop 結束後不替呼叫端打開 set -e"

# ── 參數檔不進版控 ──
repo="$(cd "$here/../.." && pwd)"
assert_status 0 "scripts/gitlab-ops.env 已列入 .gitignore" git -C "$repo" check-ignore -q scripts/gitlab-ops.env

# ── valid_cert_host／cert_san_type（PR-COM-09、10）──
for h in 192.168.9.129 10.0.0.1 gitlab.example.com gitlab host-1.lan A1; do assert_status 0 "憑證主機合法：$h" valid_cert_host "$h"; done
for h in "" 999.1.1.1 1.2.3 1.2.3.4.5 01.2.3.4 -bad bad- "a b" 'a;b' 'a$(id)' a/b ../x "a,b" "a:443" "*.example.com" ; do
    assert_nonzero "憑證主機非法：[$h]" valid_cert_host "$h"
done
assert_eq "IP" "$(cert_san_type 192.168.9.129)" "IPv4 → IP"
assert_eq "DNS" "$(cert_san_type gitlab.example.com)" "網域 → DNS"
assert_eq "DNS" "$(cert_san_type gitlab)" "單一主機名 → DNS"
assert_nonzero "非法主機：cert_san_type 失敗" cert_san_type "999.1.1.1"
assert_eq "" "$(cert_san_type 'a b' 2>/dev/null)" "非法主機：不輸出"

# ── make_self_signed_cert：用真的 openssl 產生，再讀回憑證驗證 SAN ──
if have_cmd openssl; then
    cdir="$T_TMP/ssl"
    make_self_signed_cert 192.168.9.129 "$cdir" </dev/null >/dev/null
    assert_eq "yes" "$([ -f "$cdir/192.168.9.129.crt" ] && [ -f "$cdir/192.168.9.129.key" ] && echo yes || echo no)" "IP 憑證：.crt／.key 檔名沿用主機"
    txt="$(openssl x509 -in "$cdir/192.168.9.129.crt" -noout -text)"
    assert_contains "$txt" "IP Address:192.168.9.129" "IP 憑證：SAN 為 IP Address"
    assert_not_contains "$txt" "DNS:192.168.9.129" "IP 憑證：SAN 不是 DNS"
    assert_contains "$txt" "CN = 192.168.9.129" "IP 憑證：CN 為主機"
    assert_eq "600" "$(stat -c %a "$cdir/192.168.9.129.key")" "私鑰權限 600"
    # 效期約 10 年（3650 天）
    assert_status 0 "效期至少 3600 天" openssl x509 -in "$cdir/192.168.9.129.crt" -noout -checkend $((3600 * 86400))
    make_self_signed_cert gitlab.example.com "$cdir" </dev/null >/dev/null
    txt="$(openssl x509 -in "$cdir/gitlab.example.com.crt" -noout -text)"
    assert_contains "$txt" "DNS:gitlab.example.com" "網域憑證：SAN 為 DNS"
    assert_not_contains "$txt" "IP Address:" "網域憑證：SAN 不是 IP"
    # 私鑰與憑證成對
    assert_eq "$(openssl x509 -in "$cdir/gitlab.example.com.crt" -noout -pubkey)" "$(openssl pkey -in "$cdir/gitlab.example.com.key" -pubout)" "私鑰與憑證成對"
    # 非互動：stdin 關閉也不卡、不提問
    assert_status 0 "stdin 關閉也能產生（不互動）" bash -c ". '$common'; make_self_signed_cert 10.0.0.1 '$cdir' </dev/null"
    # 非法主機：不產生任何檔案
    assert_nonzero "非法主機：不產生憑證" make_self_signed_cert "a;b" "$cdir"
    assert_eq "no" "$([ -e "$cdir/a;b.crt" ] && echo yes || echo no)" "非法主機：沒有檔案"
    # 預設目錄走 GITLAB_SSL_DIR
    GITLAB_SSL_DIR="$T_TMP/ssl2" make_self_signed_cert 10.1.1.1 </dev/null >/dev/null
    assert_eq "yes" "$([ -f "$T_TMP/ssl2/10.1.1.1.crt" ] && echo yes || echo no)" "預設目錄取 GITLAB_SSL_DIR"
fi
