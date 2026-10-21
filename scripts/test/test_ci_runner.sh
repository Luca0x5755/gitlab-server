#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012,SC2010,SC2030,SC2031
# runner.sh 的純函式（接縫 A）、動作函式的結束碼與副作用（接縫 B）、選單行程（接縫 C）。
#
# 重要：version-manifest.txt、gitlab-runner／docker 指令的 fixture 依官方格式謄寫，「非實機擷取」。
# 待 Ubuntu VM 試跑時，請換成實機輸出再確認解析仍正確。期望值一律寫死字面值。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
rnr="$here/../runner.sh"

# source 取得函式：main 守門，source 時不啟動選單、不改選項。
. "$rnr"

# ── runner_gitlab_version：從 version-manifest.txt 取 GitLab 版本 ──
printf 'gitlab-ce 18.10.3\n\nBuild: 18.10.3-ce.0\n' >"$T_TMP/manifest-ce.txt"
assert_eq "18.10.3" "$(runner_gitlab_version "$T_TMP/manifest-ce.txt")" "取出 gitlab-ce 的版本"
printf 'gitlab-ee 17.2.0\n' >"$T_TMP/manifest-ee.txt"
assert_eq "17.2.0" "$(runner_gitlab_version "$T_TMP/manifest-ee.txt")" "也接受 gitlab-ee"
printf 'nothing here\n' >"$T_TMP/manifest-bad.txt"
assert_nonzero "格式不符回非 0" runner_gitlab_version "$T_TMP/manifest-bad.txt"
assert_nonzero "檔案不存在回非 0" runner_gitlab_version "$T_TMP/nope.txt"

# ── runner_version_mismatch：major.minor 不同才算不一致 ──
assert_status 1 "同 major.minor 不算不一致" runner_version_mismatch 18.10.3 18.10.0
assert_status 0 "minor 不同算不一致" runner_version_mismatch 18.10.3 18.9.1
assert_status 0 "major 不同算不一致" runner_version_mismatch 18.10.3 17.10.3
assert_status 0 "Runner 版本帶 debian 後綴（-1）仍可比對" runner_version_mismatch 18.10.3 18.9.0-1
assert_status 1 "Runner 版本帶 debian 後綴且 major.minor 相同" runner_version_mismatch 18.10.3 18.10.0-1
assert_status 2 "非法版本字串回 2（不是「一致」也不是「不一致」）" runner_version_mismatch 18.10.3 abc

# ── runner_url_scheme／runner_url_host／runner_clone_url ──
assert_eq "https" "$(runner_url_scheme https://192.168.9.129)" "https 網址的 scheme"
assert_eq "http" "$(runner_url_scheme http://127.0.0.1:8080/)" "http 網址的 scheme"
assert_nonzero "非 http(s) 的網址被拒絕" runner_url_scheme ftp://x
assert_eq "gitlab.example.com" "$(runner_url_host https://gitlab.example.com:8443/path)" "取出主機並去掉埠與路徑"
assert_eq "https://10.0.0.5" "$(runner_clone_url https://192.168.9.129 10.0.0.5)" "clone_url 把主機換成區網 IP"
assert_eq "http://10.0.0.5:8080" "$(runner_clone_url http://127.0.0.1:8080/ 10.0.0.5)" "保留埠、去掉結尾斜線"
assert_nonzero "區網 IP 不合法被拒絕" runner_clone_url https://a.b 999.1.1.1

# ── runner_cert_covers_host：憑證 SAN 是否涵蓋主機（用真的 openssl 產生的憑證）──
make_self_signed_cert 10.0.0.5 "$T_TMP/certs" >/dev/null
make_self_signed_cert gitlab.example.com "$T_TMP/certs" >/dev/null
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$T_TMP/cn.key" -out "$T_TMP/cn-only.crt" \
    -subj "/CN=10.0.0.5" 2>/dev/null
