#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2317,SC2034,SC2012
# lib/common.sh 的版本函式與 gitlab.rb 管理區塊（接縫 A）：source 後直接呼叫函式。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/helpers.sh"
common="$here/../lib/common.sh"
. "$common"

# cp 的包裝：CP_FAIL 非空時模擬複製失敗（備份失敗情境用）。定義在所有使用處之前。
cp() {
    if [ -n "${CP_FAIL:-}" ]; then return 1; fi
    command cp "$@"
}

# ── version_cmp（歸屬本票，ISSUE-007／008 直接使用）──
vc() { version_cmp "$1" "$2"; }
assert_eq "-1" "$(vc 18.7.6-ce.0 18.10.0-ce.0)" "18.7 小於 18.10（數值比較，不是字串）"
assert_eq "1" "$(vc 18.10.0-ce.0 18.7.6-ce.0)" "18.10 大於 18.7"
assert_eq "-1" "$(vc 17.11.2-ce.0 18.0.0-ce.0)" "跨大版本"
assert_eq "0" "$(vc 18.7.6-ce.0 18.7.6-ce.0)" "相等"
assert_eq "1" "$(vc 18.7.6-ce.1 18.7.6-ce.0)" "-ce.1 大於 -ce.0"
assert_eq "0" "$(vc 17.11.2 17.11.2-ce.0)" "無後綴視同 -ce.0"
assert_eq "-1" "$(vc 18.7.9-ce.0 18.7.10-ce.0)" "修訂號 9 < 10"
for bad in "" abc 18.7 18.7.6-ee.0 "18.7.6 " "18.7.6-ce." 18.7.6.1; do
    assert_nonzero "非法版本：[$bad]" version_cmp "$bad" 18.7.6-ce.0
    assert_nonzero "非法版本（右側）：[$bad]" version_cmp 18.7.6-ce.0 "$bad"
    assert_eq "" "$(version_cmp "$bad" 18.7.6-ce.0 2>/dev/null)" "非法版本不輸出：[$bad]"
done

# ── sort_versions：輸入刻意打亂，期望值寫死 ──
shuffled=$'18.7.6-ce.0\n17.11.2-ce.0\n18.10.0-ce.0\n18.7.10-ce.0\n18.7.6-ce.1'
assert_eq $'18.10.0-ce.0\n18.7.10-ce.0\n18.7.6-ce.1\n18.7.6-ce.0\n17.11.2-ce.0' "$(printf '%s\n' "$shuffled" | sort_versions desc)" "desc 新到舊"
assert_eq $'17.11.2-ce.0\n18.7.6-ce.0\n18.7.6-ce.1\n18.7.10-ce.0\n18.10.0-ce.0' "$(printf '%s\n' "$shuffled" | sort_versions asc)" "asc 小到大"
# 字串排序會把 18.10 排在 18.7 前面（升冪時），證明期望值不是字串排序的結果
assert_eq "no" "$([ "$(printf '%s\n' "$shuffled" | sort_versions asc)" = "$(printf '%s\n' "$shuffled" | LC_ALL=C sort)" ] && echo yes || echo no)" "結果不同於純字串排序"
assert_nonzero "含非法行：非 0" bash -c ". '$common'; printf '18.7.6-ce.0\nabc\n' | sort_versions asc"
assert_nonzero "未知排序方向：非 0" bash -c ". '$common'; echo 18.7.6-ce.0 | sort_versions sideways"

# ══ 管理區塊：純函式 ═══════════════════════════════════════════════════════════
B() { printf '# >>> gitlab-ops:%s BEGIN 腳本維護，重跑整段取代，請勿手改\n' "$1"; }
E() { printf '# <<< gitlab-ops:%s END\n' "$1"; }
F="$T_TMP/rb"

