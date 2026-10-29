#!/usr/bin/env bash
set -euo pipefail

# UC-009: where no OpenWrt uci CLI is installed (GitHub backend CI), the
# tests write through the test shim tests/helpers/uci_cli/uci
# (selected by tests/helpers/uci_cli/select.sh). Its behaviour on the subset
# Forkop uses is pinned here to a transcript recorded with the real CLI
# (tests/fixtures/uci_cli/transcript.txt, uci 74f6277a, 2026-03-12); with a
# real uci on PATH the transcript is checked against it as well (a failure
# only with FORKOP_TEST_UCI_CLI=real, which pins that revision). Calls
# outside the subset must fail loudly and fail the test that made them, and
# the selection must name a missing or broken tool.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT_DIR/tests/helpers/uci_cli/uci"
GOLDEN="$ROOT_DIR/tests/fixtures/uci_cli/transcript.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

# ---- the transcript -----------------------------------------------------------

UCI=""
# step <uci arguments...>: the call, its exit code, stdout and stderr (the
# program path and the parser position "at line N, byte M" left out).
step() {
  local rc=0
  printf '$ uci %s\n' "$*"
  "$UCI" "$@" >out.txt 2>err.txt || rc=$?
  printf '[rc=%s]\n' "$rc"
  sed -n 's/^/  out| /; l 0' out.txt
  sed -n -E 's/^[^ ]*uci: /uci: /; s/ at line [0-9]+(, byte [0-9]+)?$//; s/^/  err| /; l 0' err.txt
}
u() { step -c c -t s "$@"; }
dump() {
  printf '# c/%s (mode %s)\n' "$1" "$(stat -c %a "c/$1")"
  sed -n 's/^/  | /; l 0' "c/$1"
  if [ -e "s/$1" ]; then
    printf '# s/%s\n' "$1"
    sed -n 's/^/  | /; l 0' "s/$1"
  else
    printf '# s/%s absent\n' "$1"
  fi
}

