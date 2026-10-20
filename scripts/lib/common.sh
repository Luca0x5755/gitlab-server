#!/usr/bin/env bash
# scripts 共用函式——五支選單腳本與 backup_auto.sh 一律 source 這支，勿各自重複實作。
# 只定義函式與常數，source 時不產生任何副作用（不 cd、不改 shell 選項）。
# 後續擴充：在對應分區「追加」函式；已有函式的簽名不改。

# repo 根目錄（呼叫端未先定義才補）。
: "${root:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# ── 輸出與確認 ───────────────────────────────────────────────────────────────

die() { echo "✗ $*" >&2; exit 1; }

# 破壞性操作的確認：必須輸入 yes。stdin 讀到 EOF（無人可答）一律視為否。
confirm() {
    local ans=""
    read -r -p "$1 輸入 yes 繼續：" ans || true
    [ "$ans" = "yes" ]
}

# 腳本不收參數：帶任何參數（含空字串）即明確拒絕，不靜默開選單。
reject_args() {
    [ $# -eq 0 ] && return 0
    echo "✗ 本腳本不收參數，請直接執行並從選單操作。" >&2
    exit 2
}

# ── 參數（參數檔 scripts/gitlab-ops.env，不存任何密碼）─────────────────────────

# 參數檔路徑；OPS_ENV_FILE 可由呼叫端（測試）覆寫。
ops_env_file() { echo "${OPS_ENV_FILE:-$root/scripts/gitlab-ops.env}"; }

# 參數檔以「KEY=VALUE」逐行存放，只用文字處理讀寫，絕不 source（避免執行檔內容）。
env_get() { # env_get <KEY>：無檔或無鍵回空字串，恆回 0
    local f
    f="$(ops_env_file)"
    [ -f "$f" ] || return 0
    sed -n "s/^$1=\(.*\)$/\1/p" "$f" | tail -n1
}

env_set() { # env_set <KEY> <VALUE>：同鍵只留一行
    local f tmp
    f="$(ops_env_file)"
    mkdir -p "$(dirname "$f")"
    tmp="$(mktemp)"
    { [ -f "$f" ] && grep -v "^$1=" "$f"; printf '%s=%s\n' "$1" "$2"; } >"$tmp" || true
    cat "$tmp" >"$f"
    rm -f "$tmp"
}

# 詢問一項參數，並把答案存入參數檔。
# 用法：value="$(ask_param <KEY> <提示> [預設] [驗證函式])"
# - 值走 stdout（提示走 stderr，才不會混進回傳值）；
# - Enter 沿用上次答案，沒有上次答案才用預設；stdin EOF 等同 Enter；
# - 有驗證函式時，不合格就重問；EOF 後仍不合格回非 0；只有合格的值才寫入參數檔。
# 本簽名之後所有腳本沿用，勿改。
ask_param() {
    local key="$1" prompt="$2" default="${3:-}" validator="${4:-}" cur ans eof
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "參數鍵名不合法：$key"
    cur="$(env_get "$key")"
    default="${cur:-$default}"
    while true; do
        eof=0
        ans=""
        read -r -p "$prompt${default:+ [$default]}：" ans || eof=1
        ans="${ans:-$default}"
        if [ -z "$validator" ] || "$validator" "$ans"; then
            env_set "$key" "$ans"
            echo "$ans"
            return 0
        fi
        echo "✗ 格式不符：$ans" >&2
        [ "$eof" -eq 0 ] || return 1
    done
}

# ── 驗證（純函式）────────────────────────────────────────────────────────────

# IPv4：四段 0–255 的十進位，不接受前導零、空白、前綴長度。
valid_ipv4() {
    local re='^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'
    local o
    [[ $1 =~ $re ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [ "$o" -le 255 ] || return 1
    done
}

# ── 機器檢查 ─────────────────────────────────────────────────────────────────

# 探測用的小函式，獨立出來是為了讓測試能直接重新定義，不必靠空 PATH 之類的手法。
have_cmd() { command -v "$1" >/dev/null 2>&1; }
gitlab_installed() { [ -d "${GITLAB_OPT_DIR:-/opt/gitlab}" ]; }
current_uid() { echo "${OPS_FAKE_UID:-$(id -u)}"; }

# 依「機器角色」檢查目前這台是不是該跑這個動作；不符即中止並說明應在哪台執行。
# 用法：require_machine <online|server|ubuntu> [必備指令…]
#   online ：【有網路的電腦】——要有 apt
#   server ：【GitLab 伺服器】——要有 apt 與 /opt/gitlab（GitLab 已安裝）
#   ubuntu ：只要 Ubuntu 工具（apt 與列出的指令），不要求 GitLab 已安裝；
#            給安裝前就會用到的動作（例如改固定 IP）。
require_machine() {
    local role="${1:-}" c
    shift || true
    case "$role" in
        online)
            have_cmd apt || die "缺少 apt。這個動作須在【有網路的電腦】（Ubuntu／Debian）上執行。"
            ;;
        server)
            have_cmd apt || die "缺少 apt。這個動作須在【GitLab 伺服器】上執行。"
            gitlab_installed || die "找不到 GitLab（${GITLAB_OPT_DIR:-/opt/gitlab}）。這個動作須在已安裝 GitLab 的【GitLab 伺服器】上執行。"
            ;;
        ubuntu)
            have_cmd apt || die "缺少 apt。這個動作須在【GitLab 伺服器】（Ubuntu）上執行；此時 GitLab 可能尚未安裝，不要求。"
            for c in "$@"; do
                have_cmd "$c" || die "缺少指令 $c。這個動作須在【GitLab 伺服器】（Ubuntu）上執行；此時 GitLab 可能尚未安裝，不要求。"
            done
            ;;
        *) die "require_machine：未知的機器角色「$role」（可用：online／server／ubuntu）" ;;
    esac
}

# 會改系統檔的動作先確認是 root，免得做到一半才因權限失敗而留下半套狀態。
require_root() {
    [ "$(current_uid)" -eq 0 ] || die "需要 root 權限，請用 sudo 執行。"
}

# ── 選單骨架（各選單腳本共用）────────────────────────────────────────────────

# 選單迴圈：呼叫端定義 show_menu（印選單）與 dispatch <選項>（執行一項）。
# q 或 stdin EOF 離開（結束碼 0）。每個動作在獨立子 shell 內以 set -e 執行：
# die／未檢查的指令失敗只結束該動作並顯示 ✗，然後回選單。
# 外層需暫時 set +e：放在 if／|| 條件裡，子 shell 內的 set -e 會被 bash 無視。
menu_loop() {
    local choice="" rc had_e=0
    [[ $- == *e* ]] && had_e=1
    # Ctrl-C 只該停掉當前動作；子 shell 不繼承 trap、照常被中斷，選單本身存活。
    trap ':' INT
    while true; do
        show_menu
        read -r -p "選擇：" choice || { echo; echo "已離開。"; return 0; }
        case "$choice" in q | Q) echo "已離開。"; return 0 ;; esac
        set +e
        ( set -e; dispatch "$choice" )
        rc=$?
        [ "$had_e" -eq 0 ] || set -e
        [ "$rc" -eq 0 ] || echo "✗ 動作未完成（結束碼 $rc）。" >&2
        echo
    done
}
