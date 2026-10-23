#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# docker.sh 的「說明」「常見問題排查」（選單行程接縫）與 README 腳本表（ISSUE-008，PR-DKR-30、PR-DKR-32）。
# 期望值一律寫死字面值。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
dkr="$here/../docker.sh"
readme="$here/../../README.md"

menu="$(printf 'q\n' | bash "$dkr" 2>&1)"
assert_contains "$menu" "8) 說明" "選單含「說明」"
assert_contains "$menu" "9) 常見問題排查" "選單含「常見問題排查」"

help="$(printf '8\nq\n' | bash "$dkr" 2>&1)"
fix="$(printf '9\nq\n' | bash "$dkr" 2>&1)"

# 整體順序：步驟名稱依序出現（位置遞增）
pos_prev=-1
for k in "打包 GitLab 映像包" "安裝 Docker" "遷移" "移除舊 deb" "逐站升級"; do
    rest="${help#*"$k"}"
    if [ "$rest" = "$help" ]; then pos=-2; else pos=$((${#help} - ${#rest})); fi
    if [ "$pos" -gt "$pos_prev" ]; then _t_pass; else _t_fail "說明的順序：$k" "位置 $pos 未大於 $pos_prev"; fi
    pos_prev=$pos
done
for k in "18.11" "Upgrade Path Tool" "PostgreSQL 17" "2222" "git clone ssh://git@" "宿主機 sshd 的 22" "Git SSH 埠" "GitLab 容器" "掛載目錄" "GitLab 映像包" "尚未在實機試跑" "不可逆" "機外備份"; do
    assert_contains "$help" "$k" "說明含：$k"
done
for k in "update-permissions" "docker restart gitlab" "docker logs gitlab" "stat: missing operand" "磁碟空間" "不可逆" "機外備份" "尚未在實機試跑"; do
    assert_contains "$fix" "$k" "排查含：$k"
done
for k in "已驗證" "已實測" "Docker 版本" "volume" "升級包"; do
    assert_not_contains "$help$fix" "$k" "說明與排查不含：$k"
done

assert_contains "$(grep 'docker.sh' "$readme")" "scripts/docker.sh" "README 腳本表有 docker.sh"
for s in install.sh nginx.sh upgrade.sh; do
    assert_contains "$(grep "\[$s\]" "$readme")" "僅適用 deb" "README 的 $s 標明僅適用 deb"
done