scenario() {
  mkdir -p c
  # Every syntax element the shim reads; the autotune fixtures use a subset.
  cat >c/pk <<'CONF'
# a comment
package pk

config settings 'settings'
	list dns_server 'tls://dns.example'
	list dns_server "192.0.2.1"
	option  plain value
	option esc 'it'\''s'
	option dq "a\"b\\c\td"
	option hash a#b
	option qhash 'x'#tail
	option empty ''
	option spaced a\ b
	option multi 'line one
line two'
config section
	option action 'zapret'
c section 'youtube' # trailing comment
	o label 'You Tube'
	l tags one
	l tags 'two words'
config section 'youtube'
	option extra 'merged'
config autotune_target 'yt'
	option host 'www.youtube.com'
	option resolver '192.0.2.53'
CONF
  chmod 640 c/pk

  # Reads.
  u get pk.settings.dns_server
  u get pk.settings.esc
  u get pk.settings.dq
  u get pk.settings.hash
  u get pk.settings.qhash
  u get pk.settings.empty
  u get pk.settings.spaced
  u get pk.settings.multi
  u get pk.youtube
  u get pk.youtube.extra
  u get pk.youtube.tags
  u get pk
  u get pk.nosec
  u get pk.settings.plain=x
  step -q -c c -t s get pk.nope
  u show pk
  u show pk.youtube
  u show pk.youtube.tags
  u show pk.nosec

  # The autotune manager's policy-set and target-set/-remove.
  u set pk.autotune=autotune
  u set pk.autotune.mode=auto
  u set pk.autotune.confirmations=4
  u set pk.yt=autotune_target
  u set pk.yt.host=m.youtube.com
  u set pk.yt.enabled=1
  u delete pk.yt.resolver
  u set pk.extra=autotune_target
  u set pk.extra.host=extra.example.com
  u set pk.extra.enabled=0
  u delete pk.extra
  dump pk
  u get pk.autotune.mode
  u show pk.yt

  # No change, errors and the remaining commands.
  u set pk.autotune.mode=auto
  u set pk.autotune=autotune
  u delete pk.yt.resolver
  u delete pk.nosec
  u set pk.nosec.opt=1
  u set pk.youtube.bad-opt=1
  u set 'pk.bad-name=x'
  u set 'pk.newsec=bad type'
  u set pk.youtube.label
  u add_list pk.nosec.l=1
  u set pk.settings.dns_server=single
  u add_list pk.settings.plain=second
  u add_list pk.autotune.targets=yt
  u del_list pk.youtube.tags=one
  u del_list pk.youtube.tags=nothere
  u del_list pk.youtube.label=You\ Tube
  u del_list pk.youtube.nothing=x
  u set pk.settings.spaced=
  u set pk.settings.never=
  u set pk.youtube=other_type
  u set "pk.settings.quote=it's \"q\" #x"
  u set "pk.settings.nfqws=--filter-tcp=443 --dpi-desync=fake"
  u set "pk.settings.lines=one
two"
  dump pk
  u get pk.settings.lines
  u commit pk
  dump pk
  u show pk
  u commit pk
  dump pk
  u commit nosuch
  u get nosuch.a

  # A private package copy (-c, -t): set/commit/get.
  mkdir -p cand cand/save
  cp c/pk cand/cand
  step -c cand -t cand/save set "cand.youtube.nfqws_opt=--filter-tcp=443 --dpi-desync=multisplit"
  step -c cand -t cand/save commit cand
  step -c cand -t cand/save get cand.youtube.nfqws_opt
  sed -n 's/^/  | /; l 0' cand/cand

  # Without a delta, commit leaves the file (and its comments) alone.
  printf "# keep me\nconfig a 'x'\n\toption o '1'\n" >c/keep
  u commit keep
  mkdir -p s && : >s/keep
  u commit keep
  printf "keep.nosec.o='skipped'\n" >s/keep
  u commit keep
  dump keep

  # Staged deltas: applied in order, entries that do not apply are skipped.
  printf "config a 'x'\n\toption gone 'g'\n\tlist l 'p'\n\tlist l 'q'\n" >c/pd
  cat >s/pd <<'DELTA'
pd.x.o='from delta'
-pd.x.gone
|pd.x.l='added'
~pd.x.l='p'
pd.nosec.o='skipped'
garbage line here
other.x.o='ignored'
pd.x.m='multi
line'
pd.x.q='it'\''s'
DELTA
  u show pd
  u commit pd
  dump pd

  # Anonymous sections are shown by their index among all sections of the type.
  printf "config b 'n'\nconfig b\n\toption k 'v'\nconfig c\nconfig b\n" >c/anon
  u show anon

  # An option statement without a value changes nothing on load: an earlier
  # value stays, and alone it creates no option (a list keeps its empty entry).
  printf "config a 'x'\n\toption o '1'\n\toption o ''\n\toption bare\n\toption lone ''\n\tlist l ''\n" >c/empty
  u show empty

  # Parse errors.
  printf "config a 'x'\nconfig b 'x'\n" >c/p1
  printf "option o 1\n" >c/p2
  printf "config a 'x'\n\toption o 1 2\n" >c/p3
  printf "config a x\n\toption o 'unterminated\n" >c/p4
  printf "config a 'x'\n\toption bad-o 1\n" >c/p5
  printf "config a 'x'\n\tbogus o 1\n" >c/p6
  printf "config 'bad type'\n" >c/p7
  printf "config a 'x'\n\t'option' o 1\n" >c/p8
  for p in p1 p2 p3 p4 p5 p6 p7 p8; do u show "$p"; done
}

transcript() { # transcript <uci> <dir>
  UCI="$1"
  mkdir -p "$2"
  # File modes are part of the transcript.
  (umask 022 && cd "$2" && scenario)
}