assert_status 0 "SAN 含該 IP" runner_cert_covers_host "$T_TMP/certs/10.0.0.5.crt" 10.0.0.5
assert_status 1 "SAN 不含另一個 IP" runner_cert_covers_host "$T_TMP/certs/10.0.0.5.crt" 10.0.0.6
assert_status 0 "SAN 含該網域" runner_cert_covers_host "$T_TMP/certs/gitlab.example.com.crt" gitlab.example.com
assert_status 1 "網域憑證不涵蓋其他網域" runner_cert_covers_host "$T_TMP/certs/gitlab.example.com.crt" other.example.com
assert_status 1 "只有 CN 沒有 SAN 的憑證視為不涵蓋" runner_cert_covers_host "$T_TMP/cn-only.crt" 10.0.0.5
assert_status 2 "憑證檔不存在回 2" runner_cert_covers_host "$T_TMP/nope.crt" 10.0.0.5

# ── valid_image_ref／valid_image_list：映像清單（會進 docker pull／save 的參數，擋注入）──
assert_status 0 "alpine:3.20 合法" valid_image_ref alpine:3.20
assert_status 0 "含 registry 與路徑合法" valid_image_ref registry.example.com:5000/team/app:1.2
assert_status 0 "docker:27-cli 合法" valid_image_ref docker:27-cli
assert_nonzero "含空白不合法" valid_image_ref "alpine 3"
assert_nonzero "分號不合法" valid_image_ref 'alpine;rm'
assert_nonzero "- 開頭會被當選項" valid_image_ref -alpine
assert_nonzero "空字串不合法" valid_image_ref ""
assert_status 0 "空白分隔的清單合法" valid_image_list "alpine:3.20 node:22"
assert_nonzero "清單內有一個不合法即整個不合法" valid_image_list "alpine:3.20 bad;x"
assert_nonzero "空清單不合法" valid_image_list ""

# ── runner_disk_low：剩餘空間（KB）低於門檻（GB）──
assert_status 0 "19 GB 低於 20 GB" runner_disk_low 19922944 20
assert_status 1 "恰好 20 GB 不算低" runner_disk_low 20971520 20
assert_status 2 "非數字回 2" runner_disk_low abc 20

# ── runner_set_concurrent：改 config.toml 的全域 concurrent ──
printf 'concurrent = 1\ncheck_interval = 0\n\n[[runners]]\n  name = "x"\n  concurrent = 99\n' >"$T_TMP/config.toml"
runner_set_concurrent "$T_TMP/config.toml" 3
assert_eq "concurrent = 3" "$(head -n1 "$T_TMP/config.toml")" "只改頂層 concurrent"
assert_contains "$(cat "$T_TMP/config.toml")" "  concurrent = 99" "不碰 [[runners]] 內的同名鍵"
printf 'check_interval = 0\n' >"$T_TMP/config2.toml"
runner_set_concurrent "$T_TMP/config2.toml" 2
assert_eq "concurrent = 2" "$(head -n1 "$T_TMP/config2.toml")" "沒有 concurrent 時補在最前面"
assert_nonzero "concurrent 必須是正整數" runner_set_concurrent "$T_TMP/config.toml" 0

