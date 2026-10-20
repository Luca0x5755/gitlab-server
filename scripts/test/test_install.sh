#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# install.sh 的純函式（接縫 B）與行程層級行為（接縫 C）。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
inst="$here/../install.sh"
repo="$(cd "$here/../.." && pwd)"
bs=$'\x5c'   # 反斜線：避免原始碼中的跳脫被多層解讀

# source 取得函式：main 守門，source 時不啟動選單、不改選項。
. "$inst"

# ══ 接縫 B：純函式 ════════════════════════════════════════════════════════════

# ── .gitignore 擋 .deb（下載的大檔不得進版控）──
assert_status 0 ".gitignore 擋 *.deb" git -C "$repo" check-ignore -q some/gitlab-ce_1.0.0-ce.0_amd64.deb

# ── valid_gitlab_version ──
for v in 18.7.6-ce.0 17.11.2-ce.1 9.0.0-ce.0; do assert_status 0 "合法版本：$v" valid_gitlab_version "$v"; done
for v in "" latest 18.7.6 "18.7.6-ce.0 " " 18.7.6-ce.0" "18.7.6-ce.0=x" "18.7.6-ce.0;ls" '18.7.6-ce.0$(id)' '18.7.6-ce.0`id`' 18.7.6-ee.0 "-18.7.6-ce.0" 18.7-ce.0; do
    assert_nonzero "非法版本：[$v]" valid_gitlab_version "$v"
done

# ── parse_madison：真實 apt-cache madison 格式；行刻意亂序；保留輸入順序、去重 ──
cat >"$T_TMP/madison.txt" <<'TXT'
 gitlab-ce | 18.7.6-ce.0 | https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu noble/main amd64 Packages
 gitlab-ce | 17.11.2-ce.0 | https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu noble/main amd64 Packages
 gitlab-ce | 18.10.0-ce.0 | https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu noble/main amd64 Packages

 gitlab-ce | 18.7.6-ce.0 | https://mirror.example.com/gitlab-ce/ubuntu noble/main amd64 Packages
 gitlab-ee | 18.9.0-ee.0 | https://packages.gitlab.com/gitlab/gitlab-ee/ubuntu noble/main amd64 Packages
 gitlab-ce | 18.7.10-ce.0 | https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu noble/main amd64 Packages
E: some unrelated line
TXT
assert_eq $'18.7.6-ce.0\n17.11.2-ce.0\n18.10.0-ce.0\n18.7.10-ce.0' "$(parse_madison <"$T_TMP/madison.txt")" "parse_madison：保留輸入順序、去重、略過 gitlab-ee 與雜行"
assert_eq "" "$(parse_madison </dev/null)" "parse_madison：空輸入"
assert_eq $'18.10.0-ce.0\n18.7.10-ce.0\n18.7.6-ce.0\n17.11.2-ce.0' "$(parse_madison <"$T_TMP/madison.txt" | sort_versions desc)" "接 sort_versions desc 得到新到舊"

# ── deb_filename／deb_version ──
assert_eq "gitlab-ce_18.7.6-ce.0_amd64.deb" "$(deb_filename 18.7.6-ce.0 amd64)" "deb_filename amd64"
assert_eq "gitlab-ce_18.7.6-ce.0_arm64.deb" "$(deb_filename 18.7.6-ce.0 arm64)" "deb_filename 不硬編碼 amd64"
assert_nonzero "deb_filename 版本不合法" deb_filename "bad version" amd64
assert_eq "18.7.6-ce.0" "$(deb_version gitlab-ce_18.7.6-ce.0_amd64.deb)" "deb_version 取版本"
assert_eq "18.7.6-ce.0" "$(deb_version /home/u/dl/gitlab-ce_18.7.6-ce.0_arm64.deb)" "deb_version 取 basename"
for n in gitlab-ee_18.7.6-ee.0_amd64.deb nginx_1.26.0-1_amd64.deb foo.deb gitlab-ce_18.7.6_amd64.deb gitlab-ce_18.7.6-ce.0_amd64.deb.bak "gitlab-ce_18.7.6-ce.0_amd64.deb;x" ""; do
    assert_nonzero "deb_version 拒絕：[$n]" deb_version "$n"
done

