#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012,SC2010,SC2030,SC2031
# nginx.sh 的純函式（接縫 A）、動作函式的結束碼與副作用（接縫 B）、選單行程（接縫 C）。
#
# 重要：本檔所有 fixture（apt-cache／dpkg／nginx -V 輸出）都是依 Ubuntu 24.04 的真實格式謄寫，
# 「非實機擷取」。待 Ubuntu VM 試跑時，請換成實機輸出再確認解析仍正確。
# 期望值一律寫死字面值，不呼叫被測函式產生。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
ngx="$here/../nginx.sh"

# source 取得函式：main 守門，source 時不啟動選單、不改選項。
. "$ngx"

# ── parse_dep_pkgs（PR-NGX-01）：解析 apt-cache depends --recurse ──
# 樣本含：縮排的相依行、替代相依 `|Depends`、虛擬套件 <debconf-2.0> 及其提供者縮排行、
# 其他架構 libc6:i386（原文件的 grep "^\w" 會放過它，本函式丟棄）。
cat >"$T_TMP/depends.txt" <<'TXT'
nginx
  Depends: libc6
  Depends: libcrypt1
  Depends: libpcre2-8-0
  Depends: libssl3t64
  Depends: zlib1g
  Depends: lsb-base
  Depends: adduser
  Depends: ucf
 |Depends: <debconf-2.0>
    cdebconf
    debconf
libc6
  Depends: libgcc-s1
libgcc-s1
  Depends: gcc-14-base
  Depends: libc6
gcc-14-base
libcrypt1
  Depends: libc6
libpcre2-8-0
  Depends: libc6
libssl3t64
  Depends: libc6
zlib1g
  Depends: libc6
libstdc++6
  Depends: libgcc-s1
lsb-base
adduser
  Depends: debconf
ucf
  Depends: debconf
<debconf-2.0>
    cdebconf
    debconf
debconf
cdebconf
libc6:i386
  Depends: libgcc-s1:i386
TXT
want=$'adduser\ncdebconf\ndebconf\ngcc-14-base\nlibc6\nlibcrypt1\nlibgcc-s1\nlibpcre2-8-0\nlibssl3t64\nlibstdc++6\nlsb-base\nnginx\nucf\nzlib1g'
assert_eq "$want" "$(parse_dep_pkgs <"$T_TMP/depends.txt")" "parse_dep_pkgs：只留實體套件名、排序去重、丟棄虛擬與其他架構"
assert_nonzero "parse_dep_pkgs：空輸入回非 0" bash -c ". '$ngx'; parse_dep_pkgs </dev/null"
assert_nonzero "parse_dep_pkgs：只有雜訊（無實體套件）回非 0" bash -c ". '$ngx'; printf '  Depends: x\n<v>\n' | parse_dep_pkgs"

# ── nginx_apt_source_line（PR-NGX-01）：預設 keyring 路徑下逐字等於 04 文件那一行 ──
unset NGX_KEYRING
assert_eq 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu noble nginx' \
    "$(nginx_apt_source_line noble)" "來源行逐字等於 04 文件"
assert_eq 'deb [signed-by=/tmp/k.gpg] http://nginx.org/packages/mainline/ubuntu noble nginx' \
    "$(NGX_KEYRING=/tmp/k.gpg nginx_apt_source_line noble)" "keyring 路徑可覆寫"

# ── os_codename：真實 Ubuntu 24.04 /etc/os-release 格式 ──
cat >"$T_TMP/os-release" <<'TXT'
PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.1 LTS (Noble Numbat)"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
UBUNTU_CODENAME=noble
TXT
assert_eq "noble" "$(OS_RELEASE_FILE="$T_TMP/os-release" os_codename)" "os_codename 讀 VERSION_CODENAME"
printf 'NAME="Ubuntu"\nVERSION_CODENAME=jammy\n' >"$T_TMP/os-release-j"
assert_eq "jammy" "$(OS_RELEASE_FILE="$T_TMP/os-release-j" os_codename)" "os_codename：jammy"
assert_eq "" "$(OS_RELEASE_FILE="$T_TMP/none" os_codename)" "os_codename：檔案不存在回空"

# ── parse_nginx_version（PR-NGX-02）：nginx -V 輸出（寫到 stderr，呼叫端要 2>&1）──
v_gitlab='nginx version: nginx/1.26.3
built by gcc 13.2.0 (Ubuntu 13.2.0-23ubuntu4)
built with OpenSSL 3.0.15 3 Sep 2024
TLS SNI support enabled
configure arguments: --prefix=/opt/gitlab/embedded --with-http_ssl_module'
assert_eq "1.26.3" "$(printf '%s\n' "$v_gitlab" | parse_nginx_version)" "parse_nginx_version：GitLab 內建樣本"
assert_eq "1.29.3" "$(printf 'nginx version: nginx/1.29.3\n' | parse_nginx_version)" "parse_nginx_version：nginx -v 單行"
assert_nonzero "parse_nginx_version：不是 nginx 輸出回非 0" bash -c ". '$ngx'; echo 'bash: nginx: command not found' | parse_nginx_version"
assert_nonzero "parse_nginx_version：空輸入回非 0" bash -c ". '$ngx'; parse_nginx_version </dev/null"

# ── candidate_from_nginx_org：apt-cache policy nginx（LC_ALL=C）──
pol_ok='nginx:
  Installed: (none)
  Candidate: 1.29.3-1~noble
  Version table:
     1.29.3-1~noble 500
        500 http://nginx.org/packages/mainline/ubuntu noble/nginx amd64 Packages
     1.24.0-2ubuntu7.5 500
        500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages
        500 http://security.ubuntu.com/ubuntu noble-security/main amd64 Packages
     1.24.0-2ubuntu7 500
        500 http://archive.ubuntu.com/ubuntu noble/main amd64 Packages'
assert_status 0 "候選來自 nginx.org（版本表第一列）" bash -c ". '$ngx'; printf '%s\n' '$pol_ok' | candidate_from_nginx_org"

pol_ubuntu='nginx:
  Installed: (none)
  Candidate: 1.24.0-2ubuntu7.5
  Version table:
     1.29.3-1~noble 100
        100 http://nginx.org/packages/mainline/ubuntu noble/nginx amd64 Packages
     1.24.0-2ubuntu7.5 500
        500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages
     1.24.0-2ubuntu7 500
        500 http://archive.ubuntu.com/ubuntu noble/main amd64 Packages'
