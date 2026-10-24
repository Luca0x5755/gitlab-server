#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# docker.sh 的純函式（接縫 A）、動作函式（接縫 B，假 docker／apt）、選單行程（接縫 C）。
# 期望值一律寫死字面值，不用被測程式重算。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
dkr="$here/../docker.sh"

# source 取得函式：main 守門，source 時不啟動選單。
. "$dkr"

# ══ 接縫 A：純函式 ════════════════════════════════════════════════════════════

# ── docker_image_ref：映像 tag 組合（PR-DKR-01）──
assert_eq "gitlab/gitlab-ce:18.10.3-ce.0" "$(docker_image_ref 18.10.3-ce.0)" "映像參照為 gitlab/gitlab-ce:<版本>-ce.0"
assert_nonzero "非法版本不組合映像參照" docker_image_ref "18.10.3;id"
assert_nonzero "缺 -ce 後綴不組合映像參照" docker_image_ref 18.10.3

# ── docker_normalize_versions：補後綴、數值排序、去重（PR-DKR-02）──
assert_eq "18.10.3-ce.0"$'\n'"18.11.13-ce.0"$'\n'"19.2.9-ce.0"$'\n'"19.5.1-ce.0" \
    "$(docker_normalize_versions "19.5.1 18.10.3 19.2.9 18.11.13")" "亂序輸入依版本數值由小到大"
assert_eq "18.7.6-ce.0"$'\n'"18.10.3-ce.0" "$(docker_normalize_versions "18.10.3 18.7.6")" "18.7 排在 18.10 前（非字串排序）"
assert_eq "18.10.3-ce.0" "$(docker_normalize_versions "18.10.3 18.10.3-ce.0")" "同版本重複只留一個"
assert_eq "18.10.3-ce.0" "$(docker_normalize_versions "  18.10.3  ")" "容忍前後空白"
assert_nonzero "含非法版本整批拒絕" docker_normalize_versions "18.10.3 abc"
assert_eq "" "$(docker_normalize_versions "18.10.3 abc" 2>/dev/null)" "含非法版本時不輸出任何 tag"
assert_nonzero "空清單拒絕" docker_normalize_versions ""

# ── docker_locale_dockerfile：把 deb 時代資料庫的 locale 烤進映像 ──
df="$(docker_locale_dockerfile gitlab/gitlab-ce:19.5.1-ce.0 zh_TW.UTF-8)"
assert_contains "$df" "FROM gitlab/gitlab-ce:19.5.1-ce.0" "Dockerfile 以官方映像為底"
assert_contains "$df" "apt-get install -y --no-install-recommends locales" "安裝 locales 套件"
assert_contains "$df" "localedef -i zh_TW -f UTF-8 zh_TW.UTF-8" "產生 zh_TW.UTF-8"
assert_contains "$df" "grep -qi '^zh_TW\.UTF8$'" "建置時驗證 locale -a 看得到"
assert_nonzero "locale 含注入字元拒絕" docker_locale_dockerfile x 'zh_TW.UTF-8;id'
assert_nonzero "locale 格式錯誤拒絕" docker_locale_dockerfile x zhTW

# ── valid_docker_version_list ──
assert_status 0 "預設清單合法" valid_docker_version_list "$GLC_DEFAULT_VERSIONS"
assert_eq "18.10.3 18.11.13 19.2.9 19.5.1" "$GLC_DEFAULT_VERSIONS" "預設版本清單"
assert_status 1 "空清單不合法" valid_docker_version_list ""
assert_status 1 "含注入字元不合法" valid_docker_version_list '18.10.3 $(id)'

# ══ 接縫 B：動作函式（PATH 放假 docker／apt；真實 docker 動作不在此驗證）══════════

# 佈置沙箱：假 apt（過機器檢查）與假 docker。FAIL_PULL=<版本字串> 使該映像 pull 失敗。
setup_sandbox() { # setup_sandbox <名稱>
    SB="$T_TMP/$1"
    rm -rf "$SB"
    mkdir -p "$SB/bin" "$SB/out"
    export HOME="$SB"
    export STUB_LOG="$SB/stub.log"
    : >"$STUB_LOG"
    export OPS_ENV_FILE="$SB/ops.env"
    make_stub "$SB/bin" apt 'exit 0'
    make_stub "$SB/bin" docker '
case "$1" in
    pull) [ -n "${FAIL_PULL:-}" ] && [[ $2 == *"$FAIL_PULL"* ]] && exit 1; exit 0 ;;
    save) [ "${FAIL_SAVE:-}" = 1 ] && exit 1; [ "$2" = "-o" ] && echo fake-tar >"$3"; exit 0 ;;
    build) cat >"$STUB_LOG.dockerfile"; [ "${FAIL_BUILD:-}" = 1 ] && exit 1; exit 0 ;;
    load) exit 0 ;;
    images) printf "gitlab/gitlab-ce   18.10.3-ce.0   abc   1 week ago   2GB\n"; exit 0 ;;