# ── os_codename／check_repo_platform：真實 Ubuntu 24.04 /etc/os-release 樣本 ──
cat >"$T_TMP/os-release" <<'TXT'
PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.1 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
UBUNTU_CODENAME=noble
LOGO=ubuntu-logo
TXT
export OS_RELEASE_FILE="$T_TMP/os-release"
assert_eq "noble" "$(os_codename)" "os_codename 取 VERSION_CODENAME（不是 UBUNTU_CODENAME 以外的行）"
sed 's/^VERSION_CODENAME=.*/VERSION_CODENAME="jammy"/' "$T_TMP/os-release" >"$T_TMP/os-release-jammy"
assert_eq "jammy" "$(OS_RELEASE_FILE="$T_TMP/os-release-jammy" os_codename)" "os_codename 去掉引號"
assert_eq "" "$(OS_RELEASE_FILE="$T_TMP/none" os_codename)" "os_codename：檔案不存在回空"
deb_arch() { echo amd64; }
assert_status 0 "noble＋amd64：放行，不問" bash -c ". '$inst'; OS_RELEASE_FILE='$OS_RELEASE_FILE'; export OS_RELEASE_FILE; deb_arch() { echo amd64; }; check_repo_platform </dev/null"
chk_plat() { # chk_plat <os-release 檔> <架構> <stdin 內容>
    printf '%s' "$3" | OS_RELEASE_FILE="$1" bash -c ". '$inst'; deb_arch() { echo $2; }; check_repo_platform"
}
assert_nonzero "jammy 且 EOF：中止" chk_plat "$T_TMP/os-release-jammy" amd64 ""
assert_status 0 "jammy 且回答 yes：放行" chk_plat "$T_TMP/os-release-jammy" amd64 "yes
"
assert_nonzero "arm64 且 EOF：中止" chk_plat "$T_TMP/os-release" arm64 ""
assert_status 0 "arm64 且回答 yes：放行" chk_plat "$T_TMP/os-release" arm64 "yes
"
out="$(chk_plat "$T_TMP/os-release-jammy" amd64 "" 2>&1)" || true
assert_contains "$out" "noble" "不符時說明應為 noble"

# ── scp／路徑驗證（白名單）──
for u in luca deploy_1 a.b-c _svc; do assert_status 0 "合法 user：$u" valid_scp_user "$u"; done
for u in "" -oProxy 1abc "a b" 'a;b' 'a$b' "a'b" 'a@b' 'a:b'; do assert_nonzero "非法 user：[$u]" valid_scp_user "$u"; done
for h in 192.168.9.129 gitlab-srv gitlab.example.com a1; do assert_status 0 "合法 host：$h" valid_scp_host "$h"; done
for h in "" -oProxyCommand=x 300.1.1.1 1.2.3 "a b" 'a;b' 'a$b' "a'b" .example.com example.com. 'a:b' 'a/b'; do assert_nonzero "非法 host：[$h]" valid_scp_host "$h"; done
# shellcheck disable=SC2088  # '~/' 是刻意的字面值：遠端目錄交給 scp 在遠端展開
for d in '~/' '~' /home/luca /srv/gl-debs ./x a/b.c; do assert_status 0 "合法遠端目錄：$d" valid_remote_dir "$d"; done
for d in "" -r "-oX=y" 'a b' 'a;b' 'a$b' 'a:b' "a'b" 'a"b'; do assert_nonzero "非法遠端目錄：[$d]" valid_remote_dir "$d"; done
for p in /home/luca/dl /tmp/gitlab-ce_18.7.6-ce.0_amd64.deb /; do assert_status 0 "合法本機路徑：$p" valid_local_path "$p"; done
# shellcheck disable=SC2088  # '~/dl' 是刻意的字面值：本機路徑不得以 ~ 開頭
for p in "" dl ./dl ../dl -oX /tmp/a:b host:/tmp/x "/tmp/a b" '/tmp/a;b' '/tmp/$x' "/tmp/a'b" '~/dl'; do assert_nonzero "非法本機路徑：[$p]" valid_local_path "$p"; done
assert_status 0 "下載目錄：絕對路徑合法" valid_download_dir /home/luca/gitlab-debs
assert_nonzero "下載目錄：相對路徑拒絕" valid_download_dir gitlab-debs

