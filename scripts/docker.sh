#!/usr/bin/env bash
# GitLab 容器（Docker）選單腳本：打包與載入 GitLab 映像包。只有互動選單，不收參數。
# 頂層只定義函式，不執行任何動作；`set -euo pipefail` 與 `cd` 都在 main 內，
# 所以測試可以 source 本檔取得函式而不啟動選單。
#
# 後續票（遷移、逐站升級、說明與排查）在對應分區追加。

_glc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_glc_dir/lib/common.sh"

# 升級路徑上的停靠站（各 minor 的最新 patch，依 Upgrade Path Tool）；可由 ask_param 修改。
GLC_DEFAULT_VERSIONS="18.10.3 18.11.13 19.2.9 19.5.1"
# 映像 tag 的後綴固定 -ce.0（使用者輸入 18.10.3 時自動補上）。
GLC_TAG_SUFFIX="-ce.0"

# ── 純函式 ───────────────────────────────────────────────────────────────────

# 單一版本補成 X.Y.Z-ce.N 形式（已帶 -ce.N 的不動）。不驗證，交給 valid_gitlab_version。
_glc_with_suffix() {
    case "$1" in
        *-ce.*) echo "$1" ;;
        *) echo "$1$GLC_TAG_SUFFIX" ;;
    esac
}

# 映像參照：gitlab/gitlab-ce:<版本>-ce.N。版本須是完整 X.Y.Z-ce.N，否則回非 0。
docker_image_ref() { # docker_image_ref <X.Y.Z-ce.N>
    valid_gitlab_version "$1" || return 1
    echo "gitlab/gitlab-ce:$1"
}

# 空白分隔的版本清單 → 每行一個 X.Y.Z-ce.N，依數值由小到大、去重。
# 清單為空或任一項非法：回非 0 且不輸出任何 tag（寧可中止也不要少拉一版）。
docker_normalize_versions() { # docker_normalize_versions "<清單>"
    local v n=0 list=""
    for v in $1; do
        v="$(_glc_with_suffix "$v")"
        valid_gitlab_version "$v" || { echo "✗ 版本格式不符：$v" >&2; return 1; }
        list+="$v"$'\n'
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || { echo "✗ 版本清單是空的。" >&2; return 1; }
    printf '%s' "$list" | sort_versions asc | awk '!seen[$0]++'
}

# ask_param 用的驗證函式：清單合法回 0。
valid_docker_version_list() { docker_normalize_versions "$1" >/dev/null 2>&1; }

# ── 動作 ─────────────────────────────────────────────────────────────────────

# 【有網路的電腦】依版本清單逐一 docker pull，再 docker save 成單一 GitLab 映像包。
# 任一 pull 失敗、或 save 失敗，都不留下 tar（先寫暫存檔，成功才 mv 到位）。
docker_build_bundle() {
    local versions tag ref tar_file tmp rc=0 refs=() tags
    require_machine online
    require_cmds docker
    versions="$(ask_param GLC_VERSIONS "GitLab 版本清單（空白分隔）" "$GLC_DEFAULT_VERSIONS" valid_docker_version_list)" \
        || die "版本清單不合法（須為 X.Y.Z 形式，例如 18.10.3，以空白分隔）。"
    tar_file="$(ask_param GLC_BUNDLE_TAR "GitLab 映像包輸出路徑" "$(sudo_home_dir)/gitlab-images.tar" valid_local_path)" \
        || die "映像包路徑不合法。"
    tags="$(docker_normalize_versions "$versions")" || die "版本清單不合法。"
    # 先全部 pull 完才 save：任何一版失敗就在這裡中止，不會有 tar。
    # 以陣列＋for 迭代而不用 while read：避免 docker 子程序吞掉迴圈的 stdin。
    for tag in $tags; do refs+=("$(docker_image_ref "$tag")"); done
    for ref in "${refs[@]}"; do
        docker pull "$ref" || die "拉取 $ref 失敗。請確認這台可連外、該版本存在。"
    done
    tmp="$(mktemp "$tar_file.XXXXXX")" || die "無法在 $(dirname "$tar_file") 建立暫存檔。"
    docker save -o "$tmp" "${refs[@]}" || rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$tmp"; die "docker save 失敗，未產生映像包。"; fi
    chmod 644 "$tmp" && mv -f "$tmp" "$tar_file" || { rm -f "$tmp"; die "無法寫入 $tar_file。"; }
    echo "✓ 已產生 GitLab 映像包：$tar_file（請以 scp 傳到【GitLab 伺服器】）"
}