assert_nonzero "候選來自 Ubuntu 自家 1.24（nginx.org 版本較高但優先序低）" bash -c ". '$ngx'; printf '%s\n' '$pol_ubuntu' | candidate_from_nginx_org"

pol_notfirst='nginx:
  Installed: (none)
  Candidate: 1.29.3-1~noble
  Version table:
     1.30.0-1ubuntu1 100
        100 http://archive.ubuntu.com/ubuntu noble-proposed/main amd64 Packages
     1.29.3-1~noble 900
        900 http://nginx.org/packages/mainline/ubuntu noble/nginx amd64 Packages
     1.24.0-2ubuntu7 500
        500 http://archive.ubuntu.com/ubuntu noble/main amd64 Packages'
assert_status 0 "候選不在版本表第一列，且來自 nginx.org" bash -c ". '$ngx'; printf '%s\n' '$pol_notfirst' | candidate_from_nginx_org"

pol_two='nginx:
  Installed: (none)
  Candidate: 1.29.3-1~noble
  Version table:
     1.29.3-1~noble 500
        500 http://mirror.example.lan/ubuntu noble/main amd64 Packages
        500 http://nginx.org/packages/mainline/ubuntu noble/nginx amd64 Packages
     1.24.0-2ubuntu7 500
        500 http://archive.ubuntu.com/ubuntu noble/main amd64 Packages'
assert_status 0 "同一版本兩個來源，其一為 nginx.org" bash -c ". '$ngx'; printf '%s\n' '$pol_two' | candidate_from_nginx_org"

pol_none='nginx:
  Installed: (none)
  Candidate: (none)
  Version table:'
assert_nonzero "沒有候選版本（Candidate: (none)）" bash -c ". '$ngx'; printf '%s\n' '$pol_none' | candidate_from_nginx_org"

pol_inst='nginx:
  Installed: 1.24.0-2ubuntu7
  Candidate: 1.24.0-2ubuntu7
  Version table:
 *** 1.24.0-2ubuntu7 500
        500 http://archive.ubuntu.com/ubuntu noble/main amd64 Packages
        100 /var/lib/dpkg/status
     1.29.3-1~noble 100
        100 http://nginx.org/packages/mainline/ubuntu noble/nginx amd64 Packages'
assert_nonzero "已安裝標記 *** 的列：候選 Ubuntu 版，後面列的 nginx.org 不算" bash -c ". '$ngx'; printf '%s\n' '$pol_inst' | candidate_from_nginx_org"

# ── dpkg -i 失敗輸出的解析（PR-NGX-02）──
cat >"$T_TMP/dpkg-dep.txt" <<'TXT'
Selecting previously unselected package nginx.
(Reading database ... 70123 files and directories currently installed.)
Preparing to unpack nginx_1.29.3-1~noble_amd64.deb ...
Unpacking nginx (1.29.3-1~noble) ...
dpkg: dependency problems prevent configuration of nginx:
 nginx depends on libssl3t64 (>= 3.0.0); however:
  Package libssl3t64 is not installed.
 nginx depends on libpcre2-8-0 (>= 10.22); however:
  Package libpcre2-8-0:amd64 is not installed.
 nginx depends on zlib1g (>= 1:1.2.0); however:
  Version of zlib1g:amd64 on system is 1:1.1.0.
 nginx depends on lsb-base; however:
  Package lsb-base is not configured yet.

dpkg: error processing package nginx (--install):
 dependency problems - leaving unconfigured
Errors were encountered while processing:
 nginx
TXT
cat >"$T_TMP/dpkg-port.txt" <<'TXT'
Preparing to unpack nginx_1.29.3-1~noble_amd64.deb ...
Unpacking nginx (1.29.3-1~noble) ...
Setting up nginx (1.29.3-1~noble) ...
nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address already in use)
dpkg: error processing package nginx (--configure):
 installed nginx package post-installation script subprocess returned error exit status 1
Errors were encountered while processing:
 nginx
 libfoo1:amd64
TXT
assert_eq $'nginx' "$(dpkg_failed_pkgs <"$T_TMP/dpkg-dep.txt")" "dpkg_failed_pkgs：相依錯誤樣本"
assert_eq $'nginx\nlibfoo1' "$(dpkg_failed_pkgs <"$T_TMP/dpkg-port.txt")" "dpkg_failed_pkgs：去掉 :amd64 後綴、多個套件"
assert_eq "" "$(printf 'Setting up nginx ...\n' | dpkg_failed_pkgs)" "dpkg_failed_pkgs：成功輸出回空"
assert_eq $'libpcre2-8-0\nlibssl3t64\nzlib1g' "$(dpkg_missing_deps <"$T_TMP/dpkg-dep.txt")" \
    "dpkg_missing_deps：not installed 與 Version of…on system，去 :amd64，排序；not configured yet 不算"
assert_eq "" "$(dpkg_missing_deps <"$T_TMP/dpkg-port.txt")" "dpkg_missing_deps：非相依錯誤（80 埠）回空"

# ══ pack_offline／check_offline_tar（PR-NGX-01／02）══
# 用真 tar 造各種壞包。造 ../x.deb 與絕對路徑用 --transform 搭配 -P。
mk="$T_TMP/mk"
mkdir -p "$mk/src"
printf 'deb-a' >"$mk/src/a.deb"
printf 'deb-b' >"$mk/src/nginx_1%3a1.29.3-1~noble_amd64.deb"
assert_status 0 "pack_offline：正常打包" pack_offline "$mk/src" "$mk/out/good.tar.gz"
assert_eq $'a.deb\nnginx_1%3a1.29.3-1~noble_amd64.deb' "$(tar tzf "$mk/out/good.tar.gz")" "pack_offline：tar 內是扁平檔名（含 %3a epoch 檔名）"
mkdir -p "$mk/x"
tar xzf "$mk/out/good.tar.gz" -C "$mk/x"
assert_file_eq "$mk/src/a.deb" "$mk/x/a.deb" "往返：a.deb byte 相同"
assert_file_eq "$mk/src/nginx_1%3a1.29.3-1~noble_amd64.deb" "$mk/x/nginx_1%3a1.29.3-1~noble_amd64.deb" "往返：epoch 檔名 byte 相同"
assert_eq "good.tar.gz" "$(ls "$mk/out")" "pack_offline：輸出目錄沒有殘留暫存檔"
assert_status 0 "check_offline_tar：自己打的包通過" check_offline_tar "$mk/out/good.tar.gz"