# ── valid_external_url／render_external_url ──
for u in http://192.168.9.129 https://192.168.9.129 http://gitlab.example.com https://gitlab.example.com:8443 http://10.0.0.5:80 http://h:65535; do
    assert_status 0 "合法 external_url：$u" valid_external_url "$u"
done
for u in "" 192.168.9.129 ftp://1.2.3.4 http:// http://1.2.3.4/ http://1.2.3.4/path "http://1.2.3.4 " "http://a b" "http://1.2.3.4'" 'http://1.2.3.4"' 'http://1.2.3.4;ls' http://300.1.1.1 http://1.2.3.4:0 http://1.2.3.4:65536 http://1.2.3.4:abc http://-bad.com 'http://a$b' "http://user@1.2.3.4" http://1.2.3.4: ; do
    assert_nonzero "非法 external_url：[$u]" valid_external_url "$u"
done
assert_eq "external_url 'http://192.168.9.129'" "$(render_external_url http://192.168.9.129)" "render_external_url"
assert_nonzero "render_external_url 拒絕非法" render_external_url "http://a'b"

# ── extract_initial_password：官方文件格式的 initial_root_password ──
pw='aB+c/d=e&f'"$bs"'g|h'
{
    cat <<'TXT'
# WARNING: This value is valid only in the following conditions
#          1. If provided manually (either via `GITLAB_ROOT_PASSWORD` environment variable or via `gitlab_rails['initial_root_password']` setting in `gitlab.rb`, it was provided before database was seeded for the first time (usually, the first reconfigure run).
#          2. Password hasn't been changed manually, either via UI or via command line.
#
#          If the password shown here doesn't work, you must reset the admin password following https://docs.gitlab.com/ee/security/reset_user_password.html#reset-your-root-password.

TXT
    printf 'Password: %s\n' "$pw"
    printf '\n# NOTE: This file will be automatically deleted in the first reconfigure run after 24 hours.\n'
} >"$T_TMP/initial_root_password"
assert_eq "$pw" "$(extract_initial_password "$T_TMP/initial_root_password")" "取出含 + / = & 反斜線 | 的密碼，逐字不變"
printf '# only comments\n# Password: not-this-one\n' >"$T_TMP/pw_none"
assert_nonzero "沒有 Password 行：非 0" extract_initial_password "$T_TMP/pw_none"
assert_eq "" "$(extract_initial_password "$T_TMP/pw_none" 2>/dev/null)" "沒有 Password 行：不輸出"
printf 'Password: \n' >"$T_TMP/pw_empty"
assert_nonzero "Password 值為空：非 0" extract_initial_password "$T_TMP/pw_empty"
assert_nonzero "檔案不存在：非 0" extract_initial_password "$T_TMP/nope"

# ══ 接縫 C：行程層級（PATH stub 沙盒）═════════════════════════════════════════
# 這只證明「腳本在什麼條件下以什麼參數呼叫什麼」，不證明真實 apt／dpkg／scp／reconfigure 的行為。
RB_DEFAULT="$T_TMP/default.rb"
cat >"$RB_DEFAULT" <<'RB'
## GitLab configuration settings
external_url 'GENERATED_EXTERNAL_URL'
# gitlab_rails['ldap_enabled'] = false
# nginx['enable'] = true
RB

setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/opt" "$SB/home" "$SB/tmp" "$SB/dl"
    STUB_LOG="$SB/stub.log"
    SNAP="$SB/snap"
    : >"$STUB_LOG"
    export STUB_LOG SNAP
    cp "$RB_DEFAULT" "$SB/gitlab.rb"
    cp "$SB/gitlab.rb" "$SB/gitlab.rb.orig"
    cp "$T_TMP/os-release" "$SB/os-release"
    cp "$T_TMP/madison.txt" "$SB/madison.txt"
    rm -f "$OPS_ENV_FILE"
    make_stub "$SB/bin" apt-cache 'if [ "$1 $2" = "madison gitlab-ce" ]; then cat "'"$SB"'/madison.txt"; fi'
    make_stub "$SB/bin" apt 'if [ "$1" = download ]; then [ -n "${STUB_APT_NOFILE:-}" ] || : >"gitlab-ce_${2#*=}_amd64.deb"; fi; exit 0'
    make_stub "$SB/bin" curl '[ "${STUB_CURL_RC:-0}" -eq 0 ] || exit "$STUB_CURL_RC"; echo "echo STUB-REPO-SCRIPT-RAN >>\"\$STUB_LOG\""'
    make_stub "$SB/bin" scp 'exit "${STUB_SCP_RC:-0}"'
    make_stub "$SB/bin" dpkg 'if [ "$1" = "--print-architecture" ]; then echo "${STUB_ARCH:-amd64}"; fi; exit "${STUB_DPKG_RC:-0}"'
    make_stub "$SB/bin" gitlab-ctl 'if [ "$1" = reconfigure ]; then cp "$GITLAB_RB" "$SNAP"; exit "${STUB_RECONF_RC:-0}"; fi'
    make_stub "$SB/bin" chmod '[ -z "${STUB_CHMOD_FAIL:-}" ] || exit 1; exec /usr/bin/chmod "$@"'
}