# ── 接縫 B：runner_register（註冊 instance runner）──
# 佈置一台假的 GitLab 伺服器：假指令、假 /opt/gitlab、假 /etc/gitlab/ssl、假 /etc/gitlab-runner。
reg_env() { # reg_env <名稱>：建立沙盒並輸出其路徑；之後以 (cd 沙盒) 內使用
    local d="$T_TMP/$1"
    mkdir -p "$d/bin" "$d/opt-gitlab" "$d/ssl" "$d/runner-etc"
    make_stub "$d/bin" apt 'exit 0'
    make_stub "$d/bin" docker 'exit 0'
    make_stub "$d/bin" hostname 'echo 10.0.0.5'
    # 假的 gitlab-runner：register 時把收到的環境變數 token 記下來，並寫出一份 config.toml。
    make_stub "$d/bin" gitlab-runner '
if [ "$1" = register ]; then
    echo "TOKEN_SEEN=${CI_SERVER_TOKEN:-}" >>"$STUB_ENV_LOG"
    printf "concurrent = 1\n\n[[runners]]\n  name = \"gitlab-ci\"\n" >"$RUNNER_CONFIG_DIR/config.toml"
fi
exit 0'
    : >"$d/stub.log"
    : >"$d/stub-env.log"
    echo "$d"
}
reg_run() { # reg_run <沙盒> <stdin 文字>：回傳 register 的結束碼，輸出存 $d/out
    local d="$1" input="$2"
    (
        export PATH="$d/bin:$PATH" STUB_LOG="$d/stub.log" STUB_ENV_LOG="$d/stub-env.log"
        export GITLAB_OPT_DIR="$d/opt-gitlab" GITLAB_SSL_DIR="$d/ssl" RUNNER_CONFIG_DIR="$d/runner-etc"
        export OPS_FAKE_UID=0 OPS_ENV_FILE="$d/ops.env"
        runner_register <<<"$input" >"$d/out" 2>&1
    )
}

# 情境 1：HTTPS 自簽、SAN 涵蓋區網 IP → 註冊成功
d="$(reg_env ok)"
make_self_signed_cert 10.0.0.5 "$d/ssl" >/dev/null
env_file="$d/ops.env"
printf 'RNR_EXTERNAL_URL=https://10.0.0.5\nRNR_LAN_IP=10.0.0.5\nRNR_CA_FILE=%s\nRNR_CONCURRENT=2\n' "$d/ssl/10.0.0.5.crt" >"$env_file"
reg_run "$d" $'\n\n\n\nglrt-abcDEF123_-xyz'
rc=$?
assert_eq 0 "$rc" "SAN 涵蓋時註冊成功"
reglog="$(cat "$d/stub.log")"
assert_contains "$reglog" "gitlab-runner register --non-interactive" "以非互動模式呼叫 register"
assert_contains "$reglog" "--url https://10.0.0.5" "register 的 --url 是區網網址"
assert_contains "$reglog" "--clone-url https://10.0.0.5" "clone_url 指向區網 IP"
assert_contains "$reglog" "--executor docker" "使用 docker executor"
assert_contains "$reglog" "--docker-pull-policy if-not-present" "pull_policy 優先用本機 image"
assert_contains "$reglog" "--tls-ca-file $d/runner-etc/certs/10.0.0.5.crt" "tls-ca-file 指向複製後的 CA"
assert_not_contains "$reglog" "glrt-abcDEF123_-xyz" "token 不在命令列參數（stub 記錄的 argv）"
assert_contains "$(cat "$d/stub-env.log")" "TOKEN_SEEN=glrt-abcDEF123_-xyz" "token 以環境變數 CI_SERVER_TOKEN 傳給 register"
assert_not_contains "$(cat "$d/out")" "glrt-abcDEF123_-xyz" "token 不印到輸出"
assert_not_contains "$(cat "$env_file")" "glrt-" "token 不寫參數檔"
assert_status 0 "CA 已複製到 Runner 的 certs 目錄" test -f "$d/runner-etc/certs/10.0.0.5.crt"
assert_eq "concurrent = 2" "$(head -n1 "$d/runner-etc/config.toml")" "concurrent 依參數設為 2"

# 情境 2：SAN 不涵蓋區網 IP → 中止，且完全沒呼叫 register
d="$(reg_env san)"
make_self_signed_cert 10.0.0.9 "$d/ssl" >/dev/null
printf 'RNR_EXTERNAL_URL=https://10.0.0.9\nRNR_LAN_IP=10.0.0.5\nRNR_CA_FILE=%s\nRNR_CONCURRENT=1\n' "$d/ssl/10.0.0.9.crt" >"$d/ops.env"
reg_run "$d" $'\n\n\n\nglrt-abc' && rc=0 || rc=$?
assert_eq 1 "$rc" "SAN 不涵蓋區網 IP 時中止"
assert_not_contains "$(cat "$d/stub.log")" "register" "SAN 不符時沒有呼叫 register"
assert_contains "$(cat "$d/out")" "subjectAltName" "訊息說明是 SAN 的問題"
assert_status 1 "SAN 不符時不留下複製過去的憑證" test -f "$d/runner-etc/certs/10.0.0.5.crt"