# 失敗保留舊輸出：來源目錄含不合白名單的檔名（有空白）
mkdir -p "$mk/badsrc"
printf 'x' >"$mk/badsrc/ok.deb"
printf 'x' >"$mk/badsrc/bad name.deb"
cp "$mk/out/good.tar.gz" "$mk/out/keep.tar.gz"
assert_nonzero "pack_offline：檔名不合白名單回非 0" pack_offline "$mk/badsrc" "$mk/out/keep.tar.gz"
assert_file_eq "$mk/out/good.tar.gz" "$mk/out/keep.tar.gz" "pack_offline 失敗：既有輸出檔原樣保留"
assert_eq $'good.tar.gz\nkeep.tar.gz' "$(ls "$mk/out")" "pack_offline 失敗：沒有殘留暫存檔"
mkdir -p "$mk/emptysrc"
assert_nonzero "pack_offline：來源沒有 .deb 回非 0" pack_offline "$mk/emptysrc" "$mk/out/none.tar.gz"
assert_eq "no" "$([ -e "$mk/out/none.tar.gz" ] && echo yes || echo no)" "pack_offline：沒有 .deb 時不產生輸出"

# 壞包：每一種都要被拒絕，且訊息（stderr）說明原因
bad_tar() { # bad_tar <名稱> <tar 引數…>：以 $mk/src 為工作目錄造 $mk/bad-<名稱>.tar.gz
    local n="$1"; shift
    tar czf "$mk/bad-$n.tar.gz" "$@" 2>/dev/null
}
expect_reject() { # expect_reject <名稱> <訊息片段>
    local out rc=0
    out="$(check_offline_tar "$mk/bad-$1.tar.gz" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then _t_pass; else _t_fail "check_offline_tar 拒絕：$1" "    期望非 0，實際 0"; fi
    assert_contains "$out" "$2" "check_offline_tar 拒絕 $1：訊息說明原因"
}
mkdir -p "$mk/src/sub"; printf 'n' >"$mk/src/sub/n.deb"
bad_tar nested -C "$mk/src" sub/n.deb
expect_reject nested "sub/n.deb"
bad_tar dotslash -C "$mk/src" ./a.deb
expect_reject dotslash "./a.deb"
bad_tar dotdot -C "$mk/src" --transform 's,^,../,' a.deb
expect_reject dotdot "../a.deb"
bad_tar abs -P -C "$mk/src" --transform 's,^,/tmp/,' a.deb
expect_reject abs "/tmp/a.deb"
printf 't' >"$mk/src/notes.txt"
bad_tar nondeb -C "$mk/src" a.deb notes.txt
expect_reject nondeb "notes.txt"
mkdir -p "$mk/dirsrc/d.deb"
bad_tar dirent -C "$mk/dirsrc" d.deb
expect_reject dirent "d.deb"
head -c 1024 /dev/zero | gzip >"$mk/bad-empty.tar.gz"
expect_reject empty ".deb"
printf 'not a tarball' >"$mk/bad-plain.tar.gz"
expect_reject plain "gzip"
assert_nonzero "check_offline_tar：檔案不存在" check_offline_tar "$mk/no-such.tar.gz"

# 手工組 ustar 條目：symlink／hardlink（Windows Git Bash 的 ln -s 不一定產生真 symlink，所以直接組位元組）。
padn() { printf '%s' "$1"; head -c $(($2 - ${#1})) /dev/zero; }
ustar_entry() { # ustar_entry <名稱> <typeflag：1 hardlink／2 symlink> <linkname> <輸出檔>：單一條目＋結尾 1024 零
    local out="$4" sum
    {
        padn "$1" 100; printf '0000777\0'; printf '0000000\0'; printf '0000000\0'
        printf '00000000000\0'; printf '00000000000\0'; printf '        '
        printf '%s' "$2"; padn "$3" 100; printf 'ustar\0' ; printf '00'
        padn "" 32; padn "" 32; padn "" 8; padn "" 8; padn "" 155; padn "" 12
    } >"$out.hdr"
    sum="$(od -An -v -tu1 "$out.hdr" | awk '{for (i = 1; i <= NF; i++) s += $i} END {print s}')"
    {
        head -c 148 "$out.hdr"
        printf '%06o\0 ' "$sum"
        tail -c +157 "$out.hdr"
        head -c 1024 /dev/zero
    } | gzip >"$out"
    rm -f "$out.hdr"
}
ustar_entry evil.deb 2 /etc/passwd "$mk/bad-symlink.tar.gz"
tv="$(tar tvzf "$mk/bad-symlink.tar.gz" 2>&1)"
assert_contains "$tv" "evil.deb" "手工 ustar 檔可被 tar 讀取（前提）"
assert_eq "l" "${tv:0:1}" "手工 ustar 條目確實是 symlink（前提）"
expect_reject symlink "evil.deb"
ustar_entry evil.deb 1 a.deb "$mk/bad-hardlink.tar.gz"
tv="$(tar tvzf "$mk/bad-hardlink.tar.gz" 2>&1)"
assert_eq "h" "${tv:0:1}" "手工 ustar 條目確實是 hardlink（前提）"
expect_reject hardlink "evil.deb"

# ══ 動作函式（接縫 B）：source 後直接呼叫，取結束碼與輸出 ═══════════════════════
# menu_loop 把動作放在子 shell 跑，行程結束碼恆為 0，所以結束碼只能在這裡斷言。
# 沙盒：假指令放 PATH 最前面並記進 $STUB_LOG；路徑全指到暫存目錄。
# 這只證明「在什麼條件下呼叫了什麼」，不證明真實 apt／dpkg 的行為。
cp "$T_TMP/depends.txt" "$T_TMP/fixture-depends.txt"
cp "$T_TMP/dpkg-dep.txt" "$T_TMP/fixture-dpkg-dep.txt"
cp "$T_TMP/dpkg-port.txt" "$T_TMP/fixture-dpkg-port.txt"
printf '%s\n' "$pol_ok" >"$T_TMP/fixture-policy-ok.txt"
printf '%s\n' "$pol_ubuntu" >"$T_TMP/fixture-policy-ubuntu.txt"
printf 'NAME="Ubuntu"\nVERSION_CODENAME=noble\n' >"$T_TMP/os-noble"
printf 'NAME="Ubuntu"\nVERSION_CODENAME=jammy\n' >"$T_TMP/os-jammy"

setup_sb() { # setup_sb <名稱>
    SB="$T_TMP/sb-$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/opt/embedded/sbin" "$SB/tmp" "$SB/home" "$SB/cwd" "$SB/out"
    STUB_LOG="$SB/stub.log"; : >"$STUB_LOG"; export STUB_LOG
    cp "$T_TMP/fixture-depends.txt" "$SB/depends.txt"
    cp "$T_TMP/fixture-policy-ok.txt" "$SB/policy.txt"
    cp "$T_TMP/fixture-dpkg-dep.txt" "$SB/dpkg-out.txt"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" curl '[ "${STUB_CURL_RC:-0}" = 0 ] || exit "$STUB_CURL_RC"
while [ $# -gt 0 ]; do [ "$1" = -o ] && echo FAKEKEY >"$2"; shift; done'
    make_stub "$SB/bin" gpg 'while [ $# -gt 0 ]; do [ "$1" = -o ] && echo FAKEKEYRING >"$2"; shift; done'
    make_stub "$SB/bin" apt-get 'case "$1" in
  update) exit "${STUB_UPDATE_RC:-0}" ;;
  download) [ "${STUB_DOWNLOAD_RC:-0}" = 0 ] || exit "$STUB_DOWNLOAD_RC"
    shift; for p in "$@"; do if [ "$p" = nginx ]; then echo deb >"nginx_1.29.3-1~noble_amd64.deb"; else echo deb >"${p}_1.0_amd64.deb"; fi; done ;;
esac'
    make_stub "$SB/bin" apt-cache 'case "$1" in
  depends) [ -n "${STUB_DEPENDS_EMPTY:-}" ] || cat "'"$SB"'/depends.txt" ;;
  policy) cat "'"$SB"'/policy.txt" ;;
  madison) echo "     nginx | 1.29.3-1~noble | http://nginx.org/packages/mainline/ubuntu noble/nginx amd64 Packages" ;;
esac'
    make_stub "$SB/bin" dpkg 'cat "'"$SB"'/dpkg-out.txt"; exit "${STUB_DPKG_RC:-0}"'
    make_stub "$SB/bin" nginx 'echo "nginx version: nginx/1.29.3" >&2'
    make_stub "$SB/bin" systemctl 'echo "● nginx.service - nginx"; exit "${STUB_SYSTEMCTL_RC:-0}"'
    printf '#!/usr/bin/env bash\necho "nginx version: nginx/1.26.3"  >&2\necho "built by gcc 13.2.0 (Ubuntu 13.2.0-23ubuntu4)" >&2\n' >"$SB/opt/embedded/sbin/nginx"
    chmod +x "$SB/opt/embedded/sbin/nginx"
    rm -f "$OPS_ENV_FILE"
}