# run_ins <stdin 內容> [環境變數 KEY=VAL…]：在沙盒中執行 install.sh（無參數），stdin 一律顯式給。
run_ins() {
    local input="$1"
    shift
    printf '%b' "$input" | env PATH="$SB/bin:$PATH" GITLAB_RB="$SB/gitlab.rb" GITLAB_INITIAL_PW="$SB/initial_root_password" \
        GITLAB_OPT_DIR="$SB/opt" OS_RELEASE_FILE="$SB/os-release" OPS_FAKE_UID=0 HOME="$SB/home" TMPDIR="$SB/tmp" \
        "$@" bash "$inst" 2>&1
}
log_has() { grep -qF -- "$1" "$STUB_LOG"; }
count_log() { grep -cE -- "$1" "$STUB_LOG" || true; }

setup_sandbox menu

# ── C-1 無參數（PR-COM-01）──
assert_status 2 "帶參數即拒絕" env PATH="$SB/bin:$PATH" bash "$inst" foo
assert_status 2 "空字串參數也拒絕" env PATH="$SB/bin:$PATH" bash "$inst" ""
assert_status 2 "多個參數也拒絕" env PATH="$SB/bin:$PATH" bash "$inst" -h --help
assert_status 0 "q 離開結束碼 0" bash -c "printf 'q\n' | env PATH='$SB/bin:$PATH' bash '$inst'"
assert_status 0 "stdin EOF 離開結束碼 0" bash -c "env PATH='$SB/bin:$PATH' bash '$inst' </dev/null"

# ── C-2 選單標示、說明、排查（PR-COM-04、11）──
menu="$(run_ins 'q\n')"
assert_contains "$menu" "說明" "選單含「說明」"
assert_contains "$menu" "常見問題排查" "選單含「常見問題排查」"
bad=0
while IFS= read -r line; do
    [[ $line =~ ^\ +[0-9]+\) ]] || continue
    [[ $line == *"說明"* || $line == *"常見問題排查"* ]] && continue
    [[ $line == *"【有網路的電腦】"* || $line == *"【GitLab 伺服器】"* ]] || { bad=1; echo "未標示：$line" >&2; }
done <<<"$menu"
assert_eq "0" "$bad" "每個動作項目都標示機器"
assert_contains "$menu" "【有網路的電腦】" "選單有【有網路的電腦】項目"
assert_contains "$menu" "【GitLab 伺服器】" "選單有【GitLab 伺服器】項目"
help="$(run_ins '8\nq\n')"
for k in "Ubuntu 24.04" Noble "apt download" scp "24 小時" initial_root_password reconfigure dpkg; do
    assert_contains "$help" "$k" "說明含：$k"
done
fix="$(run_ins '9\nq\n')"
for k in 相依 備份 initial_root_password reconfigure noble; do
    assert_contains "$fix" "$k" "排查含：$k"
done

