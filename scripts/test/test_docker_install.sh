#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# Docker 離線安裝共用函式（common.sh）與 docker.sh 的兩個選單動作。
# 真實 apt／dpkg／systemd 不在此驗證；以 PATH 上的假指令觀察呼叫。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
dkr="$here/../docker.sh"
rnr="$here/../runner.sh"
common="$here/../lib/common.sh"
. "$dkr"

# ── 共用不複製（PR-DKR-04）：相依解析只在 common.sh ──
assert_status 0 "common.sh 含 apt-cache depends" grep -q 'apt-cache depends' "$common"
for fn in docker_download_debs unpack_offline_tar install_debs_in docker_enable_service; do
    assert_status 0 "runner.sh 呼叫 $fn" grep -qE "^[^#]*[^A-Za-z_]${fn}([^A-Za-z_]|$)|^${fn}" "$rnr"
    assert_status 0 "docker.sh 呼叫 $fn" grep -qE "^[^#]*[^A-Za-z_]${fn}([^A-Za-z_]|$)|^${fn}" "$dkr"
done
for s in "$rnr" "$dkr"; do
    assert_status 1 "${s##*/}：不自行解析相依（無 apt-cache depends 呼叫、無 parse_dep_pkgs）" grep -qE "^[^#]*(apt-cache depends|parse_dep_pkgs)" "$s"
    assert_status 1 "${s##*/}：不自行呼叫 dpkg -i／apt-get download" grep -qE '^[[:space:]]*(\(cd [^)]*&& )?(dpkg -i|apt-get download)' "$s"
done

# die 會 exit，動作函式一律在子 shell 內呼叫，免得終止整個測試檔。
sub() { ( "$@" ); }

# ── 沙箱 ──
setup() { # setup <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/debs"
    export HOME="$SB" STUB_LOG="$SB/stub.log" OPS_ENV_FILE="$SB/ops.env" TMPDIR="$SB" OPS_FAKE_UID=0
    : >"$STUB_LOG"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" apt-cache 'printf "docker.io\n  Depends: runc\nrunc\n<virt>\nlibc6:i386\n"'
    make_stub "$SB/bin" apt-get '[ "${FAIL_GET:-}" = 1 ] && exit 100; shift; for p in "$@"; do : >"${p}_1.0_amd64.deb"; done'
    make_stub "$SB/bin" dpkg 'exit "${FAIL_DPKG:-0}"'
    make_stub "$SB/bin" systemctl '[ "${FAIL_SYSTEMCTL:-}" = 1 ] && exit 1; exit 0'
    export PATH="$SB/bin:$PATH"
}

# ── docker_download_debs ──
setup dl_ok
docker_download_debs "$SB/debs" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "下載成功：結束碼 0"
assert_eq "docker.io_1.0_amd64.deb runc_1.0_amd64.deb " "$(cd "$SB/debs" && ls | tr '\n' ' ')" "只下載實體套件（丟棄虛擬與其他架構）"

setup dl_fail
FAIL_GET=1 docker_download_debs "$SB/debs" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "apt-get download 失敗：回非 0"

setup dl_empty
make_stub "$SB/bin" apt-cache 'exit 0'
docker_download_debs "$SB/debs" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "解析不到相依：回非 0"
assert_not_contains "$(cat "$STUB_LOG")" "apt-get" "解析不到相依：不呼叫 apt-get"

# ── unpack_offline_tar ──
setup un_ok
: >"$SB/debs/a_1.deb"; pack_offline "$SB/debs" "$SB/p.tar.gz" >/dev/null
mkdir "$SB/x"
unpack_offline_tar "$SB/p.tar.gz" "$SB/x" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "合法離線包解開成功"
assert_eq "a_1.deb" "$(ls "$SB/x")" "解出 deb 且不留私有副本"
printf 'junk' >"$SB/bad.tar.gz"
mkdir "$SB/y"
unpack_offline_tar "$SB/bad.tar.gz" "$SB/y" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "損壞離線包回非 0"
assert_eq "" "$(ls "$SB/y")" "損壞離線包不解出任何檔案"
( cd "$SB/debs" && tar czf "$SB/evil.tar.gz" --transform 's,^,../,' a_1.deb ) 2>/dev/null
unpack_offline_tar "$SB/evil.tar.gz" "$SB/y" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "含 ../ 條目的離線包被拒絕"

# ── docker_enable_service ──
setup en
docker_enable_service >/dev/null 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "啟用服務成功回 0"
assert_contains "$(cat "$STUB_LOG")" "systemctl enable --now docker" "呼叫 systemctl enable --now docker"
FAIL_SYSTEMCTL=1 docker_enable_service >"$SB/o" 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "啟用失敗只警告、仍回 0"
assert_contains "$(cat "$SB/o")" "⚠" "啟用失敗印出警告"

# ── docker_build_offline（【有網路的電腦】）──
setup bo
printf 'GLC_DOCKER_TAR=%s\n' "$SB/docker-offline.tar.gz" >"$OPS_ENV_FILE"
sub docker_build_offline </dev/null >"$SB/o" 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "打包 Docker 離線包成功"
assert_eq "docker.io_1.0_amd64.deb runc_1.0_amd64.deb " "$(tar tzf "$SB/docker-offline.tar.gz" | LC_ALL=C sort | tr '\n' ' ')" "包內是 docker.io 與其相依"
assert_status 0 "離線包通過安裝端檢查" check_offline_tar "$SB/docker-offline.tar.gz"

