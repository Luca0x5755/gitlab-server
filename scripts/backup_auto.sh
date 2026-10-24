#!/usr/bin/env bash
# GitLab 自動備份：先資料備份，再設定備份（gitlab-ctl backup-etc），最後清理過期的設定備份。
# cron、升級前（upgrade.sh）與 backup.sh 的「立即備份」共用這一份。
# 容器模式（名為 gitlab 的容器執行中）時，兩個指令改以 docker exec 在容器內執行；
# 產物仍落在宿主機掛載的 /var/opt/gitlab/backups 與 /etc/gitlab/config_backup。
# 非互動：不問任何問題，才能被 cron 呼叫；不收參數。
#
# 結束碼：0 全部成功；1 資料備份失敗；2 設定備份失敗（沒有設定備份，資料備份無法還原，
# 所以同樣視為失敗）；其他非 0 為前置檢查（非 root、沒有 GitLab）失敗。
# 資料備份的保留天數由 gitlab.rb 的 backup_keep_time 管（backup.sh 選單 3 設定），
# 本腳本只清理設定備份。
#
# 頂層只定義函式；`set` 與實際動作都在 main 內，測試可以 source 取得函式。
# 可由環境變數覆寫的路徑（供測試用）：GITLAB_CONFIG_BACKUP_DIR、BACKUP_AUTO_LOG、GITLAB_OPT_DIR。

_bka_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$_bka_dir/lib/common.sh"

BKA_KEEP_DAYS=7

bka_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$(backup_log_file)"
}

# 清理超過保留天數的設定備份，輸出刪除的個數。
# 只動 gitlab_config_*.tar（backup-etc 的檔名），不碰目錄裡其他東西。
prune_config_backups() {
    local dir
    dir="$(config_backup_dir)"
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" -maxdepth 1 -type f -name 'gitlab_config_*.tar' -mtime +"$BKA_KEEP_DAYS" -print -delete | wc -l | tr -d ' '
}

main() {
    set -uo pipefail
    reject_args "$@"
    # 模式只在開頭探測一次，避免備份中途容器狀態改變而前後走不同路徑。
    _GITLAB_MODE="$(gitlab_mode)"
    require_gitlab_host
    require_root
    # 容器模式的指令在容器裡，宿主機（deb 已移除）沒有 gitlab-backup／gitlab-ctl，不檢查。
    if [ "$_GITLAB_MODE" = deb ]; then
        have_cmd gitlab-backup || die "找不到 gitlab-backup。"
        have_cmd gitlab-ctl || die "找不到 gitlab-ctl。"
    fi

    local log deleted
    log="$(backup_log_file)"
    mkdir -p "$(dirname "$log")" || die "無法建立日誌目錄：$(dirname "$log")"

    bka_log "========== 開始 GitLab 備份 =========="

    bka_log "[1/3] 資料備份..."
    if gitlab_run gitlab-backup create CRON=1 >>"$log" 2>&1; then
        bka_log "[1/3] 資料備份完成"
    else
        bka_log "[1/3] ✗ 資料備份失敗（詳見 $log）"
        return 1
    fi

    bka_log "[2/3] 設定備份（gitlab-ctl backup-etc）..."
    if gitlab_run gitlab-ctl backup-etc >>"$log" 2>&1; then
        bka_log "[2/3] 設定備份完成 → $(config_backup_dir)"
    else
        bka_log "[2/3] ✗ 設定備份失敗（詳見 $log）。沒有設定備份，資料備份無法還原。"
        return 2
    fi

    bka_log "[3/3] 清理 ${BKA_KEEP_DAYS} 天前的設定備份..."
    deleted="$(prune_config_backups)"
    bka_log "  設定備份：已刪除 ${deleted} 個舊檔案（資料備份的保留由 gitlab.rb 的 backup_keep_time 控制）"

    bka_log "========== 備份完成 =========="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
