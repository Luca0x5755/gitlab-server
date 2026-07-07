#!/bin/bash
# ============================================================
# GitLab CE 定期完整備份腳本
# 用途：備份 GitLab 資料 + 設定檔/金鑰，並清理過期備份
# 建議搭配 crontab 每日自動執行
# ============================================================

# ---------- 可自訂參數 ----------
BACKUP_DIR="/var/opt/gitlab/backups"
CONFIG_BACKUP_DIR="/var/opt/gitlab/backups/config"
LOG_FILE="/var/log/gitlab_backup.log"
KEEP_DAYS=7                          # 備份保留天數
DATE=$(date +%Y%m%d_%H%M%S)
# --------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 確保備份目錄存在
mkdir -p "$CONFIG_BACKUP_DIR"

log "========== 開始 GitLab 完整備份 =========="

# --------------------------------------------------
# 1. 資料備份（儲存庫、資料庫、附件、Wiki 等）
# --------------------------------------------------
log "[1/3] 執行資料備份..."
if sudo gitlab-rake gitlab:backup:create CRON=1 >> "$LOG_FILE" 2>&1; then
    log "[1/3] 資料備份完成"
else
    log "[1/3] ❌ 資料備份失敗！"
    exit 1
fi

# --------------------------------------------------
# 2. 備份設定檔與金鑰（還原時必要）
# --------------------------------------------------
log "[2/3] 備份設定檔與金鑰..."
CONFIG_TAR="$CONFIG_BACKUP_DIR/gitlab_config_${DATE}.tar.gz"
if sudo tar -czf "$CONFIG_TAR" \
    /etc/gitlab/gitlab.rb \
    /etc/gitlab/gitlab-secrets.json \
    /etc/gitlab/ssl 2>/dev/null; then
    sudo chmod 600 "$CONFIG_TAR"
    log "[2/3] 設定檔備份完成 → $CONFIG_TAR"
else
    log "[2/3] ⚠️ 設定檔備份失敗（請確認檔案是否存在）"
fi

# --------------------------------------------------
# 3. 清理過期備份
# --------------------------------------------------
log "[3/3] 清理 ${KEEP_DAYS} 天前的備份..."

# 清理資料備份
DELETED_DATA=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar" -mtime +${KEEP_DAYS} -print -delete 2>/dev/null | wc -l)
log "  資料備份：已刪除 ${DELETED_DATA} 個舊檔案"

# 清理設定備份
DELETED_CONFIG=$(find "$CONFIG_BACKUP_DIR" -name "gitlab_config_*.tar.gz" -mtime +${KEEP_DAYS} -print -delete 2>/dev/null | wc -l)
log "  設定備份：已刪除 ${DELETED_CONFIG} 個舊檔案"

# --------------------------------------------------
# 完成
# --------------------------------------------------
log "========== 備份完成 =========="
log "備份位置：$BACKUP_DIR"
log ""