# act <函式> [參數…]：在子 shell 中以 set -euo pipefail 呼叫（與真正的選單一致），
# stdin 為 ACT_IN（printf %b）；ACT_PRE 是先 eval 的覆寫（例如重新定義 have_cmd）。
# 結果在 ACT_OUT（stdout+stderr）與 ACT_RC。
act() {
    ACT_RC=0
    ACT_OUT="$( (
        export PATH="$SB/bin:$PATH" HOME="$SB/home" TMPDIR="$SB/tmp" OPS_FAKE_UID="${ACT_UID:-0}" \
            OS_RELEASE_FILE="${ACT_OS:-$T_TMP/os-noble}" GITLAB_OPT_DIR="${ACT_OPT:-$SB/opt}" \
            GITLAB_NGINX_BIN="${ACT_NGINX_BIN-$SB/opt/embedded/sbin/nginx}" \
            NGX_KEYRING="$SB/keyring.gpg" NGX_SOURCES_LIST="$SB/nginx.list"
        unset SUDO_USER
        cd "$SB/cwd"
        eval "${ACT_PRE:-:}"
        set -euo pipefail
        printf '%b' "${ACT_IN:-}" | "$@"
    ) 2>&1 )" || ACT_RC=$?
}
log_has() { grep -q -- "$1" "$STUB_LOG"; }
line_of() { grep -n -m1 -- "^$1" "$STUB_LOG" | cut -d: -f1; }
yn() { if "$@"; then echo yes; else echo no; fi; }

DEB_LIST=$'adduser_1.0_amd64.deb\ncdebconf_1.0_amd64.deb\ndebconf_1.0_amd64.deb\ngcc-14-base_1.0_amd64.deb\nlibc6_1.0_amd64.deb\nlibcrypt1_1.0_amd64.deb\nlibgcc-s1_1.0_amd64.deb\nlibpcre2-8-0_1.0_amd64.deb\nlibssl3t64_1.0_amd64.deb\nlibstdc++6_1.0_amd64.deb\nlsb-base_1.0_amd64.deb\nnginx_1.29.3-1~noble_amd64.deb\nucf_1.0_amd64.deb\nzlib1g_1.0_amd64.deb'

# ── ngx_build_offline 成功路徑（PR-NGX-01）──
setup_sb build
ACT_IN="$SB/out/nginx-offline.tar.gz\n"
act ngx_build_offline
build_out="$ACT_OUT"
assert_eq "0" "$ACT_RC" "ngx_build_offline 成功：結束碼 0"
assert_eq "$DEB_LIST" "$(tar tzf "$SB/out/nginx-offline.tar.gz" | LC_ALL=C sort)" "離線包內容＝下載到的 .deb，扁平檔名"
assert_eq "deb [signed-by=$SB/keyring.gpg] http://nginx.org/packages/mainline/ubuntu noble nginx" "$(cat "$SB/nginx.list")" "sources 檔寫入官方 mainline 來源行"
assert_eq "FAKEKEYRING" "$(cat "$SB/keyring.gpg")" "keyring 檔由 gpg --dearmor 產生"
assert_contains "$(cat "$STUB_LOG")" "https://nginx.org/keys/nginx_signing.key" "curl 取官方金鑰網址"
assert_eq "yes" "$(yn grep -q -- '^curl -fsSL' "$STUB_LOG")" "curl 用 -fsSL（HTTP 錯誤時失敗）"
assert_eq "yes" "$(yn grep -q -- "^gpg --dearmor --yes -o $SB/keyring.gpg" "$STUB_LOG")" "gpg 帶 --dearmor 與 --yes（重跑時 keyring 已存在）"
assert_contains "$(cat "$STUB_LOG")" "apt-get download adduser cdebconf debconf gcc-14-base libc6 libcrypt1 libgcc-s1 libpcre2-8-0 libssl3t64 libstdc++6 lsb-base nginx ucf zlib1g" "apt-get download 的引數逐字等於預期套件清單"
assert_not_contains "$(cat "$STUB_LOG")" "<debconf-2.0>" "download 引數不含虛擬套件"
assert_not_contains "$(cat "$STUB_LOG")" "libc6:i386" "download 引數不含其他架構"
o_curl="$(line_of curl)"; o_gpg="$(line_of gpg)"; o_upd="$(line_of 'apt-get update')"
o_pol="$(line_of 'apt-cache policy nginx')"; o_dep="$(line_of 'apt-cache depends')"; o_dl="$(line_of 'apt-get download')"
assert_eq "yes" "$([ -n "$o_curl" ] && [ "$o_curl" -lt "${o_gpg:-0}" ] && [ "$o_gpg" -lt "${o_upd:-0}" ] && [ "$o_upd" -lt "${o_pol:-0}" ] \
    && [ "$o_pol" -lt "${o_dep:-0}" ] && [ "$o_dep" -lt "${o_dl:-0}" ] && echo yes || echo no)" "順序：curl→gpg→apt-get update→policy→depends→download"