# 比較「檔案內容」與期望字串（byte 級；$(…) 會吃結尾換行，所以用檔案比）
assert_out_eq() { # assert_out_eq <期望檔> <名稱> <指令…>：指令的 stdout 與期望檔逐 byte 相同
    local want="$1" name="$2"
    shift 2
    "$@" >"$T_TMP/out.bin" 2>/dev/null
    assert_file_eq "$want" "$T_TMP/out.bin" "$name"
}

assert_status 0 "名稱 foo_1 合法" valid_block_name foo_1
for n in "" 1abc Foo foo-bar "foo bar" 'a$b' "a'b"; do
    assert_nonzero "非法區塊名稱：[$n]" valid_block_name "$n"
done

# ── render_block ──
{ B foo; printf 'external_url '"'"'http://1.2.3.4'"'"'\n'; E foo; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "render_block 產出標記行包夾的整段" render_block foo "external_url 'http://1.2.3.4'"
{ B foo; E foo; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "空內容：只有兩行標記" render_block foo ""
assert_nonzero "內容夾帶 BEGIN 標記行：拒絕" render_block foo $'a\n# >>> gitlab-ops:bar BEGIN\nb'
assert_nonzero "內容夾帶 END 標記行：拒絕" render_block foo $'a\n# <<< gitlab-ops:foo END'
assert_eq "" "$(render_block foo $'a\n# >>> gitlab-ops:bar BEGIN' 2>/dev/null)" "拒絕時不輸出"
assert_nonzero "名稱不合法：拒絕" render_block "Bad Name" x

# ── replace_block：追加 ──
printf '' >"$F"
{ B foo; printf 'x=1\n'; E foo; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "空檔追加" replace_block "$F" foo "x=1"
printf '# 手寫\nfoo = 1\n' >"$F"
{ cat "$F"; B foo; printf 'x=1\n'; E foo; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "有內容檔追加：舊檔是前綴" replace_block "$F" foo "x=1"
printf '# 手寫\nfoo = 1' >"$F"   # 無結尾換行
{ printf '# 手寫\nfoo = 1\n'; B foo; printf 'x=1\n'; E foo; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "無結尾換行檔追加：只補一個換行" replace_block "$F" foo "x=1"

# ── 重跑不重複追加（用 replace_block 連續套三次）──
printf '# 手寫\nfoo = 1\n' >"$F"
replace_block "$F" foo "x=1" >"$T_TMP/r1"
cp "$T_TMP/r1" "$T_TMP/r1b"
replace_block "$T_TMP/r1" foo "x=1" >"$T_TMP/r2"
replace_block "$T_TMP/r2" foo "x=1" >"$T_TMP/r3"
assert_file_eq "$T_TMP/r1b" "$T_TMP/r3" "重跑三次與一次逐 byte 相同"
assert_eq "1" "$(grep -c '^# >>> gitlab-ops:foo BEGIN' "$T_TMP/r3")" "BEGIN 標記行恰 1 行"

# ── replace_block：取代，區塊外 byte 不變（四種位置）──
chk_replace() { # chk_replace <名稱> <前段> <後段> ：前後段原樣保留，區塊內容換掉
    local name="$1" pre="$2" post="$3"
    { printf '%s' "$pre"; B foo; printf 'OLD\n'; E foo; printf '%s' "$post"; } >"$T_TMP/orig"
    { printf '%s' "$pre"; B foo; printf 'NEW\n'; E foo; printf '%s' "$post"; } >"$T_TMP/want"
    assert_out_eq "$T_TMP/want" "取代：$name" replace_block "$T_TMP/orig" foo "NEW"
}
chk_replace "區塊在檔首" "" $'tail1\ntail2\n'
chk_replace "區塊在檔中" $'head1\nhead2\n' $'tail1\ntail2\n'
chk_replace "區塊在檔尾" $'head1\n' ""
chk_replace "後段無結尾換行" $'head1\n' $'tail1\ntail2'
# 區塊在檔尾且 END 行無結尾換行：新檔 END 行補換行（區塊本身是我們的）
{ printf 'head\n'; B foo; printf 'OLD\n'; printf '# <<< gitlab-ops:foo END'; } >"$T_TMP/orig"
{ printf 'head\n'; B foo; printf 'NEW\n'; E foo; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "取代：END 行無結尾換行" replace_block "$T_TMP/orig" foo "NEW"

# ── 兩個區塊共存、名稱前綴不互誤、舊措辭仍可辨識 ──
{ printf 'a\n'; B ldap; printf 'L=1\n'; E ldap; printf 'b\n'; B ldap2; printf 'L2=1\n'; E ldap2; printf 'c\n'; } >"$T_TMP/orig"
{ printf 'a\n'; B ldap; printf 'L=NEW\n'; E ldap; printf 'b\n'; B ldap2; printf 'L2=1\n'; E ldap2; printf 'c\n'; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "改 ldap 不動 ldap2" replace_block "$T_TMP/orig" ldap "L=NEW"
{ printf 'a\n'; B ldap; printf 'L=1\n'; E ldap; printf 'b\n'; B ldap2; printf 'L2=NEW\n'; E ldap2; printf 'c\n'; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "改 ldap2 不動 ldap" replace_block "$T_TMP/orig" ldap2 "L2=NEW"
{ printf 'a\n# >>> gitlab-ops:foo BEGIN 舊措辭\nOLD\n# <<< gitlab-ops:foo END 舊措辭\nz\n'; } >"$T_TMP/orig"
{ printf 'a\n'; B foo; printf 'NEW\n'; E foo; printf 'z\n'; } >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "尾巴措辭不同的舊區塊仍被整段取代" replace_block "$T_TMP/orig" foo "NEW"
{ printf 'a\n# >>> gitlab-ops:fooX BEGIN\nOLD\n# <<< gitlab-ops:fooX END\n'; } >"$T_TMP/orig"
assert_eq "1" "$(replace_block "$T_TMP/orig" foo "NEW" | grep -c '^# >>> gitlab-ops:foo BEGIN')" "名稱 fooX 不被當成 foo（改為追加新區塊）"

# ── 標記毀損：非 0、stdout 空 ──
corrupt() { # corrupt <名稱> <檔內容>
    printf '%b' "$2" >"$T_TMP/bad"
    assert_nonzero "毀損：$1（replace）" replace_block "$T_TMP/bad" foo x
    assert_eq "" "$(replace_block "$T_TMP/bad" foo x 2>/dev/null)" "毀損：$1（stdout 空）"
    assert_nonzero "毀損：$1（strip）" strip_block "$T_TMP/bad" foo
    assert_nonzero "毀損：$1（block_present）" block_present "$T_TMP/bad" foo
}
bf="$(B foo)"; ef="$(E foo)"
corrupt "只有 BEGIN" "a\n${bf}\nx\n"
corrupt "只有 END" "a\nx\n${ef}\n"
corrupt "同名兩段" "${bf}\nx\n${ef}\n${bf}\ny\n${ef}\n"
corrupt "順序顛倒" "${ef}\nx\n${bf}\n"
corrupt "巢狀 BEGIN" "${bf}\n${bf}\nx\n${ef}\n"
corrupt "BEGIN 帶 CRLF" "# >>> gitlab-ops:foo BEGIN\r\nx\n${ef}\n"
corrupt "END 帶 CRLF" "${bf}\nx\n# <<< gitlab-ops:foo END\r\n"

# ── 內容保真：特殊字元逐 byte 原樣 ──
bs=$'\x5c'   # 反斜線：避免原始碼中的跳脫被多層解讀
tricky="quote's \"dq\" \$HOME \`bt\` & / | ${bs} 字面${bs}n 與 ${bs}${bs} 兩反斜線"$'\n'"  leading space"$'\n'"# hash"$'\n'"'password' => 'x${bs}ny'"
printf 'head\n' >"$F"
replace_block "$F" foo "$tricky" >"$T_TMP/out.bin"
{ printf 'head\n'; B foo; printf '%s\n' "$tricky"; E foo; } >"$T_TMP/want"
assert_file_eq "$T_TMP/want" "$T_TMP/out.bin" "特殊字元（含字面 \n、\\）原樣寫入"

# ── strip_block／block_present ──
{ printf 'a\n'; B foo; printf 'X\n'; E foo; printf 'b\n'; } >"$T_TMP/orig"
printf 'a\nb\n' >"$T_TMP/want"
assert_out_eq "$T_TMP/want" "strip 移除區塊，區塊外 byte 不變" strip_block "$T_TMP/orig" foo
assert_status 0 "block_present：存在" block_present "$T_TMP/orig" foo
assert_nonzero "block_present：不存在（其他名稱）" block_present "$T_TMP/orig" bar
assert_out_eq "$T_TMP/orig" "strip 無此區塊：原樣" strip_block "$T_TMP/orig" bar
printf 'p\nq' >"$T_TMP/orig2"
assert_out_eq "$T_TMP/orig2" "strip 無此區塊且無結尾換行：原樣" strip_block "$T_TMP/orig2" foo
# 追加後再 strip 回到原檔
printf 'p\nq\n' >"$F"
replace_block "$F" foo "x" >"$T_TMP/added"
assert_out_eq "$F" "追加後 strip 回到原檔" strip_block "$T_TMP/added" foo

# ══ 管理區塊：備份、寫入、reconfigure、還原 ═══════════════════════════════════
# 這一段在目前 shell 內直接呼叫函式；GITLAB_RB 指向暫存檔，不碰真實 /etc/gitlab。
export GITLAB_RB="$T_TMP/gitlab.rb"
export STUB_LOG="$T_TMP/stub.log"
export TMPDIR="$T_TMP/tmpdir"
mkdir -p "$TMPDIR"
SNAP="$T_TMP/snap"
CALLS="$T_TMP/calls"
OUT="$T_TMP/combined.out"

# 依 GitLab 預設 gitlab.rb 的樣子（節錄）：含一行有效的 external_url 與大量註解
cat >"$T_TMP/default.rb" <<'RB'
## GitLab configuration settings
external_url 'GENERATED_EXTERNAL_URL'
# gitlab_rails['ldap_enabled'] = false
# nginx['enable'] = true
RB

# 被呼叫「當下」才快照 gitlab.rb 的 reconfigure：證明 reconfigure 發生在寫檔之後，
# 也讓「還原」測試有對照（快照含新區塊，最終檔案卻等於原檔）。
fake_reconfigure() {
    echo "reconfigure" >>"$CALLS"
    cp "$GITLAB_RB" "$SNAP"
    return "${RECONF_RC:-0}"
}

# 每個情境開頭呼叫：重置 gitlab.rb、清掉備份／快照／記錄，並裝回測試用的覆寫函式。
reset_rb() {
    . "$common"   # 還原 write_file_from／restore_gitlab_rb 等預設實作
    rm -f "$GITLAB_RB".bak-* "$SNAP" "$CALLS" "$STUB_LOG" "$OUT"
    cp "$T_TMP/default.rb" "$GITLAB_RB"
    cp "$GITLAB_RB" "$T_TMP/pristine"
    : >"$CALLS"
    RECONF_RC=0
    now_stamp() { echo 20260101000000; }
    gitlab_reconfigure() { fake_reconfigure; }
    chmod() { echo "chmod $*" >>"$STUB_LOG"; command chmod "$@"; }
}
baks() { ls "$GITLAB_RB".bak-* 2>/dev/null | wc -l | tr -d ' '; }
reconf_calls() { wc -l <"$CALLS" | tr -d ' '; }
tmpleft() { ls "$TMPDIR" | wc -l | tr -d ' '; }
# run_here <stdin 檔> <指令…>：顯式 stdin；回碼存 rc；stdout+stderr 寫進 $OUT。
# 不放進管線子 shell，LAST_GITLAB_RB_BAK 等全域狀態才看得到。
run_here() {
    local in="$1"
    shift
    rc=0
    "$@" <"$in" >"$OUT" 2>&1 || rc=$?
}
printf 'yes\n' >"$T_TMP/in_yes"
printf 'no\n' >"$T_TMP/in_no"
printf '\n' >"$T_TMP/in_empty"
: >"$T_TMP/in_eof"

# ── now_stamp 預設格式（尚未被覆寫時才測）──
assert_eq "yes" "$([[ $(now_stamp) =~ ^[0-9]{14}$ ]] && echo yes || echo no)" "now_stamp 預設是 14 位數字"

# ── 成功路徑：追加、備份、reconfigure 在寫檔之後 ──
reset_rb
run_here "$T_TMP/in_eof" apply_managed_block foo "x=1"
assert_eq "0" "$rc" "成功回 0"
{ cat "$T_TMP/pristine"; B foo; printf 'x=1\n'; E foo; } >"$T_TMP/want_foo"
assert_file_eq "$T_TMP/want_foo" "$GITLAB_RB" "gitlab.rb：舊內容為前綴、尾端追加區塊"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB.bak-20260101000000" "備份內容等於寫入前的 gitlab.rb"
assert_contains "$(cat "$STUB_LOG")" "chmod 600 $GITLAB_RB.bak-20260101000000" "備份設為 600"
[[ $(uname -s) != Linux ]] || assert_eq "600" "$(stat -c %a "$GITLAB_RB.bak-20260101000000")" "備份實際權限 600"
assert_eq "1" "$(reconf_calls)" "reconfigure 呼叫一次"
assert_file_eq "$T_TMP/want_foo" "$SNAP" "reconfigure 被呼叫當下，gitlab.rb 已含新區塊"
assert_eq "$GITLAB_RB.bak-20260101000000" "$LAST_GITLAB_RB_BAK" "LAST_GITLAB_RB_BAK 記下備份路徑"
assert_eq "0" "$(tmpleft)" "成功路徑：暫存檔已清掉"

# ── 重跑不重複追加；同秒備份不覆蓋 ──
run_here "$T_TMP/in_eof" apply_managed_block foo "x=1"
run_here "$T_TMP/in_eof" apply_managed_block foo "x=1"
assert_file_eq "$T_TMP/want_foo" "$GITLAB_RB" "重跑三次與一次逐 byte 相同"
assert_eq "1" "$(grep -c '^# >>> gitlab-ops:foo BEGIN' "$GITLAB_RB")" "BEGIN 標記行恰 1 行"
assert_eq "3" "$(baks)" "同秒三次備份各自獨立，不覆蓋"

# ── 兩個區塊共存，改一個不動另一個 ──
reset_rb
run_here "$T_TMP/in_eof" apply_managed_block foo "a=1"
run_here "$T_TMP/in_eof" apply_managed_block bar "b=1"
run_here "$T_TMP/in_eof" apply_managed_block foo "a=2"
{ cat "$T_TMP/pristine"; B foo; printf 'a=2\n'; E foo; B bar; printf 'b=1\n'; E bar; } >"$T_TMP/want"
assert_file_eq "$T_TMP/want" "$GITLAB_RB" "兩個區塊共存；改 foo 不動 bar"

# ── 事前拒絕：回 2、gitlab.rb 不動、不 reconfigure、不留備份 ──
reset_rb
rm -f "$GITLAB_RB"
run_here "$T_TMP/in_eof" apply_managed_block foo "x"
assert_eq "2" "$rc" "gitlab.rb 不存在：回 2"
assert_eq "0" "$(reconf_calls)" "gitlab.rb 不存在：未 reconfigure"
reset_rb
run_here "$T_TMP/in_eof" apply_managed_block "Bad Name" "x"
assert_eq "2" "$rc" "區塊名稱不合法：回 2"
run_here "$T_TMP/in_eof" apply_managed_block foo $'a\n# >>> gitlab-ops:foo BEGIN'
assert_eq "2" "$rc" "內容含標記行：回 2"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "內容含標記行：gitlab.rb 不變"
{ cat "$T_TMP/pristine"; B foo; } >"$GITLAB_RB"
cp "$GITLAB_RB" "$T_TMP/pristine"
run_here "$T_TMP/in_eof" apply_managed_block foo "x"
assert_eq "2" "$rc" "標記毀損：回 2"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "標記毀損：gitlab.rb byte 不變"
assert_eq "0" "$(reconf_calls)" "拒絕：未 reconfigure"
assert_eq "0" "$(baks)" "拒絕：不留備份"
assert_eq "0" "$(tmpleft)" "拒絕路徑：暫存檔已清掉"
reset_rb
{ printf 'a\r\n'; B foo | tr -d '\n'; printf '\r\nx\r\n'; E foo | tr -d '\n'; printf '\r\n'; } >"$GITLAB_RB"   # CRLF 檔
cp "$GITLAB_RB" "$T_TMP/pristine"
run_here "$T_TMP/in_eof" apply_managed_block foo "x"
assert_eq "2" "$rc" "標記行帶 CRLF：回 2"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "標記行帶 CRLF：gitlab.rb 不變"

# ── 備份失敗：回 2，gitlab.rb 不動 ──
reset_rb
CP_FAIL=1 run_here "$T_TMP/in_eof" apply_managed_block foo "x"
assert_eq "2" "$rc" "備份失敗：回 2"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "備份失敗：gitlab.rb 不變"
assert_eq "0" "$(reconf_calls)" "備份失敗：未 reconfigure"
assert_eq "0" "$(tmpleft)" "備份失敗：暫存檔已清掉"

# ── 寫入中途失敗：回 3、自動由備份還原、不詢問、不 reconfigure ──
reset_rb
write_file_from() { head -c 5 "$1" >"$2"; return 1; }   # 模擬磁碟滿：寫了一半就失敗
run_here "$T_TMP/in_eof" apply_managed_block foo "x"
assert_eq "3" "$rc" "寫入中途失敗：回 3"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "寫入中途失敗：自動還原為原檔 byte（還原不經 write_file_from）"
assert_eq "0" "$(reconf_calls)" "寫入中途失敗：未 reconfigure"
assert_eq "1" "$(baks)" "寫入中途失敗：備份仍在"
assert_eq "0" "$(tmpleft)" "寫入中途失敗：暫存檔已清掉"
reset_rb
write_file_from() { head -c 5 "$1" >"$2"; return 1; }
run_here "$T_TMP/in_yes" apply_managed_block foo "x"
assert_eq "3" "$rc" "寫入失敗（stdin 有 yes）：仍回 3，不詢問"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "寫入失敗（stdin 有 yes）：已還原"
reset_rb
write_file_from() { head -c 5 "$1" >"$2"; return 1; }
restore_gitlab_rb() { echo "還原失敗，請手動以 $1 還原 gitlab.rb" >&2; return 1; }
run_here "$T_TMP/in_eof" apply_managed_block foo "x"
assert_eq "3" "$rc" "寫入與還原都失敗：回 3"
assert_contains "$(cat "$OUT")" "$GITLAB_RB.bak-20260101000000" "輸出含備份路徑"
assert_contains "$(cat "$OUT")" "手動" "輸出含人工還原指示"

# ── reconfigure 失敗：詢問是否還原 ──
{ cat "$T_TMP/default.rb"; B foo; printf 'x=1\n'; E foo; } >"$T_TMP/want_new"
reset_rb
RECONF_RC=1 run_here "$T_TMP/in_yes" apply_managed_block foo "x=1"
assert_eq "1" "$rc" "reconfigure 失敗＋yes：回 1"
assert_file_eq "$T_TMP/want_new" "$SNAP" "reconfigure 當下 gitlab.rb 含新區塊（還原不是因為根本沒寫）"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "reconfigure 失敗＋yes：gitlab.rb 還原為原檔 byte"
assert_eq "0" "$(tmpleft)" "reconfigure 失敗：暫存檔已清掉"
reset_rb
RECONF_RC=1 run_here "$T_TMP/in_no" apply_managed_block foo "x=1"
assert_eq "1" "$rc" "reconfigure 失敗＋no：回 1"
assert_file_eq "$T_TMP/want_new" "$GITLAB_RB" "reconfigure 失敗＋no：保留新區塊"
assert_contains "$(cat "$OUT")" "$GITLAB_RB.bak-20260101000000" "reconfigure 失敗＋no：印出備份路徑"
reset_rb
RECONF_RC=1 run_here "$T_TMP/in_empty" apply_managed_block foo "x=1"
assert_file_eq "$T_TMP/want_new" "$GITLAB_RB" "reconfigure 失敗＋空行：視同 no，保留新區塊"
reset_rb
RECONF_RC=1 run_here "$T_TMP/in_eof" apply_managed_block foo "x=1"
assert_eq "1" "$rc" "reconfigure 失敗＋EOF：回 1"
assert_file_eq "$T_TMP/want_new" "$GITLAB_RB" "reconfigure 失敗＋EOF：視同 no，保留新區塊"

# ── reconfigure 失敗、答 yes，但還原失敗：仍回 1，印人工還原指示 ──
reset_rb
restore_gitlab_rb() { echo "還原失敗，請手動以 $1 還原 gitlab.rb" >&2; return 1; }
RECONF_RC=1 run_here "$T_TMP/in_yes" apply_managed_block foo "x=1"
assert_eq "1" "$rc" "答 yes 但還原失敗（覆寫 restore）：回 1"
assert_contains "$(cat "$OUT")" "手動" "答 yes 但還原失敗：印人工還原指示"
reset_rb
gitlab_reconfigure() { rm -f "$GITLAB_RB".bak-*; return 1; }   # reconfigure 失敗，且備份不見
run_here "$T_TMP/in_yes" apply_managed_block foo "x=1"
assert_eq "1" "$rc" "備份不見、真實 restore 失敗：仍回 1"
assert_contains "$(cat "$OUT")" "手動" "備份不見：印人工還原指示"

# ── remove_managed_block ──
reset_rb
run_here "$T_TMP/in_eof" apply_managed_block foo "x=1"
run_here "$T_TMP/in_eof" apply_managed_block bar "y=1"
cp "$GITLAB_RB" "$T_TMP/before_remove"
rm -f "$CALLS" "$SNAP" "$GITLAB_RB".bak-*
: >"$CALLS"
run_here "$T_TMP/in_eof" remove_managed_block foo
assert_eq "0" "$rc" "remove 成功回 0"
{ cat "$T_TMP/default.rb"; B bar; printf 'y=1\n'; E bar; } >"$T_TMP/want"
assert_file_eq "$T_TMP/want" "$GITLAB_RB" "remove：只移除指定區塊，其餘 byte 不變"
assert_file_eq "$T_TMP/before_remove" "$GITLAB_RB.bak-20260101000000" "remove：備份是移除前的內容"
assert_eq "1" "$(reconf_calls)" "remove：reconfigure 一次"
assert_file_eq "$T_TMP/want" "$SNAP" "remove：reconfigure 當下區塊已不在"
# 區塊不存在：回 0，不備份、不寫、不 reconfigure
reset_rb
run_here "$T_TMP/in_eof" remove_managed_block foo
assert_eq "0" "$rc" "remove 區塊不存在：回 0"
assert_eq "0" "$(baks)" "remove 區塊不存在：無備份"
assert_eq "0" "$(reconf_calls)" "remove 區塊不存在：未 reconfigure"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "remove 區塊不存在：gitlab.rb 不變"
# reconfigure 失敗：yes 還原（還原後含回區塊）、no 保留
reset_rb
run_here "$T_TMP/in_eof" apply_managed_block foo "x=1"
cp "$GITLAB_RB" "$T_TMP/with_foo"
RECONF_RC=1 run_here "$T_TMP/in_yes" remove_managed_block foo
assert_eq "1" "$rc" "remove reconfigure 失敗＋yes：回 1"
assert_file_eq "$T_TMP/with_foo" "$GITLAB_RB" "remove 失敗＋yes：區塊還原回來"
assert_file_eq "$T_TMP/pristine" "$SNAP" "remove：失敗當下快照不含該區塊"
RECONF_RC=1 run_here "$T_TMP/in_no" remove_managed_block foo
assert_eq "1" "$rc" "remove reconfigure 失敗＋no：回 1"
assert_eq "no" "$(grep -q 'gitlab-ops:foo' "$GITLAB_RB" && echo yes || echo no)" "remove 失敗＋no：保留移除後的狀態"
# 毀損 → 2
reset_rb
{ cat "$T_TMP/pristine"; B foo; } >"$GITLAB_RB"
cp "$GITLAB_RB" "$T_TMP/pristine"
run_here "$T_TMP/in_eof" remove_managed_block foo
assert_eq "2" "$rc" "remove 標記毀損：回 2"
assert_file_eq "$T_TMP/pristine" "$GITLAB_RB" "remove 標記毀損：gitlab.rb 不變"
run_here "$T_TMP/in_eof" remove_managed_block "Bad Name"
assert_eq "2" "$rc" "remove 名稱不合法：回 2"

# ── 不洩密：含 SECRET-PW 的內容，所有輸出與記錄都不得出現 ──
secret="'password' => 'SECRET-PW'"
sweep() { # sweep <情境>：把 $OUT 與 STUB_LOG 合起來找 SECRET-PW
    local hit
    hit="$(cat "$OUT" "$STUB_LOG" 2>/dev/null | grep -c 'SECRET-PW')"
    assert_eq "0" "$hit" "不洩密：$1"
}
reset_rb
run_here "$T_TMP/in_eof" apply_managed_block ldap "$secret"
sweep "成功"
assert_eq "1" "$(grep -c 'SECRET-PW' "$GITLAB_RB")" "（對照）密碼確實寫進 gitlab.rb"
run_here "$T_TMP/in_eof" remove_managed_block ldap
sweep "remove 成功"
reset_rb
RECONF_RC=1 run_here "$T_TMP/in_yes" apply_managed_block ldap "$secret"
sweep "reconfigure 失敗＋yes"
reset_rb
RECONF_RC=1 run_here "$T_TMP/in_no" apply_managed_block ldap "$secret"
sweep "reconfigure 失敗＋no"
reset_rb
run_here "$T_TMP/in_eof" apply_managed_block ldap "$secret"$'\n# >>> gitlab-ops:x BEGIN'
sweep "內容含標記行被拒"
reset_rb
write_file_from() { head -c 5 "$1" >"$2"; return 1; }
run_here "$T_TMP/in_eof" apply_managed_block ldap "$secret"
sweep "寫入失敗"
reset_rb
write_file_from() { head -c 5 "$1" >"$2"; return 1; }
restore_gitlab_rb() { return 1; }
run_here "$T_TMP/in_eof" apply_managed_block ldap "$secret"
sweep "寫入與還原都失敗"
assert_eq "0" "$(tmpleft)" "各失敗路徑結束後 TMPDIR 為空"
reset_rb
if [[ $(uname -s) == Linux ]]; then
    write_file_from() { echo "tmpmode=$(stat -c %a "$1")" >>"$STUB_LOG"; cat "$1" >"$2"; }
    run_here "$T_TMP/in_eof" apply_managed_block ldap "$secret"
    assert_contains "$(cat "$STUB_LOG")" "tmpmode=600" "暫存檔權限 600"
fi
reset_rb