# 情境 3：token 格式不對 → 中止，沒呼叫 register
d="$(reg_env badtok)"
make_self_signed_cert 10.0.0.5 "$d/ssl" >/dev/null
printf 'RNR_EXTERNAL_URL=https://10.0.0.5\nRNR_LAN_IP=10.0.0.5\nRNR_CA_FILE=%s\nRNR_CONCURRENT=1\n' "$d/ssl/10.0.0.5.crt" >"$d/ops.env"
reg_run "$d" $'\n\n\n\nnot a token' && rc=0 || rc=$?
assert_eq 1 "$rc" "token 不是 glrt- 開頭時中止"
assert_not_contains "$(cat "$d/stub.log")" "register" "token 不合法時沒有呼叫 register"

# 情境 4：http（不需要 CA）→ 不要求憑證，不帶 --tls-ca-file
d="$(reg_env http)"
printf 'RNR_EXTERNAL_URL=http://127.0.0.1\nRNR_LAN_IP=10.0.0.5\nRNR_CONCURRENT=1\n' >"$d/ops.env"
reg_run "$d" $'\n\n\nglrt-abc' && rc=0 || rc=$?
assert_eq 0 "$rc" "http 註冊成功"
assert_contains "$(cat "$d/stub.log")" "--clone-url http://10.0.0.5" "http 的 clone_url"
assert_not_contains "$(cat "$d/stub.log")" "--tls-ca-file" "http 不帶 tls-ca-file"

# 情境 5：已註冊過 → 不重複註冊
d="$(reg_env again)"
printf 'RNR_EXTERNAL_URL=http://127.0.0.1\nRNR_LAN_IP=10.0.0.5\nRNR_CONCURRENT=1\n' >"$d/ops.env"
reg_run "$d" $'\n\n\nglrt-abc'
: >"$d/stub.log"
reg_run "$d" $'\n\n\nglrt-abc' && rc=0 || rc=$?
assert_eq 0 "$rc" "重跑結束碼 0"
assert_not_contains "$(cat "$d/stub.log")" "register" "已註冊過時不再呼叫 register"
assert_contains "$(cat "$d/out")" "已註冊" "訊息告知已註冊、可先取消註冊再重來"

# 情境 6：非 root → 中止
d="$(reg_env noroot)"
( export PATH="$d/bin:$PATH" GITLAB_OPT_DIR="$d/opt-gitlab" OPS_FAKE_UID=1000 OPS_ENV_FILE="$d/ops.env"; runner_register </dev/null >/dev/null 2>&1 ) && rc=0 || rc=$?
assert_eq 1 "$rc" "非 root 時中止"