setup bo_fail
printf 'GLC_DOCKER_TAR=%s\n' "$SB/docker-offline.tar.gz" >"$OPS_ENV_FILE"
FAIL_GET=1 sub docker_build_offline </dev/null >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "下載失敗：中止"
assert_status 1 "下載失敗：不產生離線包" test -f "$SB/docker-offline.tar.gz"

# ── docker_install_offline（【GitLab 伺服器】）──
inst_setup() { # inst_setup <名稱>
    setup "$1"
    : >"$SB/debs/docker.io_1.0_amd64.deb"
    pack_offline "$SB/debs" "$SB/docker-offline.tar.gz" >/dev/null
    printf 'GLC_DOCKER_TAR=%s\n' "$SB/docker-offline.tar.gz" >"$OPS_ENV_FILE"
}
inst_setup in_ok
sub docker_install_offline <<<$'
yes' >"$SB/o" 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "安裝成功"
assert_contains "$(cat "$STUB_LOG")" "dpkg -i" "呼叫 dpkg -i"
assert_contains "$(cat "$STUB_LOG")" "docker.io_1.0_amd64.deb" "安裝清單含 docker.io"
assert_contains "$(cat "$STUB_LOG")" "systemctl enable --now docker" "安裝後啟用 docker 服務"

inst_setup in_no
sub docker_install_offline <<<$'
no' >/dev/null 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "使用者拒絕：正常結束"
assert_not_contains "$(cat "$STUB_LOG")" "dpkg -i" "使用者拒絕：不安裝"

inst_setup in_bad
printf 'junk' >"$SB/docker-offline.tar.gz"
sub docker_install_offline <<<$'
yes' >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "離線包損壞：中止"
assert_not_contains "$(cat "$STUB_LOG")" "dpkg -i" "離線包損壞：不安裝"

inst_setup in_miss
rm -f "$SB/docker-offline.tar.gz"
sub docker_install_offline <<<$'
yes' >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "找不到離線包：中止"
assert_not_contains "$(cat "$STUB_LOG")" "dpkg -i" "找不到離線包：不安裝"

inst_setup in_nonroot
OPS_FAKE_UID=1000 sub docker_install_offline <<<$'
yes' >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "非 root：中止"
assert_not_contains "$(cat "$STUB_LOG")" "dpkg -i" "非 root：不安裝"

inst_setup in_dpkgfail
FAIL_DPKG=1 sub docker_install_offline <<<$'
yes' >/dev/null 2>&1 && r=0 || r=$?
assert_eq 1 "$r" "dpkg 失敗：回非 0"
assert_not_contains "$(cat "$STUB_LOG")" "systemctl" "dpkg 失敗：不啟用服務"

# ── 選單（接縫 C）──
menu="$(show_menu)"
assert_contains "$(grep '打包 Docker 離線包' <<<"$menu")" "【有網路的電腦】" "打包 Docker 離線包標【有網路的電腦】"
assert_contains "$(grep '安裝 Docker' <<<"$menu")" "【GitLab 伺服器】" "安裝 Docker 標【GitLab 伺服器】"
assert_not_contains "$menu" "尚未實作" "選單不再有佔位項目"
# dispatch 經選單行程驗證：看下游效果，不覆寫函式
setup menu_3
printf 'GLC_DOCKER_TAR=%s\n' "$SB/m.tar.gz" >"$OPS_ENV_FILE"
printf '3\n\nq\n' | bash "$dkr" >"$SB/o" 2>&1
assert_contains "$(cat "$STUB_LOG")" "apt-get download" "選單 3：下載 deb"
assert_status 0 "選單 3：產生離線包" test -f "$SB/m.tar.gz"
inst_setup menu_4
printf '4\n\nyes\nq\n' | bash "$dkr" >"$SB/o" 2>&1
assert_contains "$(cat "$STUB_LOG")" "dpkg -i" "選單 4：dpkg -i"
assert_contains "$(cat "$STUB_LOG")" "systemctl enable --now docker" "選單 4：啟用 docker 服務"

# ── install_debs_in ──
setup ii_ok
: >"$SB/debs/a_1.deb"
install_debs_in "$SB/debs" <<<"yes" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 0 "$r" "install_debs_in：確認後成功"
assert_contains "$(cat "$STUB_LOG")" "dpkg -i" "install_debs_in：呼叫 dpkg -i"
setup ii_no
: >"$SB/debs/a_1.deb"
install_debs_in "$SB/debs" <<<"no" >/dev/null 2>&1 && r=0 || r=$?
assert_eq 100 "$r" "install_debs_in：使用者拒絕回 100"
assert_not_contains "$(cat "$STUB_LOG")" "dpkg -i" "install_debs_in：拒絕不安裝"
setup ii_fail
: >"$SB/debs/a_1.deb"
FAIL_DPKG=7 install_debs_in "$SB/debs" <<<"yes" >/dev/null 2>"$SB/e" && r=0 || r=$?
assert_eq 7 "$r" "install_debs_in：dpkg 失敗原樣回傳其結束碼"
assert_contains "$(cat "$SB/e")" "dpkg -i 失敗" "install_debs_in：dpkg 失敗印出說明"