# ── C-3 機器檢查：缺指令靠覆寫 have_cmd 模擬，不靠空 PATH ──
chk() { # chk <有哪些指令> <gitlab 已裝? 0|1> <函式> [參數…]
    local have_list="$1" gl="$2"
    shift 2
    (
        have_cmd() { case " $have_list " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
        if [ "$gl" = 1 ]; then gitlab_installed() { return 0; }; else gitlab_installed() { return 1; }; fi
        "$@"
    ) 2>&1
}
assert_status 0 "線上機器：apt curl 齊備放行" chk "apt curl" 0 ins_require_online curl
out="$(chk "apt" 0 ins_require_online curl)" || true
assert_contains "$out" "curl" "缺 curl 時點名"
assert_contains "$out" "【有網路的電腦】" "缺 curl 時指向【有網路的電腦】"
out="$(chk "curl" 0 ins_require_online curl)" || true
assert_contains "$out" "【有網路的電腦】" "缺 apt 時指向【有網路的電腦】"
out="$(chk "apt curl apt-cache" 0 ins_require_online scp)" || true
assert_contains "$out" "scp" "缺 scp 時點名"
assert_contains "$out" "【有網路的電腦】" "缺 scp 時指向【有網路的電腦】"
assert_status 0 "安裝：apt＋dpkg 齊備、未裝 GitLab 也放行" chk "apt dpkg" 0 ins_require_install_host
out="$(chk "apt" 0 ins_require_install_host)" || true
assert_contains "$out" "dpkg" "缺 dpkg 時點名"
assert_contains "$out" "【GitLab 伺服器】" "缺 dpkg 時指向【GitLab 伺服器】"
assert_status 0 "已裝 GitLab 的伺服器放行" chk "apt" 1 ins_require_gitlab_host
out="$(chk "apt" 0 ins_require_gitlab_host)" || true
assert_contains "$out" "【GitLab 伺服器】" "未裝 GitLab：指向【GitLab 伺服器】"

# ── C-4 下載（PR-INS-01）──
URL="https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh"
setup_sandbox repo_yes
out="$(run_ins '1\nyes\nq\n')"
assert_eq "yes" "$(log_has "curl -fsSL $URL" && echo yes || echo no)" "加來源：curl 取得官方 script.deb.sh"
assert_eq "yes" "$(log_has "STUB-REPO-SCRIPT-RAN" && echo yes || echo no)" "加來源：curl 的輸出交給 bash 執行"
assert_contains "$out" "$URL" "加來源：確認前印出完整 URL"
assert_contains "$out" "已加入" "加來源成功：有成功訊息"
assert_not_contains "$(cat "$STUB_LOG")" "sudo" "已是 root，不用 sudo bash"
setup_sandbox repo_no
out="$(run_ins '1\nno\nq\n')"
assert_eq "0" "$(count_log '^curl ')" "加來源回答 no：curl 沒被呼叫"
setup_sandbox repo_eof
out="$(run_ins '1\n')"
assert_eq "0" "$(count_log '^curl ')" "加來源遇 EOF：curl 沒被呼叫"
setup_sandbox repo_fail
out="$(run_ins '1\nyes\nq\n' STUB_CURL_RC=22)"
assert_contains "$out" "動作未完成" "curl 失敗：整體動作失敗（pipefail 有效）"
assert_not_contains "$out" "已加入" "curl 失敗：不宣稱來源已加入"
assert_eq "no" "$(log_has STUB-REPO-SCRIPT-RAN && echo yes || echo no)" "curl 失敗：沒有東西被執行"
setup_sandbox repo_nonroot
out="$(run_ins '1\nyes\nq\n' OPS_FAKE_UID=1000)"
assert_eq "0" "$(count_log '^curl ')" "非 root：curl 沒被呼叫"
assert_contains "$out" "root" "非 root：提示需要 root"
setup_sandbox repo_jammy
cp "$T_TMP/os-release-jammy" "$SB/os-release"
out="$(run_ins '1\nno\nq\n')"
assert_eq "0" "$(count_log '^curl ')" "發行版不是 noble 且未確認：curl 沒被呼叫"
assert_contains "$out" "noble" "發行版不符：說明以 noble 為準"
setup_sandbox repo_arm
out="$(run_ins '1\nq\n' STUB_ARCH=arm64)"
assert_eq "0" "$(count_log '^curl ')" "架構不是 amd64 且 EOF：curl 沒被呼叫"

setup_sandbox list
out="$(run_ins '2\nq\n')"
assert_contains "$(cat "$STUB_LOG")" "apt-cache madison gitlab-ce" "列版本：呼叫 apt-cache madison gitlab-ce"
assert_eq $'18.10.0-ce.0\n18.7.10-ce.0\n18.7.6-ce.0\n17.11.2-ce.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-ce\.[0-9]+' <<<"$out")" "列版本：新到舊"

