#!/usr/bin/env bash
# 一次執行全部測試：自動發現同目錄的 test_*.sh，各以獨立 bash 子程序執行。
# 後續新增測試只要加 test_*.sh，不必修改本檔。任一失敗（或找不到任何測試）即以非 0 結束。
set -u

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

files=()
for f in "$dir"/test_*.sh; do
    [ -e "$f" ] && files+=("$f")
done

if [ "${#files[@]}" -eq 0 ]; then
    echo "✗ 找不到任何 test_*.sh，視為失敗。" >&2
    exit 1
fi

failed=()
for f in "${files[@]}"; do
    name="$(basename "$f")"
    echo "── $name"
    if ! bash "$f"; then
        failed+=("$name")
    fi
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
    echo "✗ 失敗 ${#failed[@]}／${#files[@]}：${failed[*]}" >&2
    exit 1
fi
echo "✓ 全部通過（${#files[@]} 個測試檔）"