command -v ucode >/dev/null 2>&1 || fail "the uci test shim needs ucode on PATH"
# FORKOP_TEST_UCI_RECORD=1 records the transcript again with the real CLI.
if [ "${FORKOP_TEST_UCI_RECORD:-}" = 1 ]; then
  REAL="$(command -v uci)" || fail "recording needs the OpenWrt uci CLI on PATH"
  mkdir -p "$(dirname "$GOLDEN")"
  transcript "$REAL" "$WORK/record" >"$GOLDEN"
  ok "recorded $GOLDEN with $REAL"
  exit 0
fi
[ -s "$GOLDEN" ] || fail "missing $GOLDEN"
transcript "$SHIM" "$WORK/shim" >"$WORK/shim.txt"
diff -u "$GOLDEN" "$WORK/shim.txt" >&2 || fail "the uci shim differs from the transcript of the real uci CLI"
ok "the shim reproduces the recorded transcript of the real uci CLI"
# The transcript is re-checked against a real uci on PATH. Only
# FORKOP_TEST_UCI_CLI=real (a pinned uci, as in the CI proposal) makes a
# difference a failure: another uci revision on a developer host may word its
# errors differently, which says nothing about the shim.
REAL=""
case "${FORKOP_TEST_UCI_CLI:-auto}" in
  auto) REAL="$(command -v uci 2>/dev/null || true)" ;;
  real)
    REAL="$(command -v uci 2>/dev/null)" ||
      fail "FORKOP_TEST_UCI_CLI=real: the OpenWrt uci CLI (uci -c/-t) is not on PATH"
    ;;
  shim) ;;
  *) fail "FORKOP_TEST_UCI_CLI must be auto, real or shim, not '${FORKOP_TEST_UCI_CLI}'" ;;
esac
if [ -n "$REAL" ]; then
  transcript "$REAL" "$WORK/real" >"$WORK/real.txt"
  if diff -u "$GOLDEN" "$WORK/real.txt" >"$WORK/real.diff"; then
    ok "the recorded transcript matches the real uci CLI ($REAL)"
  else
    cat "$WORK/real.diff" >&2
    [ "${FORKOP_TEST_UCI_CLI:-auto}" != real ] ||
      fail "the real uci CLI ($REAL) differs from the recorded transcript"
    printf 'NOTE: the uci CLI on PATH (%s) differs from the transcript recorded with uci 74f6277a; FORKOP_TEST_UCI_CLI=real makes this a failure, FORKOP_TEST_UCI_RECORD=1 records it again\n' "$REAL"
  fi
elif [ "${FORKOP_TEST_UCI_CLI:-auto}" = shim ]; then
  printf 'NOTE: FORKOP_TEST_UCI_CLI=shim, the transcript is not re-checked against a real uci CLI\n'
else
  printf 'NOTE: no OpenWrt uci CLI on PATH, the transcript is not re-checked against it\n'
fi

# ---- outside the subset: loud, never approximated ------------------------------