setup_sandbox dl
out="$(run_ins "3\n$SB/dl\n18.7.6-ce.0\nq\n")"
assert_eq "yes" "$(log_has "apt download gitlab-ce=18.7.6-ce.0" && echo yes || echo no)" "下載：apt download gitlab-ce=<版本>"
assert_eq "yes" "$([ -f "$SB/dl/gitlab-ce_18.7.6-ce.0_amd64.deb" ] && echo yes || echo no)" "下載：.deb 在指定的下載目錄"
assert_contains "$(cat "$OPS_ENV_FILE")" "INS_VERSION=18.7.6-ce.0" "下載：版本存入參數檔"
assert_contains "$(cat "$OPS_ENV_FILE")" "INS_DOWNLOAD_DIR=$SB/dl" "下載：目錄存入參數檔"
setup_sandbox dl_badver
out="$(run_ins "3\n$SB/dl\nlatest\n18.7.6-ce.0;touch /tmp/x\nq\n")"
assert_eq "0" "$(count_log '^apt download')" "版本不合法：apt download 完全沒被呼叫"
setup_sandbox dl_reldir
out="$(run_ins "3\nrelative/dir\n18.7.6-ce.0\nq\n")"
assert_eq "0" "$(count_log '^apt download')" "下載目錄非絕對路徑：apt download 沒被呼叫"
setup_sandbox dl_nofile
out="$(run_ins "3\n$SB/dl\n18.7.6-ce.0\nq\n" STUB_APT_NOFILE=1)"
assert_contains "$out" "動作未完成" "下載後 .deb 不存在：動作失敗"

# ── C-5 傳送（PR-INS-02）──
setup_sandbox scp_ok
: >"$SB/dl/gitlab-ce_18.7.6-ce.0_amd64.deb"
out="$(run_ins "4\n$SB/dl/gitlab-ce_18.7.6-ce.0_amd64.deb\nluca\n192.168.9.129\n~/\nq\n")"
assert_eq "yes" "$(log_has "scp -- $SB/dl/gitlab-ce_18.7.6-ce.0_amd64.deb luca@192.168.9.129:~/" && echo yes || echo no)" "scp 以 -- 分隔、參數完整正確"
env_text="$(cat "$OPS_ENV_FILE")"
assert_contains "$env_text" "INS_SERVER_HOST=192.168.9.129" "答案存入參數檔"
assert_not_contains "$env_text" "assword" "參數檔不含任何密碼欄位"
setup_sandbox scp_nofile
out="$(run_ins "4\n$SB/dl/none.deb\nluca\n192.168.9.129\n~/\nq\n")"
assert_eq "0" "$(count_log '^scp ')" "來源檔不存在：scp 沒被呼叫"
for row in "host:/tmp/a.deb|luca|1.2.3.4|~/" "relative.deb|luca|1.2.3.4|~/" "-oX|luca|1.2.3.4|~/"; do
    IFS='|' read -r p u h d <<<"$row"
    setup_sandbox scp_badpath
    out="$(run_ins "4\n$p\n$u\n$h\n$d\n")"
    assert_eq "0" "$(count_log '^scp ')" "本機路徑 [$p]：scp 沒被呼叫"
done
for row in "-oProxyCommand=x|1.2.3.4|~/" "luca|-oBad|~/" "luca|1.2.3.4|-r" "luca|1.2.3.4|a:b" "luca|300.1.1.1|~/"; do
    IFS='|' read -r u h d <<<"$row"
    setup_sandbox scp_baddest
    : >"$SB/dl/gitlab-ce_18.7.6-ce.0_amd64.deb"
    out="$(run_ins "4\n$SB/dl/gitlab-ce_18.7.6-ce.0_amd64.deb\n$u\n$h\n$d\n")"
    assert_eq "no" "$(log_has "$u@$h:$d" && echo yes || echo no)" "非法目的地 [$u|$h|$d]：scp 絕不帶著它被呼叫（重問後吃預設值是安全的）"
done
setup_sandbox scp_notdeb
: >"$SB/dl/random.txt"
out="$(run_ins "4\n$SB/dl/random.txt\nluca\n1.2.3.4\n~/\nq\n")"
assert_eq "0" "$(count_log '^scp ')" "檔名不是 gitlab-ce .deb：scp 沒被呼叫"

