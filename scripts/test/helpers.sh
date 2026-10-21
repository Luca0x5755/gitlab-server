#!/usr/bin/env bash
# 測試輔助：被各 test_*.sh source（本檔不符 test_*.sh 命名，run.sh 不會把它當測試）。
# source 後提供：assert_eq／assert_status／assert_contains／assert_not_contains／assert_file_eq、
# T_TMP（本測試檔專屬暫存目錄，結束時自動清除）、make_stub（建立假指令）。
#
# 不假綠的保證：斷言的計數寫在檔案裡（子 shell 內的斷言也算數）；
# 結束時只要有任何失敗，或一個斷言都沒執行，整個測試檔一律以非 0 結束。
#
# 注意：stdin 不是 TTY 時，`read -p` 不會印出提示字串，所以測試不可斷言提示文字，
# 只能斷言行為與其他輸出。

T_TMP="$(mktemp -d)"
: >"$T_TMP/.asserts"
: >"$T_TMP/.fails"
# 預設把參數檔指到暫存位置，避免測試意外寫到真正的 scripts/gitlab-ops.env。
export OPS_ENV_FILE="$T_TMP/gitlab-ops.env"

_t_finish() {
    local asserts fails
    asserts="$(wc -c <"$T_TMP/.asserts" | tr -d ' ')"
    fails="$(wc -c <"$T_TMP/.fails" | tr -d ' ')"
    rm -rf "$T_TMP"
    if [ "$fails" -gt 0 ]; then
        echo "FAILED: $fails of $asserts assertions" >&2
        exit 1
    fi
    if [ "$asserts" -eq 0 ]; then
        echo "FAILED: 沒有執行任何斷言（空測試視為失敗）" >&2
        exit 1
    fi
    echo "ok: $asserts assertions"
}
trap _t_finish EXIT

_t_pass() { printf '.' >>"$T_TMP/.asserts"; }
_t_fail() { # _t_fail <名稱> <細節>
    printf '.' >>"$T_TMP/.asserts"
    printf 'x' >>"$T_TMP/.fails"
    printf '  FAIL: %s\n%s\n' "$1" "$2" >&2
}

assert_eq() { # assert_eq <期望> <實際> <名稱>
    if [ "$1" = "$2" ]; then _t_pass; else _t_fail "$3" "    期望：[$1]"$'\n'"    實際：[$2]"; fi
}

assert_status() { # assert_status <期望結束碼> <名稱> <指令…>
    local want="$1" name="$2" rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq "$want" ]; then _t_pass; else _t_fail "$name" "    期望結束碼 $want，實際 $rc"; fi
}

assert_nonzero() { # assert_nonzero <名稱> <指令…>
    local name="$1" rc=0
    shift
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then _t_pass; else _t_fail "$name" "    期望非 0，實際 0"; fi
}

assert_contains() { # assert_contains <全文> <片段> <名稱>
    if [[ $1 == *"$2"* ]]; then _t_pass; else _t_fail "$3" "    找不到：[$2]"$'\n'"    全文：[$1]"; fi
}

assert_not_contains() {
    if [[ $1 != *"$2"* ]]; then _t_pass; else _t_fail "$3" "    不該出現：[$2]"$'\n'"    全文：[$1]"; fi
}

assert_file_eq() { # assert_file_eq <檔A> <檔B> <名稱>：byte 比對
    if cmp -s "$1" "$2"; then _t_pass; else _t_fail "$3" "    $1 與 $2 內容不同"; fi
}

# make_stub <目錄> <指令名> <腳本本體>：建立會把「指令名 參數」記進 $STUB_LOG 的假指令。
make_stub() {
    local dir="$1" name="$2" body="$3"
    mkdir -p "$dir"
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"$name \$*\" >>\"\${STUB_LOG:-/dev/null}\""
        printf '%s\n' "$body"
    } >"$dir/$name"
    chmod +x "$dir/$name"
}
