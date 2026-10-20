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

# ── 版本字串（純函式；ISSUE-007／008 直接使用，勿另行定義）──────────────────────

# 版本轉成可字串比較的鍵：主.次.修[-ce.N]，各段補零到 10 位；無 -ce 後綴視同 -ce.0。
# 非法格式回非 0 且不輸出。各段最多 9 位數，避免溢位。
_version_key() {
    local re='^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})(-ce\.([0-9]{1,9}))?$'
    [[ $1 =~ $re ]] || return 1
    printf '%010d.%010d.%010d.%010d\n' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" \
        "$((10#${BASH_REMATCH[3]}))" "$((10#${BASH_REMATCH[5]:-0}))"
}

# version_cmp <a> <b>：輸出 -1／0／1；兩者都合法回 0，任一非法回 1 且不輸出。
# 用數值比較（18.7 < 18.10），不可用字串排序。
version_cmp() {
    local ka kb
    ka="$(_version_key "$1")" || return 1
    kb="$(_version_key "$2")" || return 1
    if [[ $ka < $kb ]]; then echo -1; elif [[ $ka > $kb ]]; then echo 1; else echo 0; fi
}

# sort_versions <asc|desc>：stdin 一行一版本，stdout 排序後；有非法行回非 0 且不輸出。
sort_versions() {
    local dir="${1:-}" line key keyed=""
    case "$dir" in asc | desc) ;; *) echo "✗ sort_versions：方向須為 asc 或 desc" >&2; return 2 ;; esac
    while IFS= read -r line || [ -n "$line" ]; do
        key="$(_version_key "$line")" || { echo "✗ 非法版本字串：$line" >&2; return 1; }
        keyed+="$key"$'\t'"$line"$'\n'
    done
    [ -n "$keyed" ] || return 0
    if [ "$dir" = asc ]; then
        printf '%s' "$keyed" | LC_ALL=C sort | cut -f2-
    else
        printf '%s' "$keyed" | LC_ALL=C sort -r | cut -f2-
    fi
}

# ── gitlab.rb 管理區塊 ───────────────────────────────────────────────────────
# 管理區塊是腳本寫進 gitlab.rb、以標記行包夾的一段設定；區塊名稱是參數，
# 各票（external_url、HTTPS、LDAP、備份保留、外部 Nginx）用不同名稱重用本分區。
#   # >>> gitlab-ops:<name> BEGIN 腳本維護，重跑整段取代，請勿手改
#   …內容…
#   # <<< gitlab-ops:<name> END
# 辨識只比對前綴，其後須是行尾或空白／Tab 開頭，所以尾巴說明文字日後可改。
# 內容（可能含 LDAP bind 密碼）只在 bash 變數與 umask 077 暫存檔間流動，
# 絕不經 awk -v／sed 替換字串／外部指令的 argv，也絕不印出。

valid_block_name() { [[ $1 =~ ^[a-z][a-z0-9_]*$ ]]; }

# 判斷一行相對於區塊 <name> 是什麼：結果放進全域 _bk（begin／end／bad／none），
# 避免每行開子 shell。標記前綴後緊接 CR（Windows 換行）視為 bad。
_block_kind() { # _block_kind <行> <name>
    local b="# >>> gitlab-ops:$2 BEGIN" e="# <<< gitlab-ops:$2 END" rest
    _bk=none
    if [[ $1 == "$b"* ]]; then
        rest="${1#"$b"}"
        case "$rest" in "" | " "* | $'\t'*) _bk=begin ;; $'\r'*) _bk=bad ;; esac
    elif [[ $1 == "$e"* ]]; then
        rest="${1#"$e"}"
        case "$rest" in "" | " "* | $'\t'*) _bk=end ;; $'\r'*) _bk=bad ;; esac
    fi
}

# 組出含標記行的整段，放進全域 _rb（保留結尾換行）。內容的任一行以標記前綴開頭即拒絕。
_render_block_var() { # _render_block_var <name> <內容>
    local line
    valid_block_name "$1" || { echo "✗ 區塊名稱不合法：$1" >&2; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line == "# >>> gitlab-ops:"* || $line == "# <<< gitlab-ops:"* ]]; then
            echo "✗ 區塊內容不可含管理區塊標記行。" >&2
            return 1
        fi
    done <<<"$2"
    _rb="# >>> gitlab-ops:$1 BEGIN 腳本維護，重跑整段取代，請勿手改"$'\n'
    [ -z "$2" ] || _rb+="$2"$'\n'
    _rb+="# <<< gitlab-ops:$1 END"$'\n'
}