# ── C-6 安裝（PR-INS-03）──
GOODDEB="gitlab-ce_18.7.6-ce.0_amd64.deb"
setup_sandbox inst_ok
rmdir "$SB/opt"
: >"$SB/dl/$GOODDEB"
out="$(run_ins "5\n$SB/dl/$GOODDEB\nq\n")"
assert_eq "yes" "$(log_has "dpkg -i -- $SB/dl/$GOODDEB" && echo yes || echo no)" "安裝：dpkg -i -- <絕對路徑>"
setup_sandbox inst_missing
rmdir "$SB/opt"
out="$(run_ins "5\n$SB/dl/$GOODDEB\nq\n")"
assert_eq "0" "$(count_log '^dpkg -i')" "檔案不存在：dpkg -i 完全沒被呼叫"
assert_contains "$out" "動作未完成" "檔案不存在：動作失敗"
for p in "-rf" "dl/$GOODDEB" "./$GOODDEB"; do
    setup_sandbox inst_rel
    rmdir "$SB/opt"
    out="$(run_ins "5\n$p\nq\n")"
    assert_eq "0" "$(count_log '^dpkg -i')" "非絕對路徑 [$p]：dpkg -i 沒被呼叫"
done
setup_sandbox inst_wrongdeb
rmdir "$SB/opt"
: >"$SB/dl/gitlab-ee_18.7.6-ee.0_amd64.deb"
out="$(run_ins "5\n$SB/dl/gitlab-ee_18.7.6-ee.0_amd64.deb\nq\n")"
assert_eq "0" "$(count_log '^dpkg -i')" "不是 gitlab-ce 檔名：dpkg -i 沒被呼叫"
setup_sandbox inst_nonroot
rmdir "$SB/opt"
: >"$SB/dl/$GOODDEB"
out="$(run_ins "5\n$SB/dl/$GOODDEB\nq\n" OPS_FAKE_UID=1000)"
assert_eq "0" "$(count_log '^dpkg -i')" "非 root：dpkg -i 沒被呼叫"
setup_sandbox inst_again
: >"$SB/dl/$GOODDEB"   # opt 目錄存在＝已安裝 GitLab
out="$(run_ins "5\n$SB/dl/$GOODDEB\n")"
assert_eq "0" "$(count_log '^dpkg -i')" "已安裝且遇 EOF：dpkg -i 沒被呼叫"
assert_contains "$out" "upgrade.sh" "已安裝：指向 upgrade.sh"
setup_sandbox inst_again_yes
: >"$SB/dl/$GOODDEB"
out="$(run_ins "5\n$SB/dl/$GOODDEB\nyes\nq\n")"
assert_eq "yes" "$(log_has "dpkg -i -- $SB/dl/$GOODDEB" && echo yes || echo no)" "已安裝但確認 yes：照裝"
setup_sandbox inst_dpkgfail
rmdir "$SB/opt"
: >"$SB/dl/$GOODDEB"
out="$(run_ins "5\n$SB/dl/$GOODDEB\nq\n" STUB_DPKG_RC=1)"
assert_contains "$out" "動作未完成" "dpkg 失敗：動作失敗"

