#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# 所有腳本都要通過 bash -n（語法檢查）。涵蓋 scripts/ 下所有 .sh，新增的腳本自動納入。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
scripts="$(cd "$here/.." && pwd)"

n=0
for f in "$scripts"/*.sh "$scripts"/lib/*.sh "$scripts"/test/*.sh; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    assert_status 0 "bash -n ${f#"$scripts"/}" bash -n "$f"
done
assert_eq "yes" "$([ "$n" -ge 3 ] && echo yes || echo no)" "至少檢查到 network.sh、common.sh 與測試檔"