# ── 接縫 B：runner_install_offline（解包、版本比對、磁碟警告、dpkg -i）──
inst_env() { # inst_env <名稱> <GitLab 版本> <Runner deb 版本> <剩餘 KB>：建立沙盒與離線包
    local d="$T_TMP/$1"
    mkdir -p "$d/bin" "$d/opt-gitlab" "$d/debs"
    printf 'gitlab-ce %s\n' "$2" >"$d/opt-gitlab/version-manifest.txt"
    printf 'x' >"$d/debs/gitlab-runner_amd64.deb"
    printf 'x' >"$d/debs/gitlab-runner-helper-images.deb"
    printf 'x' >"$d/debs/docker.io_26.1.3-0ubuntu1~24.04.1_amd64.deb"
    pack_offline "$d/debs" "$d/runner-offline.tar.gz" >/dev/null
    make_stub "$d/bin" apt 'exit 0'
    make_stub "$d/bin" dpkg 'exit 0'
    make_stub "$d/bin" dpkg-deb "echo $3"
    make_stub "$d/bin" systemctl 'exit 0'
    make_stub "$d/bin" docker 'exit 0'
    make_stub "$d/bin" df "printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 100 1 $4 1%% /\n'"
    : >"$d/stub.log"
    printf 'RNR_TARBALL=%s\n' "$d/runner-offline.tar.gz" >"$d/ops.env"
    echo "$d"
}
inst_run() { # inst_run <沙盒> <stdin 文字>
    local d="$1"
    (
        export PATH="$d/bin:$PATH" STUB_LOG="$d/stub.log" GITLAB_OPT_DIR="$d/opt-gitlab"
        export OPS_FAKE_UID=0 OPS_ENV_FILE="$d/ops.env" DOCKER_DATA_DIR="$d"
        runner_install_offline <<<"$2" >"$d/out" 2>&1
    )
}

d="$(inst_env instok 18.10.3 18.10.0-1 99999999)"
inst_run "$d" $'
yes' && rc=0 || rc=$?
assert_eq 0 "$rc" "版本一致且空間足夠時安裝成功"
assert_contains "$(cat "$d/stub.log")" "dpkg -i" "呼叫 dpkg -i"
assert_contains "$(cat "$d/stub.log")" "gitlab-runner_amd64.deb" "安裝清單含 gitlab-runner"
assert_contains "$(cat "$d/stub.log")" "gitlab-runner-helper-images.deb" "安裝清單含 helper images"
assert_not_contains "$(cat "$d/out")" "警告" "一致且空間足夠時沒有警告"

d="$(inst_env instver 18.10.3 18.9.0-1 99999999)"
inst_run "$d" $'
no' && rc=0 || rc=$?
assert_eq 0 "$rc" "版本不一致時取消仍是正常結束"
assert_contains "$(cat "$d/out")" "警告" "版本不一致時警告"
assert_contains "$(cat "$d/out")" "18.9" "警告中列出 Runner 版本"
assert_not_contains "$(cat "$d/stub.log")" "dpkg -i" "版本不一致且使用者拒絕時不安裝"

d="$(inst_env instver2 18.10.3 18.9.0-1 99999999)"
inst_run "$d" $'\nyes\nyes' && rc=0 || rc=$?
assert_contains "$(cat "$d/stub.log")" "dpkg -i" "版本不一致但使用者確認後仍安裝"

d="$(inst_env instdisk 18.10.3 18.10.0-1 10485760)"
inst_run "$d" $'
no' && rc=0 || rc=$?
assert_contains "$(cat "$d/out")" "警告" "剩餘空間低於 20 GB 時警告"
assert_not_contains "$(cat "$d/stub.log")" "dpkg -i" "空間不足且使用者拒絕時不安裝"

d="$(inst_env instbad 18.10.3 18.10.0-1 99999999)"
printf 'not a tar' >"$d/runner-offline.tar.gz"
inst_run "$d" $'
yes' && rc=0 || rc=$?
assert_eq 1 "$rc" "離線包損壞時中止"
assert_not_contains "$(cat "$d/stub.log")" "dpkg -i" "離線包損壞時不安裝"

# ── 接縫 B：runner_build_offline（【有網路的電腦】打離線套件）──
bld_env() { # bld_env <名稱> [curl 是否失敗]
    local d="$T_TMP/$1"
    mkdir -p "$d/bin"
    make_stub "$d/bin" apt 'exit 0'
    make_stub "$d/bin" apt-cache 'printf "docker.io\n  Depends: runc\nrunc\n"'
    make_stub "$d/bin" apt-get 'shift; for p in "$@"; do : >"${p}_1.0_amd64.deb"; done'
    if [ "${2:-}" = fail ]; then
        make_stub "$d/bin" curl 'exit 22'
    else
        make_stub "$d/bin" curl 'while [ $# -gt 0 ]; do [ "$1" = -o ] && { : >"$2"; }; shift; done'
    fi
    : >"$d/stub.log"
    echo "$d"
}
bld_run() { # bld_run <沙盒> <stdin>
    local d="$1"
    (
        export PATH="$d/bin:$PATH" STUB_LOG="$d/stub.log" OPS_ENV_FILE="$d/ops.env" TMPDIR="$d"
        runner_build_offline <<<"$2" >"$d/out" 2>&1
    )
}