esac'
    export PATH="$SB/bin:$PATH"
}

# ── docker_build_bundle（PR-DKR-01、PR-DKR-02、PR-COM-05）──
setup_sandbox build_ok
printf '%s\n%s\n' "19.5.1 18.10.3" "$SB/out/gl.tar" | docker_build_bundle >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "全部 pull 成功：結束碼 0"
assert_eq "docker pull gitlab/gitlab-ce:18.10.3-ce.0"$'
'"docker pull gitlab/gitlab-ce:19.5.1-ce.0"$'
'"docker build -t gitlab/gitlab-ce:18.10.3-ce.0 -"$'
'"docker build -t gitlab/gitlab-ce:19.5.1-ce.0 -"$'
'"docker save -o $SB/out/gl.tar.tmp gitlab/gitlab-ce:18.10.3-ce.0 gitlab/gitlab-ce:19.5.1-ce.0" \
    "$(sed -E 's#-o [^ ]*/([^/ ]*)\.[A-Za-z0-9]{6} #-o '"$SB"'/out/\1.tmp #' "$STUB_LOG")" "依版本順序逐一 pull、補 locale（build），再單一 docker save"
assert_status 0 "產生 tar" test -f "$SB/out/gl.tar"
assert_eq "" "$(ls "$SB/out" | grep -v '^gl.tar$' || true)" "輸出目錄沒有暫存殘留"
assert_contains "$(cat "$OPS_ENV_FILE")" "GLC_VERSIONS=19.5.1 18.10.3" "版本清單存入參數檔"
assert_contains "$(cat "$OPS_ENV_FILE")" "GLC_BUNDLE_TAR=$SB/out/gl.tar" "tar 路徑存入參數檔"
assert_contains "$(cat "$STUB_LOG.dockerfile")" "localedef -i zh_TW -f UTF-8 zh_TW.UTF-8" "補 locale：Dockerfile 產生預設 zh_TW.UTF-8"

setup_sandbox build_pullfail
FAIL_PULL=18.11.13 bash -c ". '$dkr'; printf '%s\n%s\n' '18.10.3 18.11.13 19.2.9' '$SB/out/gl.tar' | docker_build_bundle" >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "任一 pull 失敗：非 0"
assert_eq "" "$(ls "$SB/out")" "任一 pull 失敗：不產生 tar、不留殘留"
assert_not_contains "$(cat "$STUB_LOG")" "docker save" "任一 pull 失敗：不呼叫 docker save"
assert_contains "$(cat "$SB/o.txt")" "18.11.13" "pull 失敗訊息點名版本"

setup_sandbox build_savefail
FAIL_SAVE=1 bash -c ". '$dkr'; printf '%s\n%s\n' '18.10.3' '$SB/out/gl.tar' | docker_build_bundle" >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "docker save 失敗：非 0"
assert_eq "" "$(ls "$SB/out")" "docker save 失敗：不留半成品 tar"

setup_sandbox build_localefail
FAIL_BUILD=1 bash -c ". '$dkr'; printf '%s
%s
' '18.10.3' '$SB/out/gl.tar' | docker_build_bundle" >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "1" "$r" "補 locale 失敗：非 0"
assert_eq "" "$(ls "$SB/out")" "補 locale 失敗：不產生 tar"
assert_not_contains "$(cat "$STUB_LOG")" "docker save" "補 locale 失敗：不呼叫 docker save"

setup_sandbox build_badlist
printf '%s\n%s\n%s\n' "18.10.3 abc" "18.11.13" "$SB/out/gl.tar" | bash -c ". '$dkr'; docker_build_bundle" >"$SB/o.txt" 2>&1 && r=0 || r=$?
assert_eq "0" "$r" "版本清單非法：重問，改用合法答案後成功"
assert_eq "docker pull gitlab/gitlab-ce:18.11.13-ce.0" "$(grep '^docker pull' "$STUB_LOG")" "版本清單非法：非法那一批一個都不拉"
assert_contains "$(cat "$OPS_ENV_FILE")" "GLC_VERSIONS=18.11.13" "只有合法的清單才存入參數檔"