assert_eq "" "$(ls "$SB/tmp")" "暫存目錄已清掉"
assert_eq "" "$(ls "$SB/cwd")" "目前目錄沒留下 .deb"
assert_eq "no" "$(ls "$SB/out" | grep -q -v '^nginx-offline.tar.gz$' && echo yes || echo no)" "輸出目錄只有離線包"
assert_contains "$(cat "$OPS_ENV_FILE")" "NGX_TARBALL=$SB/out/nginx-offline.tar.gz" "離線包路徑存入參數檔"
assert_contains "$build_out" "$SB/out/nginx-offline.tar.gz" "輸出顯示離線包路徑"
assert_contains "$build_out" "scp $SB/out/nginx-offline.tar.gz" "輸出的 scp 範例帶實際路徑"
assert_contains "$build_out" "1.29.3-1~noble" "輸出顯示 nginx 版本"
# 重跑：來源行只會有一行
act ngx_build_offline
assert_eq "0" "$ACT_RC" "重跑仍成功"
assert_eq "1" "$(wc -l <"$SB/nginx.list" | tr -d ' ')" "重跑後 sources 檔仍只有一行"

# ── ngx_build_offline 失敗路徑（正向對照＝上面的成功路徑：同樣的沙盒會呼叫 curl／gpg／apt-get）──
fail_build() { # fail_build <名稱> → 設定沙盒、準備輸入，由呼叫端再 act
    setup_sb "$1"
    ACT_IN="$SB/out/nginx-offline.tar.gz\n"
    ACT_PRE=""; ACT_UID=0; ACT_OS="$T_TMP/os-noble"
}
no_artifacts() { # 沒有產生離線包、sources、keyring
    assert_eq "no" "$(yn test -e "$SB/out/nginx-offline.tar.gz")" "$1：沒有離線包"
    assert_eq "no" "$(yn test -e "$SB/nginx.list")" "$1：沒有寫 sources"
}

fail_build curlfail; STUB_CURL_RC=22 act ngx_build_offline
assert_eq "1" "$ACT_RC" "金鑰下載失敗：結束碼 1"
assert_contains "$ACT_OUT" "金鑰" "金鑰下載失敗：訊息說明"
no_artifacts "金鑰下載失敗"
assert_eq "no" "$(yn log_has '^apt-get update')" "金鑰下載失敗：沒呼叫 apt-get update"

fail_build empty; STUB_DEPENDS_EMPTY=1 act ngx_build_offline
assert_eq "1" "$ACT_RC" "相依清單為空：結束碼 1"
assert_contains "$ACT_OUT" "相依" "相依清單為空：訊息說明"
assert_eq "no" "$(yn log_has '^apt-get download')" "相依清單為空：不呼叫 apt-get download"
assert_eq "no" "$(yn test -e "$SB/out/nginx-offline.tar.gz")" "相依清單為空：沒有離線包"

fail_build dlfail; STUB_DOWNLOAD_RC=100 act ngx_build_offline
assert_eq "1" "$ACT_RC" "download 失敗：結束碼 1"
assert_eq "no" "$(yn test -e "$SB/out/nginx-offline.tar.gz")" "download 失敗：沒有離線包"
assert_eq "" "$(ls "$SB/tmp")" "download 失敗：暫存目錄已清掉"

fail_build ubuntu; cp "$T_TMP/fixture-policy-ubuntu.txt" "$SB/policy.txt"; act ngx_build_offline
assert_eq "1" "$ACT_RC" "候選版本來自 Ubuntu：結束碼 1"
assert_contains "$ACT_OUT" "nginx.org" "候選版本來自 Ubuntu：訊息說明"
assert_eq "no" "$(yn log_has '^apt-cache depends')" "候選版本來自 Ubuntu：不解析相依"
assert_eq "no" "$(yn log_has '^apt-get download')" "候選版本來自 Ubuntu：不下載"
assert_eq "" "$(ls "$SB/tmp")" "候選版本來自 Ubuntu：暫存目錄已清掉"

fail_build jammy; ACT_OS="$T_TMP/os-jammy" act ngx_build_offline
assert_eq "1" "$ACT_RC" "codename 不是 noble：結束碼 1"
assert_contains "$ACT_OUT" "noble" "codename 不是 noble：訊息說明"
assert_contains "$ACT_OUT" "jammy" "codename 不是 noble：訊息帶出實際 codename"
no_artifacts "codename 不是 noble"
assert_eq "no" "$(yn test -s "$STUB_LOG")" "codename 不是 noble：沒呼叫任何指令"

fail_build nonroot; ACT_UID=1000 act ngx_build_offline
assert_eq "1" "$ACT_RC" "非 root：結束碼 1"
assert_contains "$ACT_OUT" "root" "非 root：訊息說明"
no_artifacts "非 root"
assert_eq "no" "$(yn test -s "$STUB_LOG")" "非 root：沒呼叫任何指令"

# 機器分區：缺 apt（用 have_cmd 覆寫模擬，不靠空 PATH）
fail_build noapt; ACT_PRE='have_cmd() { [ "$1" != apt ] && command -v "$1" >/dev/null 2>&1; }' act ngx_build_offline
assert_eq "1" "$ACT_RC" "缺 apt：結束碼 1"
assert_contains "$ACT_OUT" "【有網路的電腦】" "缺 apt：指向【有網路的電腦】"
no_artifacts "缺 apt"
assert_eq "no" "$(yn test -s "$STUB_LOG")" "缺 apt：沒呼叫任何指令"
for c in apt-get apt-cache curl gpg tar; do
    fail_build "no-$c"
    ACT_PRE='have_cmd() { [ "$1" != '"$c"' ] && command -v "$1" >/dev/null 2>&1; }' act ngx_build_offline
    assert_eq "1" "$ACT_RC" "缺 $c：結束碼 1"
    assert_contains "$ACT_OUT" "缺少指令 $c" "缺 $c：訊息點名"
    no_artifacts "缺 $c"
    assert_eq "no" "$(yn test -s "$STUB_LOG")" "缺 $c：沒呼叫任何指令"