d="$(bld_env bldok)"
printf 'RNR_TARBALL=%s\nRNR_RUNNER_VERSION=18.10.0\n' "$d/out.tar.gz" >"$d/ops.env"
bld_run "$d" $'\n\n' && rc=0 || rc=$?
assert_eq 0 "$rc" "離線套件打包成功"
list="$(tar tzf "$d/out.tar.gz" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "docker.io_1.0_amd64.deb gitlab-runner-helper-images.deb gitlab-runner_amd64.deb runc_1.0_amd64.deb " "$list" "包內是 docker.io 與其相依、runner、helper images"
assert_contains "$(cat "$d/stub.log")" "v18.10.0/deb/gitlab-runner_amd64.deb" "依指定版本下載 runner"
assert_contains "$(cat "$d/stub.log")" "v18.10.0/deb/gitlab-runner-helper-images.deb" "依指定版本下載 helper images"
assert_status 0 "產出的離線包通過安裝端的檢查" check_offline_tar "$d/out.tar.gz"

d="$(bld_env bldfail fail)"
printf 'RNR_TARBALL=%s\nRNR_RUNNER_VERSION=18.10.0\n' "$d/out.tar.gz" >"$d/ops.env"
bld_run "$d" $'\n\n' && rc=0 || rc=$?
assert_eq 1 "$rc" "下載失敗時中止"
assert_status 1 "下載失敗時不產生離線包" test -f "$d/out.tar.gz"

d="$(bld_env bldver)"
printf 'RNR_TARBALL=%s\n' "$d/out.tar.gz" >"$d/ops.env"
bld_run "$d" $'\n18.10.0;rm\n' && rc=0 || rc=$?
assert_eq 1 "$rc" "Runner 版本含非法字元時中止"
assert_not_contains "$(cat "$d/stub.log")" "curl" "版本不合法時沒有下載任何東西"

# ── 接縫 B：映像包（runner_build_images／runner_load_images）──
img_env() { # img_env <名稱>
    local d="$T_TMP/$1"
    mkdir -p "$d/bin" "$d/opt-gitlab"
    make_stub "$d/bin" apt 'exit 0'
    make_stub "$d/bin" docker 'if [ "$1" = save ]; then : >"$3"; fi; exit 0'
    : >"$d/stub.log"
    echo "$d"
}
img_run() { # img_run <沙盒> <函式> <stdin>
    local d="$1"
    (
        export PATH="$d/bin:$PATH" STUB_LOG="$d/stub.log" OPS_ENV_FILE="$d/ops.env" GITLAB_OPT_DIR="$d/opt-gitlab" OPS_FAKE_UID=0 TMPDIR="$d"
        printf "%s" "$3" | "$2" >"$d/out" 2>&1
    )
}

d="$(img_env imgok)"
printf 'RNR_IMAGES_TAR=%s\nRNR_IMAGES=alpine:3.20 node:22\n' "$d/images.tar" >"$d/ops.env"
img_run "$d" runner_build_images $'\n' && rc=0 || rc=$?
assert_eq 0 "$rc" "映像包打包成功"
assert_contains "$(cat "$d/stub.log")" "docker pull alpine:3.20" "拉第一個 image"
assert_contains "$(cat "$d/stub.log")" "docker pull node:22" "拉第二個 image"
assert_contains "$(cat "$d/stub.log")" "alpine:3.20 node:22" "save 一次存下整份清單"
assert_status 0 "產出映像包" test -f "$d/images.tar"