mkdir -p "$WORK/loud/c" "$WORK/loud/host"
printf "config section\n\toption action 'zapret'\nconfig section 'named'\n" >"$WORK/loud/c/pk"
printf "config a 'x' ; option o 1\n" >"$WORK/loud/c/semi"
printf "config a 'x'\n\toption o a\\\\\n\toption p 2\n" >"$WORK/loud/c/cont"
printf "config a 'x'\n" >"$WORK/loud/c/staged"
echo "staged.x.o='1'" >"$WORK/loud/host/staged"
export FORKOP_TEST_UCI_SHIM_LOG="$WORK/loud/shim.log"
export FORKOP_TEST_UCI_SHIM_HOST_SAVEDIR="$WORK/loud/host"
loud() { # loud <what> <uci arguments...>
  local what="$1" rc=0
  shift
  (cd "$WORK/loud" && "$SHIM" "$@") >"$WORK/loud/out" 2>"$WORK/loud/err" || rc=$?
  [ "$rc" = 2 ] || fail "$what: exit $rc, want 2 ($(cat "$WORK/loud/err"))"
  grep -Fq 'uci (Forkop test shim): unsupported' "$WORK/loud/err" || fail "$what: no explanation on stderr"
  [ "$(tail -n 1 "$FORKOP_TEST_UCI_SHIM_LOG")" = "$(cat "$WORK/loud/err")" ] || fail "$what: not in the shim log"
}
loud "add" -c c -t s add pk section
loud "rename" -c c -t s rename pk.named=other
loud "revert" -c c -t s revert pk
loud "changes" -c c -t s changes pk
loud "@type[n] reference" -c c -t s get 'pk.@section[0].action'
loud "anonymous cfg name" -c c -t s get pk.cfg01e63d.action
loud "delete by index" -c c -t s delete pk.named.l=0
loud "commit of everything" -c c -t s commit
loud "missing -t" -c c get pk.named
loud "missing -c" -t s get pk.named
loud "live /etc/config" -c /etc/config -t s get pk.named
loud "other options" -c c -t s -X show pk
loud "';' separator" -c c -t s show semi
loud "line continuation" -c c -t s show cont
loud "host staged changes" -c c -t s get staged.x
loud "host save directory" -c c -t "$WORK/loud/host" get pk.named
loud "two arguments" -c c -t s set pk.named.label=a b
loud "quiet does not hide it" -q -c c -t s add pk section
[ ! -e "$WORK/loud/s" ] || fail "a refused call must not write deltas"
unset FORKOP_TEST_UCI_SHIM_LOG FORKOP_TEST_UCI_SHIM_HOST_SAVEDIR
ok "calls outside the subset fail loudly"

# ---- selection: a missing or broken tool is named ------------------------------

tools() { # tools <dir> <command...>: a PATH directory with just these commands
  local dir="$1" cmd
  shift
  mkdir -p "$dir"
  for cmd in "$@"; do ln -s "$(command -v "$cmd")" "$dir/$cmd"; done
}
tools "$WORK/nouci" bash mkdir rm grep cat ucode
tools "$WORK/noucode" bash mkdir rm grep cat
tools "$WORK/brokenuci" bash mkdir rm grep cat ucode
printf '#!/bin/sh\nexit 1\n' >"$WORK/brokenuci/uci"
chmod +x "$WORK/brokenuci/uci"
select_cli() { # select_cli <mode> <PATH>: prints FORKOP_AUTOTUNE_UCI or the failure
  # shellcheck disable=SC2016 # expanded by the inner bash
  env -u FORKOP_AUTOTUNE_UCI FORKOP_TEST_UCI_CLI="$1" PATH="$2" ROOT_DIR="$ROOT_DIR" WORK="$WORK/select" \
    bash -c 'set -euo pipefail; mkdir -p "$WORK"; source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"; echo "cli=$FORKOP_AUTOTUNE_UCI"' 2>&1 || true
}
got="$(select_cli auto "$WORK/nouci")"
case "$got" in *"using the test shim"*"cli=$SHIM") ;; *) fail "auto without uci must use the shim and say so: $got" ;; esac
got="$(select_cli shim "$WORK/nouci")"
[ "$got" = "cli=$SHIM" ] || fail "shim mode: $got"
got="$(select_cli real "$WORK/nouci")"
case "$got" in *"FAIL: FORKOP_TEST_UCI_CLI=real: the OpenWrt uci CLI (uci -c/-t) is not on PATH"*) ;; *) fail "real mode without uci: $got" ;; esac
case "$got" in *cli=*) fail "real mode without uci must stop: $got" ;; esac
got="$(select_cli auto "$WORK/brokenuci")"
case "$got" in *"FAIL: no working uci CLI ($WORK/brokenuci/uci)"*) ;; *) fail "a broken uci must be named: $got" ;; esac
case "$got" in *cli=*) fail "a broken uci must stop the test: $got" ;; esac
got="$(select_cli shim "$WORK/noucode")"
case "$got" in *"FAIL: the uci test shim needs ucode on PATH"*) ;; *) fail "the shim without ucode: $got" ;; esac
got="$(select_cli bogus "$WORK/nouci")"
case "$got" in *"FAIL: FORKOP_TEST_UCI_CLI must be auto, real or shim"*) ;; *) fail "unknown mode: $got" ;; esac
ok "the selection names a missing or broken uci CLI"