# 【GitLab 伺服器】docker load 載入 GitLab 映像包，並列出已有的 gitlab/gitlab-ce tag。
# 用 ubuntu 角色而非 server：purge 舊 deb 後 /opt/gitlab 不在了，下一批映像包仍要能載入。
docker_load_bundle() {
    local tar_file
    require_machine ubuntu docker
    require_root
    tar_file="$(ask_param GLC_BUNDLE_TAR "GitLab 映像包路徑" "$(sudo_home_dir)/gitlab-images.tar" valid_local_path)" \
        || die "映像包路徑不合法。"
    [ -f "$tar_file" ] || die "找不到映像包：$tar_file"
    docker load -i "$tar_file" || die "docker load 失敗。"
    echo "已有的 gitlab/gitlab-ce 映像："
    docker images gitlab/gitlab-ce || die "無法列出映像。"
    echo "✓ 已載入 GitLab 映像包。"
}

# 【有網路的電腦】打 Docker 離線包：docker.io 與其全部相依的 .deb（解析與下載是與 runner.sh 共用的
# docker_download_debs）。檔名預設 docker-offline.tar.gz，與 runner.sh 的 runner-offline.tar.gz 分開，不互相覆蓋。
docker_build_offline() {
    local tarball stage rc=0
    require_machine online
    require_cmds apt-get apt-cache tar
    tarball="$(ask_param GLC_DOCKER_TAR "Docker 離線包輸出路徑" "$(sudo_home_dir)/docker-offline.tar.gz" valid_local_path)" \
        || die "離線包路徑不合法。"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/docker-offline.XXXXXX")" || die "建立暫存目錄失敗。"
    # 在 `|| rc=$?` 內 set -e 會失效，所以每步都明確檢查。
    if docker_download_debs "$stage" && pack_offline "$stage" "$tarball"; then
        echo "✓ 已產生 Docker 離線包：$tarball（請以 scp 傳到【GitLab 伺服器】）"
    else
        rc=1
    fi
    rm -rf "$stage"
    return "$rc"
}

# 【GitLab 伺服器】解開 Docker 離線包、dpkg -i 安裝並啟用 docker 服務。
# 用 ubuntu 角色：安裝 Docker 發生在 GitLab 容器之前，不要求 /opt/gitlab。
docker_install_offline() {
    local tarball dir rc=0
    require_machine ubuntu dpkg tar systemctl
    require_root
    tarball="$(ask_param GLC_DOCKER_TAR "Docker 離線包路徑" "$(sudo_home_dir)/docker-offline.tar.gz" valid_local_path)" \
        || die "離線包路徑不合法。"
    [ -f "$tarball" ] || die "找不到離線包：$tarball"
    dir="$(mktemp -d "${TMPDIR:-/tmp}/docker-install.XXXXXX")" || die "建立暫存目錄失敗。"
    unpack_offline_tar "$tarball" "$dir" || { rm -rf "$dir"; die "離線包無法安全解開：$tarball"; }
    install_debs_in "$dir" || rc=$?
    rm -rf "$dir"
    [ "$rc" -ne 100 ] || return 0 # 使用者取消：已說明，不算失敗
    [ "$rc" -eq 0 ] || return "$rc"
    docker_enable_service
    echo "✓ 已安裝 Docker。下一步：載入 GitLab 映像包。"
}

# ── 選單 ─────────────────────────────────────────────────────────────────────

show_menu() {
    cat <<'TXT'
=== GitLab 容器（Docker）===
  1) 打包 GitLab 映像包（docker save）  【有網路的電腦】
  2) 載入 GitLab 映像包（docker load）  【GitLab 伺服器】
  3) 打包 Docker 離線包                【有網路的電腦】
  4) 安裝 Docker（含啟用服務）          【GitLab 伺服器】
  q) 離開
TXT
}

dispatch() {
    case "$1" in
        1) docker_build_bundle ;;
        2) docker_load_bundle ;;
        3) docker_build_offline ;;
        4) docker_install_offline ;;
        *) echo "✗ 無此選項：$1" >&2 ;;
    esac
}

# ── 入口（頂層不得執行任何動作；被 source 時不啟動）──────────────────────────

main() {
    set -euo pipefail
    reject_args "$@"
    cd "$(dirname "$_glc_dir")"
    menu_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