d="$(img_env imgbad)"
printf 'RNR_IMAGES_TAR=%s\n' "$d/images.tar" >"$d/ops.env"
img_run "$d" runner_build_images $'\nalpine;rm -rf' && rc=0 || rc=$?
assert_eq 1 "$rc" "映像清單含非法字元時中止"
assert_not_contains "$(cat "$d/stub.log")" "docker pull" "非法清單時沒有拉任何 image"

d="$(img_env imgload)"
: >"$d/images.tar"
printf 'RNR_IMAGES_TAR=%s\n' "$d/images.tar" >"$d/ops.env"
img_run "$d" runner_load_images $'\n' && rc=0 || rc=$?
assert_eq 0 "$rc" "載入映像包成功"
assert_contains "$(cat "$d/stub.log")" "docker load -i $d/images.tar" "以 docker load -i 載入"

d="$(img_env imgmissing)"
printf 'RNR_IMAGES_TAR=%s\n' "$d/none.tar" >"$d/ops.env"
img_run "$d" runner_load_images $'\n' && rc=0 || rc=$?
assert_eq 1 "$rc" "找不到映像包時中止"

# ── 接縫 B：取消註冊、清理、驗證 ──
d="$(img_env misc)"
make_stub "$d/bin" gitlab-runner 'exit 0'
printf 'concurrent = 1\n\n[[runners]]\n  name = "gitlab-ci"\n' >"$d/config.toml"
mk() { ( export PATH="$d/bin:$PATH" STUB_LOG="$d/stub.log" OPS_ENV_FILE="$d/ops.env" GITLAB_OPT_DIR="$d/opt-gitlab" OPS_FAKE_UID=0 RUNNER_CONFIG_DIR="$d"; "$1" <<<"$2" >"$d/out" 2>&1 ); }
mk runner_unregister "no" && rc=0 || rc=$?
assert_eq 0 "$rc" "取消註冊被拒絕時正常結束"
assert_not_contains "$(cat "$d/stub.log")" "unregister" "拒絕時不呼叫 unregister"
mk runner_unregister "yes"
assert_contains "$(cat "$d/stub.log")" "gitlab-runner unregister --name gitlab-ci" "確認後以名稱取消註冊"
assert_contains "$(cat "$d/out")" "後台" "提醒到後台刪除 Runner"

: >"$d/stub.log"
mk runner_cleanup "no"
assert_not_contains "$(cat "$d/stub.log")" "prune" "拒絕時不清理"
mk runner_cleanup "yes"
assert_contains "$(cat "$d/stub.log")" "docker system prune -f" "確認後只清未使用的懸空資源（不加 -a）"
assert_not_contains "$(cat "$d/stub.log")" "prune -a" "不刪除已載入的 image"

: >"$d/stub.log"
mk runner_verify ""
assert_contains "$(cat "$d/stub.log")" "gitlab-runner verify" "驗證呼叫 gitlab-runner verify"
assert_contains "$(cat "$d/stub.log")" "docker info" "驗證呼叫 docker info"
assert_contains "$(cat "$d/out")" "image: alpine:3.20" "印出範例 .gitlab-ci.yml"

# ── 說明與排查、選單 ──
assert_contains "$(show_help)" "Runner" "說明有內容"
assert_contains "$(show_troubleshooting)" "x509" "排查含憑證錯誤"
assert_contains "$(show_menu)" "註冊" "選單有註冊項目"
assert_status 2 "帶參數被拒絕" bash "$rnr" foo
out="$(bash "$rnr" </dev/null 2>&1)" && rc=0 || rc=$?
assert_eq 0 "$rc" "stdin EOF 時離開選單"
out="$(printf '99\nq\n' | bash "$rnr" 2>&1)"
assert_contains "$out" "無此選項：99" "無此選項時提示"