done

# ngx_default_tarball：sudo 下改用 SUDO_USER 的家目錄
getent() { echo "alice:x:1000:1000:Alice:/home/alice:/bin/bash"; }
assert_eq "/home/alice/nginx-offline.tar.gz" "$(SUDO_USER=alice ngx_default_tarball)" "有 SUDO_USER：預設用該使用者家目錄"
assert_eq "$HOME/nginx-offline.tar.gz" "$(unset SUDO_USER; ngx_default_tarball)" "沒有 SUDO_USER：用 \$HOME"
unset -f getent

# ══ ngx_install_offline（PR-NGX-02）══
setup_inst() { # setup_inst <名稱>：沙盒＋一個用真 tar 造的離線包
    setup_sb "$1"
    mkdir -p "$SB/pkg" "$SB/in"
    printf 'a' >"$SB/pkg/a.deb"
    printf 'n' >"$SB/pkg/nginx_1.29.3-1~noble_amd64.deb"
    tar czf "$SB/in/nginx-offline.tar.gz" -C "$SB/pkg" a.deb nginx_1.29.3-1~noble_amd64.deb
    ACT_IN="$SB/in/nginx-offline.tar.gz\nyes\n"
    ACT_PRE=""; ACT_UID=0; ACT_OPT=""; ACT_OS="$T_TMP/os-noble"
    unset ACT_OPT
}

setup_inst inst
act ngx_install_offline
inst_log="$(cat "$STUB_LOG")"
assert_eq "0" "$ACT_RC" "ngx_install_offline 成功：結束碼 0"
dpkg_line="$(grep '^dpkg ' "$STUB_LOG")"
re="^dpkg -i $SB/tmp/[^ /]+/a\.deb $SB/tmp/[^ /]+/nginx_1\.29\.3-1~noble_amd64\.deb$"
assert_eq "yes" "$([[ $dpkg_line =~ $re ]] && echo yes || echo no)" "dpkg -i 的引數是暫存目錄的絕對路徑，且含全部 .deb（實際：$dpkg_line）"
o_d="$(line_of dpkg)"; o_v="$(line_of 'nginx -v')"; o_s="$(line_of 'systemctl status nginx')"
assert_eq "yes" "$([ -n "$o_d" ] && [ "$o_d" -lt "${o_v:-0}" ] && [ "$o_v" -lt "${o_s:-0}" ] && echo yes || echo no)" "順序：dpkg -i → nginx -v → systemctl status nginx"
assert_contains "$ACT_OUT" "1.29.3" "輸出顯示 nginx -v 的版本"
assert_eq "" "$(ls "$SB/tmp")" "成功後暫存目錄已清掉"
assert_eq "" "$(ls "$SB/cwd")" "目前目錄沒有解包殘留"

# 未確認不動系統（正向對照＝上面成功路徑呼叫了 dpkg）
setup_inst no; ACT_IN="$SB/in/nginx-offline.tar.gz\nno\n"; act ngx_install_offline
assert_eq "0" "$ACT_RC" "回答 no：結束碼 0"
assert_eq "no" "$(yn log_has '^dpkg')" "回答 no：沒呼叫 dpkg"
assert_contains "$ACT_OUT" "已取消" "回答 no：訊息說明已取消"
assert_eq "" "$(ls "$SB/tmp")" "回答 no：暫存目錄已清掉"
setup_inst eof; ACT_IN="$SB/in/nginx-offline.tar.gz\n"; act ngx_install_offline
assert_eq "no" "$(yn log_has '^dpkg')" "確認處 EOF：沒呼叫 dpkg"

# 離線包不存在／不安全：不呼叫 dpkg、不解包
setup_inst missing; ACT_IN="$SB/in/none.tar.gz\nyes\n"; act ngx_install_offline
assert_eq "1" "$ACT_RC" "離線包不存在：結束碼 1"
assert_contains "$ACT_OUT" "$SB/in/none.tar.gz" "離線包不存在：訊息帶路徑"
assert_eq "no" "$(yn log_has '^dpkg')" "離線包不存在：沒呼叫 dpkg"
setup_inst unsafe
mkdir -p "$SB/pkg/sub"; printf 'x' >"$SB/pkg/sub/evil.deb"
tar czf "$SB/in/evil.tar.gz" -C "$SB/pkg" a.deb sub/evil.deb
ACT_IN="$SB/in/evil.tar.gz\nyes\n"; act ngx_install_offline
assert_eq "1" "$ACT_RC" "不安全的離線包（巢狀路徑）：結束碼 1"
assert_contains "$ACT_OUT" "sub/evil.deb" "不安全的離線包：訊息點名條目"
assert_eq "no" "$(yn log_has '^dpkg')" "不安全的離線包：沒呼叫 dpkg"
assert_eq "" "$(ls "$SB/tmp")" "不安全的離線包：沒有解包到暫存目錄"

# dpkg 失敗且有缺相依：列出有問題的套件與缺的相依，導向回有網路的電腦
setup_inst depfail; STUB_DPKG_RC=1 act ngx_install_offline
assert_eq "1" "$ACT_RC" "dpkg 失敗：結束碼 1"
for p in libssl3t64 libpcre2-8-0 zlib1g; do assert_contains "$ACT_OUT" "$p" "缺相依：列出 $p"; done
assert_contains "$ACT_OUT" "有網路的電腦" "缺相依：提示回【有網路的電腦】補下載"
assert_contains "$ACT_OUT" "apt-get download libpcre2-8-0 libssl3t64 zlib1g" "缺相依：給出可複製的補下載指令"
assert_eq "no" "$(yn log_has '^nginx')" "dpkg 失敗：不跑 nginx -v 驗證"
assert_eq "no" "$(yn log_has '^systemctl')" "dpkg 失敗：不跑 systemctl"
kept="$(ls "$SB/tmp")"
assert_eq "yes" "$([ -n "$kept" ] && echo yes || echo no)" "dpkg 失敗：保留解包目錄供檢查"
assert_contains "$ACT_OUT" "$SB/tmp/$kept" "dpkg 失敗：訊息印出保留的目錄"