# ── C-7 external_url（PR-INS-04）──
setup_sandbox url_ok
out="$(run_ins '6\nhttp://192.168.9.129\nq\n')"
{ cat "$SB/gitlab.rb.orig"; printf '# >>> gitlab-ops:install_external_url BEGIN 腳本維護，重跑整段取代，請勿手改\nexternal_url '"'"'http://192.168.9.129'"'"'\n# <<< gitlab-ops:install_external_url END\n'; } >"$SB/want"
assert_file_eq "$SB/want" "$SB/gitlab.rb" "區塊追加在檔尾，區塊外 byte 不變（含預設的 GENERATED_EXTERNAL_URL 行）"
assert_file_eq "$SB/want" "$SNAP" "gitlab-ctl reconfigure 被呼叫當下 gitlab.rb 已含新區塊"
assert_eq "1" "$(count_log '^gitlab-ctl reconfigure')" "reconfigure 恰一次"
bak="$(ls "$SB"/gitlab.rb.bak-* | head -n1)"
assert_file_eq "$SB/gitlab.rb.orig" "$bak" "備份內容等於修改前"
assert_contains "$(cat "$STUB_LOG")" "chmod 600 $bak" "備份設為 600"
assert_contains "$(cat "$OPS_ENV_FILE")" "INS_EXTERNAL_URL=http://192.168.9.129" "網址存入參數檔"
out="$(run_ins '6\nhttp://192.168.9.129\n6\nhttp://192.168.9.129\nq\n')"
assert_file_eq "$SB/want" "$SB/gitlab.rb" "重跑兩次仍只有一段、內容相同"
assert_eq "1" "$(grep -c 'gitlab-ops:install_external_url BEGIN' "$SB/gitlab.rb")" "BEGIN 標記行恰 1 行"
setup_sandbox url_fail_yes
out="$(run_ins '6\nhttp://192.168.9.129\nyes\nq\n' STUB_RECONF_RC=1)"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "reconfigure 失敗＋yes：gitlab.rb 還原為原檔"
assert_eq "yes" "$(grep -q 'install_external_url' "$SNAP" && echo yes || echo no)" "失敗當下快照確實含新區塊（還原不是假的）"
assert_contains "$out" "動作未完成" "reconfigure 失敗：動作回報失敗"
setup_sandbox url_fail_eof
out="$(run_ins '6\nhttp://192.168.9.129\n' STUB_RECONF_RC=1)"
assert_eq "yes" "$(grep -q 'install_external_url' "$SB/gitlab.rb" && echo yes || echo no)" "reconfigure 失敗＋EOF：不還原"
setup_sandbox url_bad
out="$(run_ins "6\nhttp://1.2.3.4/path\nhttp://a'b\nq\n")"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "URL 不合法：gitlab.rb 不動"
assert_eq "0" "$(count_log '^gitlab-ctl')" "URL 不合法：不 reconfigure"
setup_sandbox url_nogl
rmdir "$SB/opt"
out="$(run_ins '6\nhttp://192.168.9.129\nq\n')"
assert_eq "0" "$(count_log '^gitlab-ctl')" "尚未安裝 GitLab：不 reconfigure"
assert_contains "$out" "【GitLab 伺服器】" "尚未安裝 GitLab：指向【GitLab 伺服器】"
setup_sandbox url_nonroot
out="$(run_ins '6\nhttp://192.168.9.129\nq\n' OPS_FAKE_UID=1000)"
assert_file_eq "$SB/gitlab.rb.orig" "$SB/gitlab.rb" "非 root：gitlab.rb 不動"

# ── C-8 初始密碼（PR-INS-05）──
setup_sandbox pw_ok
cp "$T_TMP/initial_root_password" "$SB/initial_root_password"
out="$(run_ins '7\nq\n')"
assert_contains "$out" "$pw" "顯示密碼，逐字不變（含 + / = & 反斜線 |）"
assert_contains "$out" "24 小時" "提醒 24 小時內修改"
assert_contains "$out" "root" "指出帳號 root"
assert_not_contains "$out" "reset the admin password" "只印密碼那一行，不傾倒整個檔案"
assert_not_contains "$(cat "$STUB_LOG")" "$pw" "stub 呼叫記錄不含密碼"
[ ! -f "$OPS_ENV_FILE" ] || assert_not_contains "$(cat "$OPS_ENV_FILE")" "$pw" "參數檔不含密碼"
setup_sandbox pw_unparsable
printf '# nothing useful\n' >"$SB/initial_root_password"
out="$(run_ins '7\nq\n')"
assert_contains "$out" "sudo cat $SB/initial_root_password" "解析不到：退回請 sudo cat 該檔"
assert_not_contains "$out" "動作未完成" "解析不到：不是錯誤，不 die"
setup_sandbox pw_gone
out="$(run_ins '7\nq\n')"
assert_contains "$out" "24" "檔案不存在：說明 24 小時後自動刪除"
assert_contains "$out" "gitlab:password:reset" "檔案不存在：給出重設密碼指引"
assert_not_contains "$out" "動作未完成" "檔案不存在：是正常情況，不算失敗"
setup_sandbox pw_nogl
rmdir "$SB/opt"
out="$(run_ins '7\nq\n')"
assert_contains "$out" "【GitLab 伺服器】" "尚未安裝 GitLab：指向【GitLab 伺服器】"