# ---- a refused call fails the test, even where the test tolerates it -----------

# Every test that sources select.sh sets its EXIT trap first. Its prologue (up
# to that source line) runs here with a body whose failing uci call the test
# would tolerate (`|| true`, a negative check): the refusal the shim logged
# must still fail the test, and WORK must still be removed.
# shellcheck disable=SC2016 # a literal $ROOT_DIR in the pattern
users="$(grep -rlE '^source "\$ROOT_DIR/tests/helpers/uci_cli/select\.sh"$' "$ROOT_DIR/tests" | LC_ALL=C sort)"
[ -n "$users" ] || fail "no test sources select.sh: the check lost its anchor"
mkdir -p "$WORK/refusal/host"
# shellcheck disable=SC2016 # literal $ROOT_DIR and $WORK for the generated test
with_prologue() { # with_prologue <test file> <body>: runs it, sets RUN_RC and RUN_OUT
  local script="$WORK/refusal/test.sh"
  {
    printf 'set -euo pipefail\nROOT_DIR=%q\n' "$ROOT_DIR"
    sed -e '/^ROOT_DIR=/d' -e '/^source "\$ROOT_DIR\/tests\/helpers\/uci_cli\/select\.sh"$/q' "$1"
    printf 'printf "%%s\\n" "$WORK" >%q\n%s\n' "$WORK/refusal/work" "$2"
  } >"$script"
  rm -f "$WORK/refusal/work"
  RUN_RC=0
  RUN_OUT="$(env -u FORKOP_AUTOTUNE_UCI FORKOP_TEST_UCI_CLI=shim \
    FORKOP_TEST_UCI_SHIM_HOST_SAVEDIR="$WORK/refusal/host" bash "$script" 2>&1)" || RUN_RC=$?
  [ -s "$WORK/refusal/work" ] || fail "${1#"$ROOT_DIR"/}: the body did not run: $RUN_OUT"
  [ ! -e "$(cat "$WORK/refusal/work")" ] || fail "${1#"$ROOT_DIR"/}: WORK was not removed at exit"
}
# shellcheck disable=SC2016 # expanded by the test body
refused='if "$FORKOP_AUTOTUNE_UCI" -c "$WORK" -t "$WORK/uci-save" rename forkop.yt=other 2>/dev/null; then exit 3; fi'
for file in $users; do
  name="${file#"$ROOT_DIR"/}"
  with_prologue "$file" "$refused"$'\nexit 0'
  [ "$RUN_RC" = 1 ] || fail "$name: a tolerated refused call must fail the test, exit $RUN_RC: $RUN_OUT"
  case "$RUN_OUT" in *"FAIL: the uci test shim refused a call"*"unsupported command 'rename'"*) ;;
    *) fail "$name: the refusal is not reported: $RUN_OUT" ;; esac
  with_prologue "$file" "$refused"$'\nexit 3'
  [ "$RUN_RC" = 3 ] || fail "$name: a failing test must keep its exit status, exit $RUN_RC: $RUN_OUT"
  with_prologue "$file" 'exit 0'
  [ "$RUN_RC" = 0 ] || fail "$name: a passing test without refusals must pass, exit $RUN_RC: $RUN_OUT"
  case "$RUN_OUT" in *FAIL*) fail "$name: no refusal, yet: $RUN_OUT" ;; esac
done
ok "a call the shim refused fails the test that tolerated it"
