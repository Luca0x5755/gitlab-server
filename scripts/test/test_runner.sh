#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# run.sh 的行為：自動發現 test_*.sh、任一失敗即非 0、不假綠。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"

# 在暫存目錄佈置一個迷你測試目錄（複製真正的 run.sh 與 helpers.sh）。
sandbox() { # sandbox <名稱>：回傳目錄
    local d="$T_TMP/$1"
    mkdir -p "$d"
    cp "$here/run.sh" "$here/helpers.sh" "$d/"
    echo "$d"
}

d="$(sandbox pass)"
printf '. "$(dirname "$0")/helpers.sh"\nassert_eq 1 1 x\n' >"$d/test_a.sh"
assert_status 0 "全部通過時 run.sh 結束碼為 0" bash "$d/run.sh"

printf '. "$(dirname "$0")/helpers.sh"\nassert_eq 1 2 x\n' >"$d/test_b.sh"
assert_nonzero "任一測試檔失敗時 run.sh 非 0" bash "$d/run.sh"

d="$(sandbox discover)"
printf '. "$(dirname "$0")/helpers.sh"\nassert_eq 1 1 x\n' >"$d/test_a.sh"
printf '. "$(dirname "$0")/helpers.sh"\nassert_eq 1 1 x\n' >"$d/test_new.sh"
out="$(bash "$d/run.sh" 2>&1)"
assert_contains "$out" "test_new.sh" "新增 test_*.sh 不必改 run.sh 就會被執行"

d="$(sandbox none)"
assert_nonzero "找不到任何測試檔視為失敗" bash "$d/run.sh"

d="$(sandbox empty)"
printf '. "$(dirname "$0")/helpers.sh"\n' >"$d/test_empty.sh"
assert_nonzero "零斷言的測試檔視為失敗" bash "$d/run.sh"

d="$(sandbox subshell)"
printf '. "$(dirname "$0")/helpers.sh"\n( assert_eq 1 2 x )\n' >"$d/test_sub.sh"
assert_nonzero "子 shell 內失敗的斷言也算失敗" bash "$d/run.sh"

d="$(sandbox helper)"
printf '. "$(dirname "$0")/helpers.sh"\nassert_eq 1 1 x\n' >"$d/test_a.sh"
out="$(bash "$d/run.sh" 2>&1)"
assert_not_contains "$out" "helpers.sh" "helpers.sh 不會被當成測試執行"