render_block() { # render_block <name> <內容>：stdout 為整段
    local _rb
    _render_block_var "$1" "$2" || return 1
    printf '%s' "$_rb"
}

# 掃描檔案找出 <name> 區塊：設定 _bl_lines（各行）、_bl_b／_bl_e（BEGIN／END 的索引，無則 -1）、
# _bl_nonl（檔案非空且缺結尾換行為 1）。標記毀損回 1（只有 BEGIN、只有 END、同名多段、
# 順序顛倒、巢狀、標記帶 CR）。
_block_scan() { # _block_scan <檔> <name>
    local i n state=0
    valid_block_name "$2" || return 1
    _bl_b=-1
    _bl_e=-1
    _bl_lines=()
    mapfile -t _bl_lines <"$1" || return 1
    _bl_nonl=0
    if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then _bl_nonl=1; fi
    n="${#_bl_lines[@]}"
    for ((i = 0; i < n; i++)); do
        _block_kind "${_bl_lines[i]}" "$2"
        case "$_bk" in
            none) ;;
            begin) [ "$state" -eq 0 ] || return 1; _bl_b=$i; state=1 ;;
            end) [ "$state" -eq 1 ] || return 1; _bl_e=$i; state=2 ;;
            *) return 1 ;;
        esac
    done
    [ "$state" -ne 1 ]
}

# 把 _bl_lines 的 [from, to) 附加到 _out；檔尾那一行若原檔缺換行就維持缺。
_emit_lines() { # _emit_lines <from> <to>
    local i n="${#_bl_lines[@]}"
    for ((i = $1; i < $2; i++)); do
        if [ "$i" -eq $((n - 1)) ] && [ "$_bl_nonl" -eq 1 ]; then
            _out+="${_bl_lines[i]}"
        else
            _out+="${_bl_lines[i]}"$'\n'
        fi
    done
}

# replace_block <檔> <name> <內容>：stdout 為新檔全文，不寫檔。有區塊→整段取代；沒有→追加檔尾。
# 區塊外的 byte 不變（追加時只在舊檔缺結尾換行時補一個換行）。標記毀損或內容不合法回非 0 且不輸出。
replace_block() {
    local _rb _out="" n
    _render_block_var "$2" "$3" || return 1
    _block_scan "$1" "$2" || { echo "✗ $1 的管理區塊標記毀損（$2），不處理。" >&2; return 1; }
    n="${#_bl_lines[@]}"
    if [ "$_bl_b" -ge 0 ]; then
        _emit_lines 0 "$_bl_b"
        _out+="$_rb"
        _emit_lines $((_bl_e + 1)) "$n"
    else
        _emit_lines 0 "$n"
        [ "$_bl_nonl" -eq 0 ] || _out+=$'\n'
        _out+="$_rb"
    fi
    printf '%s' "$_out"
}

# strip_block <檔> <name>：stdout 為移除該區塊後的全文；無此區塊→原樣。標記毀損回非 0。
strip_block() {
    local _out="" n
    _block_scan "$1" "$2" || { echo "✗ $1 的管理區塊標記毀損（$2），不處理。" >&2; return 1; }
    n="${#_bl_lines[@]}"
    if [ "$_bl_b" -ge 0 ]; then
        _emit_lines 0 "$_bl_b"
        _emit_lines $((_bl_e + 1)) "$n"
    else
        _emit_lines 0 "$n"
    fi
    printf '%s' "$_out"
}

# block_present <檔> <name>：有完整區塊回 0；沒有或標記毀損回 1。
block_present() {
    _block_scan "$1" "$2" 2>/dev/null && [ "$_bl_b" -ge 0 ]
}

# gitlab.rb 路徑；GITLAB_RB 可由呼叫端（測試）覆寫，與 network.sh 同名。
gitlab_rb_file() { echo "${GITLAB_RB:-/etc/gitlab/gitlab.rb}"; }

# 時間戳；獨立成函式讓測試能固定它。
now_stamp() { date +%Y%m%d%H%M%S; }

# 寫入接縫：把暫存檔內容寫進目標（保留目標 inode／權限／擁有者）。測試可覆寫它模擬磁碟滿。
write_file_from() { cat "$1" >"$2"; }