# dpkg 失敗但沒有缺相依（例如 80 埠被內建 Nginx 佔用）：導向排查，不叫人回去補下載
setup_inst portfail; cp "$T_TMP/fixture-dpkg-port.txt" "$SB/dpkg-out.txt"; STUB_DPKG_RC=1 act ngx_install_offline
assert_eq "1" "$ACT_RC" "dpkg 失敗（非相依）：結束碼 1"
assert_contains "$ACT_OUT" "libfoo1" "非相依失敗：列出有問題的套件"
assert_contains "$ACT_OUT" "常見問題排查" "非相依失敗：導向排查"
assert_not_contains "$ACT_OUT" "apt-get download" "非相依失敗：不給補下載指令"
assert_not_contains "$ACT_OUT" "補下載" "非相依失敗：不叫人回有網路的電腦補下載"

# systemctl status 非 0（inactive）：只警告，動作整體成功
setup_inst inactive; STUB_SYSTEMCTL_RC=3 act ngx_install_offline
assert_eq "0" "$ACT_RC" "systemctl status 非 0：動作仍成功（結束碼 0）"
assert_contains "$ACT_OUT" "⚠" "systemctl status 非 0：顯示警告"
assert_eq "yes" "$(yn log_has '^systemctl status nginx')" "systemctl status 非 0：確實有呼叫"

# 機器分區（server）
setup_inst nogitlab; ACT_OPT="$SB/no-such-opt" act ngx_install_offline
assert_eq "1" "$ACT_RC" "沒裝 GitLab：結束碼 1"
assert_contains "$ACT_OUT" "【GitLab 伺服器】" "沒裝 GitLab：指向【GitLab 伺服器】"
assert_eq "no" "$(yn test -s "$STUB_LOG")" "沒裝 GitLab：沒呼叫任何指令"
unset ACT_OPT
setup_inst noapt2; ACT_PRE='have_cmd() { [ "$1" != apt ] && command -v "$1" >/dev/null 2>&1; }' act ngx_install_offline
assert_eq "1" "$ACT_RC" "伺服器缺 apt：結束碼 1"
assert_contains "$ACT_OUT" "【GitLab 伺服器】" "伺服器缺 apt：指向【GitLab 伺服器】"
setup_inst nonroot2; ACT_UID=1000 act ngx_install_offline
assert_eq "1" "$ACT_RC" "安裝非 root：結束碼 1"
assert_contains "$ACT_OUT" "root" "安裝非 root：訊息說明"
assert_eq "no" "$(yn test -s "$STUB_LOG")" "安裝非 root：沒呼叫任何指令"
for c in dpkg tar systemctl; do
    setup_inst "no-$c"
    ACT_PRE='have_cmd() { [ "$1" != '"$c"' ] && command -v "$1" >/dev/null 2>&1; }' act ngx_install_offline
    assert_eq "1" "$ACT_RC" "安裝缺 $c：結束碼 1"
    assert_contains "$ACT_OUT" "缺少指令 $c" "安裝缺 $c：訊息點名"
    assert_eq "no" "$(yn log_has '^dpkg')" "安裝缺 $c：沒呼叫 dpkg"
done

# ══ ngx_show_builtin（PR-NGX-02）══
setup_sb show; ACT_PRE=""; ACT_UID=0
act ngx_show_builtin
assert_eq "0" "$ACT_RC" "顯示內建版本：結束碼 0"
assert_contains "$ACT_OUT" "built by gcc 13.2.0" "顯示內建版本：印出完整 nginx -V"
assert_contains "$ACT_OUT" "1.26.3" "顯示內建版本：抽出版本號"
ACT_NGINX_BIN="$SB/none" act ngx_show_builtin
assert_eq "1" "$ACT_RC" "內建 nginx 不存在：結束碼 1"
assert_contains "$ACT_OUT" "reconfigure" "內建 nginx 不存在：提示先 reconfigure"
unset ACT_NGINX_BIN
ACT_OPT="$SB/no-such-opt" act ngx_show_builtin
assert_eq "1" "$ACT_RC" "顯示版本，沒裝 GitLab：結束碼 1"
assert_contains "$ACT_OUT" "【GitLab 伺服器】" "顯示版本，沒裝 GitLab：指向【GitLab 伺服器】"
unset ACT_OPT
ACT_PRE='have_cmd() { [ "$1" != apt ] && command -v "$1" >/dev/null 2>&1; }' act ngx_show_builtin
assert_eq "1" "$ACT_RC" "顯示版本，缺 apt：結束碼 1"

# ══ 接縫 C：選單行程（PR-COM-01／04／11）══
# 行程結束碼恆為 0（menu_loop 在子 shell 跑動作），所以失敗以 stderr 的「動作未完成（結束碼 N）」斷言。
run_ngx() { # run_ngx <stdin 內容> [環境變數 KEY=VAL…]：在沙盒中以無參數執行 nginx.sh
    local input="$1"
    shift
    printf '%b' "$input" | env -u SUDO_USER PATH="$SB/bin:$PATH" HOME="$SB/home" TMPDIR="$SB/tmp" OPS_FAKE_UID=0 \
        OS_RELEASE_FILE="$T_TMP/os-noble" GITLAB_OPT_DIR="$SB/opt" NGX_KEYRING="$SB/keyring.gpg" \
        NGX_SOURCES_LIST="$SB/nginx.list" "$@" bash "$ngx" 2>&1
}
setup_inst menu

assert_status 2 "帶參數即拒絕" env PATH="$SB/bin:$PATH" bash "$ngx" foo
assert_status 2 "空字串參數也拒絕" env PATH="$SB/bin:$PATH" bash "$ngx" ""
assert_status 2 "多個參數也拒絕" env PATH="$SB/bin:$PATH" bash "$ngx" -h --help
assert_status 0 "q 離開結束碼 0" bash -c "printf 'q\n' | env PATH='$SB/bin:$PATH' bash '$ngx'"
assert_status 0 "stdin EOF 離開結束碼 0" bash -c "env PATH='$SB/bin:$PATH' bash '$ngx' </dev/null"
menu="$(run_ngx 'q\n')"
for n in 1 2 3 4 5 6 7 8 9 10; do
    line="$(printf '%s\n' "$menu" | grep "^  $n)")"
    assert_contains "$line" "【" "選單第 $n 項標示執行機器（PR-COM-04）"