# ── 機器角色（PR-COM-04）：缺 apt／docker 即中止並說明 ──
setup_sandbox role
printf '#!/bin/sh\nexit 1\n' >"$SB/bin/apt"
have_cmd() { [ "$1" != apt ] && command -v "$1" >/dev/null 2>&1; }
out="$( (docker_build_bundle </dev/null) 2>&1)" && r=0 || r=$?
assert_eq "1" "$r" "打包：缺 apt 即中止"
assert_contains "$out" "【有網路的電腦】" "打包：說明應在【有網路的電腦】執行"
out="$( (docker_load_bundle </dev/null) 2>&1)" && r=0 || r=$?
assert_eq "1" "$r" "載入：缺 apt 即中止"
assert_contains "$out" "【GitLab 伺服器】" "載入：說明應在【GitLab 伺服器】執行"
have_cmd() { [ "$1" != docker ] && command -v "$1" >/dev/null 2>&1; }
out="$( (docker_build_bundle </dev/null) 2>&1)" && r=0 || r=$?
assert_eq "1" "$r" "打包：缺 docker 即中止"
assert_contains "$out" "缺少指令 docker" "打包：缺 docker 時點名指令"
out="$( (OPS_FAKE_UID=0 docker_load_bundle </dev/null) 2>&1)" && r=0 || r=$?
assert_eq "1" "$r" "載入：缺 docker 即中止"
assert_contains "$out" "缺少指令 docker" "載入：缺 docker 時點名指令"
assert_contains "$out" "【GitLab 伺服器】" "載入：缺 docker 時說明角色"
unset -f have_cmd
. "$dkr"
. "$here/../lib/common.sh"

setup_sandbox load_nonroot
echo x >"$SB/in.tar"
out="$(printf '%s\n' "$SB/in.tar" | OPS_FAKE_UID=1000 docker_load_bundle 2>&1)" && r=0 || r=$?
assert_eq "1" "$r" "載入：非 root 即中止"
assert_not_contains "$(cat "$STUB_LOG")" "docker load" "載入：非 root 不呼叫 docker load"

# ── docker_load_bundle（PR-DKR-03）──
setup_sandbox load_ok
echo x >"$SB/in.tar"
out="$(printf '%s\n' "$SB/in.tar" | OPS_FAKE_UID=0 docker_load_bundle 2>&1)" && r=0 || r=$?
assert_eq "0" "$r" "載入成功：結束碼 0"
assert_contains "$(cat "$STUB_LOG")" "docker load -i $SB/in.tar" "以 docker load -i 載入指定 tar"
assert_contains "$(cat "$STUB_LOG")" "docker images gitlab/gitlab-ce" "載入後查詢 gitlab/gitlab-ce"
assert_contains "$out" "18.10.3-ce.0" "載入後列出已有的 tag"

setup_sandbox load_missing
out="$(printf '%s\n' "$SB/none.tar" | OPS_FAKE_UID=0 docker_load_bundle 2>&1)" && r=0 || r=$?
assert_eq "1" "$r" "檔案不存在：中止"
assert_not_contains "$(cat "$STUB_LOG")" "docker load" "檔案不存在：不呼叫 docker load"
assert_contains "$out" "$SB/none.tar" "檔案不存在：訊息點名路徑"

# ══ 接縫 C：選單行程 ══════════════════════════════════════════════════════════

assert_status 2 "帶任何參數即拒絕" bash "$dkr" foo
assert_status 2 "帶空字串參數也拒絕" bash "$dkr" ""
out="$(printf 'q\n' | bash "$dkr" 2>&1)" && r=0 || r=$?
assert_eq "0" "$r" "選單輸入 q：結束碼 0"
assert_contains "$out" "打包 GitLab 映像包" "選單有打包項目"
assert_contains "$out" "載入 GitLab 映像包" "選單有載入項目"
assert_contains "$out" "【有網路的電腦】" "選單標示【有網路的電腦】"
assert_contains "$out" "【GitLab 伺服器】" "選單標示【GitLab 伺服器】"
out="$(bash -c ". '$dkr'" 2>&1)"
assert_eq "" "$out" "source 本檔頂層不產生輸出"
assert_status 0 "menu_loop、show_menu、dispatch 皆有定義" bash -c ". '$dkr'; declare -F menu_loop show_menu dispatch"
menu="$(show_menu)"
assert_contains "$(grep '打包 GitLab 映像包' <<<"$menu")" "【有網路的電腦】" "打包那一行標示【有網路的電腦】"
assert_contains "$(grep '載入 GitLab 映像包' <<<"$menu")" "【GitLab 伺服器】" "載入那一行標示【GitLab 伺服器】"
assert_not_contains "$(grep '打包 GitLab 映像包' <<<"$menu")" "【GitLab 伺服器】" "打包那一行不標示【GitLab 伺服器】"