# 備份 gitlab.rb 為 gitlab.rb.bak-<時間戳>，權限 600（內可能有 LDAP bind 密碼）。
# 同一秒重複則加 -N 後綴，不覆蓋既有備份。成功時路徑放進全域 LAST_GITLAB_RB_BAK。
backup_gitlab_rb() {
    local f ts dest n=1
    f="$(gitlab_rb_file)"
    [ -f "$f" ] || { echo "✗ 找不到 $f，無法備份。" >&2; return 1; }
    ts="$(now_stamp)"
    dest="$f.bak-$ts"
    while [ -e "$dest" ]; do
        n=$((n + 1))
        dest="$f.bak-$ts-$n"
    done
    if ! (umask 077 && cp "$f" "$dest") || ! chmod 600 "$dest"; then
        rm -f "$dest"
        echo "✗ 備份 $f 失敗。" >&2
        return 1
    fi
    LAST_GITLAB_RB_BAK="$dest"
    echo "  已備份：$dest"
}

# 把備份內容寫回 gitlab.rb。與 write_file_from 互相獨立（正向寫入失敗時還原仍可用）。
# 失敗回非 0，並印出人工還原的指令（只有路徑，不含內容）。
restore_gitlab_rb() { # restore_gitlab_rb <備份檔>
    local f
    f="$(gitlab_rb_file)"
    # 先確認備份存在：否則 `cat 不存在的檔 >目標` 會先把目標清空。
    if [ -f "$1" ] && cat "$1" >"$f"; then
        echo "  已由 $1 還原 $f。"
        return 0
    fi
    echo "✗ 自動還原失敗，請手動還原：cp '$1' '$f'" >&2
    return 1
}

# reconfigure 的薄包裝；獨立成函式讓測試能覆寫（行程層級則用 PATH 上的 gitlab-ctl stub）。
gitlab_reconfigure() { gitlab-ctl reconfigure; }

# 套用或移除區塊的共同流程。回傳碼：
#   0 成功；1 reconfigure 失敗；2 事前拒絕（gitlab.rb 保證未動）；3 寫入中途失敗（已自動還原）。
# 內容只存在變數與 umask 077 的暫存檔，絕不印出。
_managed_change_run() { # _managed_change_run <暫存檔> <apply|remove> <name> <內容>
    local tmp="$1" mode="$2" name="$3" content="${4:-}" f bak
    f="$(gitlab_rb_file)"
    valid_block_name "$name" || { echo "✗ 區塊名稱不合法：$name" >&2; return 2; }
    [ -f "$f" ] || { echo "✗ 找不到 $f。" >&2; return 2; }
    if [ "$mode" = apply ]; then
        replace_block "$f" "$name" "$content" >"$tmp" || return 2
    else
        strip_block "$f" "$name" >"$tmp" || return 2
        if ! block_present "$f" "$name"; then
            echo "  $f 沒有管理區塊「$name」，不需移除。"
            return 0
        fi
    fi
    backup_gitlab_rb || return 2
    bak="$LAST_GITLAB_RB_BAK"
    if ! write_file_from "$tmp" "$f"; then
        echo "✗ 寫入 $f 失敗，自動由備份還原。備份：$bak" >&2
        restore_gitlab_rb "$bak" || true
        return 3
    fi
    if gitlab_reconfigure; then
        return 0
    fi
    echo "✗ reconfigure 失敗。備份：$bak" >&2
    if confirm "要把 gitlab.rb 還原為修改前的備份嗎？"; then
        restore_gitlab_rb "$bak" || true
        echo "  還原後尚未重新 reconfigure，請確認設定後再執行。"
    else
        echo "  未還原，gitlab.rb 保留新內容；需要時可手動還原：cp '$bak' '$f'"
    fi
    return 1
}

_managed_change() { # _managed_change <apply|remove> <name> [內容]
    local tmp rc=0
    tmp="$(umask 077 && mktemp)" || { echo "✗ 無法建立暫存檔。" >&2; return 2; }
    _managed_change_run "$tmp" "$@" || rc=$?
    rm -f "$tmp"
    return "$rc"
}

# apply_managed_block <name> <內容>：備份 → 整段取代（沒有就追加）→ reconfigure。
# remove_managed_block <name>：備份 → 移除區塊 → reconfigure；區塊不存在回 0 且什麼都不做。
# 回傳碼見 _managed_change_run。在 menu_loop 的子 shell（set -e）內取碼要寫：
#   rc=0; apply_managed_block … || rc=$?
apply_managed_block() { _managed_change apply "$1" "$2"; }
remove_managed_block() { _managed_change remove "$1"; }