done
assert_contains "$(printf '%s\n' "$menu" | grep '^  1)')" "【GitLab 伺服器】" "顯示內建版本：【GitLab 伺服器】"
assert_contains "$(printf '%s\n' "$menu" | grep '^  2)')" "【有網路的電腦】" "打包：【有網路的電腦】"
assert_contains "$(printf '%s\n' "$menu" | grep '^  3)')" "【GitLab 伺服器】" "安裝：【GitLab 伺服器】"
assert_contains "$(printf '%s\n' "$menu" | grep '^  9)')" "說明" "第 9 項是說明"
assert_contains "$(printf '%s\n' "$menu" | grep '^  9)')" "【有網路的電腦】【GitLab 伺服器】" "說明：沿用兩個既有標示"
assert_contains "$(printf '%s\n' "$menu" | grep '^  10)')" "常見問題排查" "第 10 項是常見問題排查"
assert_contains "$(printf '%s\n' "$menu" | grep '^  10)')" "【有網路的電腦】【GitLab 伺服器】" "排查：沿用兩個既有標示"
assert_not_contains "$menu" "任一台" "不新增第三種標示"

# 動作失敗：行程仍回選單、stderr 顯示「動作未完成」；成功則沒有（正向對照）
out="$(run_ngx '1\nq\n')"
assert_contains "$out" "1.26.3" "選單 1：顯示內建版本"
assert_not_contains "$out" "動作未完成" "選單 1 成功：沒有「動作未完成」"
out="$(run_ngx '1\nq\n' GITLAB_OPT_DIR="$SB/no-such-opt")"
assert_contains "$out" "動作未完成（結束碼 1）" "選單 1 在沒裝 GitLab 的機器：動作未完成"
assert_contains "$out" "【GitLab 伺服器】" "選單 1 在沒裝 GitLab 的機器：指向【GitLab 伺服器】"
out="$(run_ngx "3\n$SB/in/nginx-offline.tar.gz\nyes\nq\n" STUB_SYSTEMCTL_RC=3)"
assert_contains "$out" "⚠" "選單 3，systemctl status 非 0：警告"
assert_not_contains "$out" "動作未完成" "選單 3，systemctl status 非 0：不算失敗"
out="$(run_ngx "2\n$SB/out/menu.tar.gz\nq\n")"
assert_not_contains "$out" "動作未完成" "選單 2 打包成功：沒有「動作未完成」"
assert_eq "yes" "$(yn test -f "$SB/out/menu.tar.gz")" "選單 2 打包成功：產生離線包"
out="$(run_ngx "2\n$SB/out/menu2.tar.gz\nq\n" OPS_FAKE_UID=1000)"
assert_contains "$out" "動作未完成（結束碼 1）" "選單 2 非 root：動作未完成"
assert_contains "$out" "已離開" "動作失敗後仍回選單，可正常離開"
out="$(run_ngx '99\nq\n')"
assert_contains "$out" "無此選項" "無效選項有提示"

# 說明（PR-COM-11）：前置條件與注意事項，只斷言來源文件的標記字串
help="$(run_ngx '9\nq\n')"
assert_contains "$help" "前置條件" "說明含前置條件"
assert_contains "$help" "sudo gitlab-ctl reconfigure" "說明：前置條件需至少 reconfigure 一次"
assert_contains "$help" "Ubuntu 24.04" "說明：須在相同 Ubuntu 24.04 的電腦打包"
assert_contains "$help" "apt-get download" "說明：提到 apt-get download"
assert_contains "$help" "已安裝" "說明：apt-get download 可在已裝 Nginx 的電腦上執行"
assert_contains "$help" "scp" "說明：傳輸步驟（scp）"
assert_contains "$help" "dpkg --configure -a" "說明：相依錯誤後的 dpkg --configure -a"
assert_contains "$help" "/opt/gitlab/embedded/sbin/nginx -V" "說明：內建版本的指令"
assert_contains "$help" "升級" "說明：提醒 dpkg -i 可能升級系統套件"
assert_not_contains "$help" "動作未完成" "說明項目本身成功"

# 常見問題排查（PR-COM-11）：04 文件排查表六列整份帶入 + 本票新增條目
fix="$(run_ngx '10\nq\n')"
assert_contains "$fix" "502 Bad Gateway" "排查：502"
assert_contains "$fix" "sudo gitlab-ctl status" "排查 502：gitlab-ctl status"
assert_contains "$fix" "ls -la /var/opt/gitlab/gitlab-workhorse/sockets/socket" "排查 502：確認 socket 存在"
assert_contains "$fix" "Permission denied" "排查：Permission denied"
assert_contains "$fix" "ps aux | grep 'nginx: worker'" "排查 Permission denied：確認 worker 使用者"
assert_contains "$fix" "web_server['external_users']" "排查 Permission denied：external_users"
assert_contains "$fix" "413 Request Entity Too Large" "排查：413"
assert_contains "$fix" "client_max_body_size 0;" "排查 413：client_max_body_size"
assert_contains "$fix" "WebSocket" "排查：WebSocket"
assert_contains "$fix" 'map $http_upgrade' "排查 WebSocket：map 區塊"
assert_contains "$fix" "Nginx 無法啟動" "排查：Nginx 無法啟動"
assert_contains "$fix" "sudo nginx -t" "排查無法啟動：nginx -t"
assert_contains "$fix" "sudo ss -tlnp | grep ':80'" "排查無法啟動：檢查 80 埠"
assert_contains "$fix" "push/pull" "排查：Git push/pull 失敗"
assert_contains "$fix" "proxy_read_timeout 3600;" "排查 push/pull：timeout"
assert_contains "$fix" "dpkg -i 相依錯誤" "排查（新增）：dpkg 相依錯誤"
assert_contains "$fix" "金鑰" "排查（新增）：金鑰匯入失敗"
assert_contains "$fix" "noble" "排查（新增）：codename 不符"
assert_contains "$fix" "nginx.org" "排查（新增）：候選版本不是 nginx.org"
assert_contains "$fix" "內建 Nginx" "排查（新增）：80 埠被內建 Nginx 佔用"
assert_not_contains "$fix" "動作未完成" "排查項目本身成功"

# ── 檢查與解包之間不可被換掉（TOCTOU）：解包用的是檢查過的私有副本，不是原路徑 ──
setup_inst toctou
real_tar="$(command -v tar)"
make_stub "$SB/bin" tar 'exec "'"$real_tar"'" "$@"'
act ngx_install_offline
assert_eq "0" "$ACT_RC" "TOCTOU 沙盒：安裝本身成功（正向對照）"
xline="$(grep '^tar xzf' "$STUB_LOG")"
assert_contains "$xline" "tar xzf $SB/tmp/" "解包的來源是暫存目錄內的私有副本"
assert_not_contains "$xline" "$SB/in/nginx-offline.tar.gz" "解包不再讀原始路徑"
