#!/usr/bin/env bash
# pack-macos.sh --- the macOS arm of the release: built, smoked and packed on
# a Mac over ssh.
#
# SPDX-License-Identifier: MIT
#
# Run through `just macos'. SBCL cannot cross-compile and the release waits on
# no CI lane, so the Apple Silicon tarball is packed the way pack.sh packs the
# Linux one -- `just tarball' of the committed revision, the shipped cells
# pulled in from src/cells/bundle.json, named nodecode-<label>-arm64-darwin --
# on a Mac this box reaches over ssh (NODECODE_MACOS_HOST, a publish setting:
# publish-config.sh). The Mac half is the script below this driver's own
# lines, sent with the revision; it is what the retired macOS lane ran
# (533bb5ad6^:.github/workflows/macos.yml): the patched SBCL and its tests, the
# stack scrub, quicklisp on the pinned dist, the tarball, the trial seams, a
# headless serve and the release feed proof. Not the lane's launchd step:
# the Mac is a person's machine, and its LaunchAgents are theirs.
#
# Everything it writes on the Mac is under one directory that names no account
# (NODECODE_MACOS_BUILD_DIR, /Users/Shared/nodecode-build by default: SBCL
# writes every build path into the release), with HOME pointed into it for
# every step: the toolchain (just, the bootstrap SBCL taken from
# Homebrew's bottle without installing it, the patched SBCL), quicklisp and
# the compile caches stay there between releases, and the build tree of each
# run is removed once the tarball is home. It installs nothing: Homebrew's zstd
# and openssl@3 must already be there (the runtime links one, the image and the
# feed proof read the other), and a Mac without them is refused by name.
#
# This driver then proves what came back is the revision it sent: every file of
# src/src and of the shipped cells, the system definition and the installer
# byte-equal inside the tarball, and the sidecar the hash of the bytes.
set -euo pipefail

REV="${1:-HEAD}"
OUT="${2:-dist}"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"

. "$repo/src/tools/publish-config.sh"
mac="$(publish_setting NODECODE_MACOS_HOST)" || exit 1
# The Mac builds under a root that names nobody, never under the account's
# home: SBCL writes every path it compiles or loads into the image and the
# fasls, and pack.sh's gate refuses a tree that carries the account's home.
mroot="${NODECODE_MACOS_BUILD_DIR:-/Users/Shared/nodecode-build}"
case "$mroot" in
  /Users/Shared/?*|/opt/?*) ;;
  *) echo "pack-macos: NODECODE_MACOS_BUILD_DIR is an absolute path under /Users/Shared or /opt, not '$mroot'" >&2; exit 1 ;;
esac
command -v python3 >/dev/null 2>&1 || { echo 'pack-macos: python3 is needed to read the tarball back against the tree' >&2; exit 1; }

commit="$(git rev-parse "$REV^{commit}")"
# NINE hex digits, explicitly (pack.sh's note): a label is what a pointer names.
label="$(git rev-parse --short=9 "$commit")"
name="nodecode-$label-arm64-darwin"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
archive="$OUT/$name.tar.gz"
log="$OUT/macos-$label.log"

ssh_mac() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 "$mac" "$@"
}

# A Mac that is asleep, away or another kind of machine fails here, by name,
# before anything is sent.
facts="$(ssh_mac 'uname -sm' 2>&1)" || {
  printf 'pack-macos: %s does not answer ssh: %s\n' "$mac" "$facts" >&2
  exit 1
}
[ "$facts" = 'Darwin arm64' ] || {
  printf 'pack-macos: %s is %s, not an Apple Silicon Mac\n' "$mac" "$facts" >&2
  exit 1
}

work="$(mktemp -d)"
locked=''
cleanup() {
  if [ -n "$locked" ]; then ssh_mac "rm -rf \"$mroot/.lock\"" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# One build at a time on the Mac: the run directory is one per account.
owner="$(hostname) pid $$ $label $(date -u +%FT%TZ)"
if ! ssh_mac "mkdir -p \"$mroot\" && mkdir \"$mroot/.lock\" && printf '%s\n' '$owner' > \"$mroot/.lock/owner\""; then
  held="$(ssh_mac "cat \"$mroot/.lock/owner\"" 2>/dev/null || true)"
  printf 'pack-macos: another build holds %s/.lock on %s (%s); remove it when none runs\n' "$mroot" "$mac" "${held:-no owner}" >&2
  exit 1
fi
locked=1

# What the Mac builds: a one-commit repository of the revision (pack.sh asks
# git for the label and archives REV), and the script that drives it.
ship="$work/ship"
mkdir -p "$ship"
git init -q "$ship/repo"
git -C "$ship/repo" fetch -q --depth 1 "file://$repo" "$commit"
git -C "$ship/repo" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$ship/repo" rev-parse --short=9 HEAD)" = "$label" ] || {
  echo "pack-macos: the shipped repository is not at $label" >&2
  exit 1
}
# The tree the proof reads the tarball against: the revision and the cells its
# pin names, laid down here the way pack.sh lays them down there.
mkdir -p "$work/tree"
git archive "$commit" | tar -x -C "$work/tree"
"$repo/src/tools/pull-cells.sh" "$work/tree/src/cells" >/dev/null

cat > "$ship/mac.sh" <<'MAC'
#!/bin/bash
# The Mac half of pack-macos.sh. macOS's own bash (3.2): no mapfile, no
# associative arrays. Every path it writes is under B.
set -euo pipefail
label="$1"
B="$2"
run="$B/run"
repo="$run/repo"
name="nodecode-$label-arm64-darwin"
export HOME="$B/env"
export XDG_CACHE_HOME="$HOME/.cache"
export PATH="$B/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset NODECODE_HOME SBCL_HOME CPATH LIBRARY_PATH || true
mkdir -p "$HOME" "$B/bin" "$run/dl"
step() { printf '\n== %s (%ss)\n' "$1" "$SECONDS"; }
cd "$repo"
[ "$(git rev-parse --short=9 HEAD)" = "$label" ] || { echo "mac: the tree is not $label" >&2; exit 1; }

step 'Homebrew zstd and openssl@3, present (nothing is installed)'
for f in /opt/homebrew/opt/zstd/include/zstd.h /opt/homebrew/opt/zstd/lib/libzstd.1.dylib \
         /opt/homebrew/opt/openssl@3/lib/libssl.dylib /opt/homebrew/opt/openssl@3/bin/openssl; do
  [ -e "$f" ] || { echo "mac: $f is missing; this arm needs Homebrew's zstd and openssl@3 and installs nothing outside $B" >&2; exit 1; }
done
export CPATH=/opt/homebrew/opt/zstd/include LIBRARY_PATH=/opt/homebrew/opt/zstd/lib

step 'just'
just_version=1.59.0
just_sha=6574cea774ed4cae12e24b6aa11857de33e80dab4667cf628fd5840df96a2a9d
if ! "$B/bin/just" --version 2>/dev/null | grep -qx "just $just_version"; then
  curl -fsSL --retry 3 -o "$run/dl/just.tar.gz" \
    "https://github.com/casey/just/releases/download/$just_version/just-$just_version-aarch64-apple-darwin.tar.gz"
  echo "$just_sha  $run/dl/just.tar.gz" | shasum -a 256 -c -
  tar -xzf "$run/dl/just.tar.gz" -C "$run/dl" just
  mv "$run/dl/just" "$B/bin/just"
fi
just --version

# The release is dumped on SBCL 2.6.8 plus src/tools/sbcl/patches (build.sh),
# rebuilt when those change, and SBCL's own tests for what the patches touch
# run on every fresh build. Its host is Homebrew's SBCL bottle, unpacked here
# and pointed at the zstd that is present: fetched, never installed.
step 'the patched SBCL'
# The release starts on macOS 15 and later: build.sh sets that floor (for
# clang too); a cached runtime above it is rebuilt below.
minos_of() { vtool -show-build "$1" 2>/dev/null | awk '$1 == "minos" { print $2; exit }'; }
key="$(cat src/tools/sbcl/build.sh src/tools/sbcl/patches/* | shasum -a 256 | cut -d' ' -f1)"
runtime_minos="$(minos_of "$B/sbcl/bin/sbcl" || true)"
if [ ! -x "$B/sbcl/bin/sbcl" ] || [ "$(cat "$B/sbcl/.key" 2>/dev/null || true)" != "$key" ] \
   || [ -z "$runtime_minos" ] || [ "${runtime_minos%%.*}" -gt 15 ]; then
  host="$(ls -d "$B"/host/sbcl/*/ 2>/dev/null | head -n 1 || true)"
  if [ -z "$host" ] || [ ! -x "${host}libexec/bin/sbcl" ]; then
    brewenv="HOMEBREW_CACHE=$run/brew-cache HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1"
    env $brewenv /opt/homebrew/bin/brew fetch --formula sbcl
    bottle="$(env $brewenv /opt/homebrew/bin/brew --cache --formula sbcl)"
    rm -rf "$B/host"
    mkdir -p "$B/host"
    tar -xzf "$bottle" -C "$B/host"
    host="$(ls -d "$B"/host/sbcl/*/ | head -n 1)"
    install_name_tool -change @@HOMEBREW_PREFIX@@/opt/zstd/lib/libzstd.1.dylib \
      /opt/homebrew/opt/zstd/lib/libzstd.1.dylib "${host}libexec/bin/sbcl" 2>/dev/null
    codesign -f -s - "${host}libexec/bin/sbcl"
  fi
  mkdir -p "$run/hostbin"
  printf '#!/bin/sh\nSBCL_HOME="%slib/sbcl" exec "%slibexec/bin/sbcl" "$@"\n' "$host" "$host" > "$run/hostbin/sbcl"
  chmod 0755 "$run/hostbin/sbcl"
  "$run/hostbin/sbcl" --version
  rm -rf "$B/sbcl"
  PATH="$run/hostbin:$PATH" sh src/tools/sbcl/build.sh "$B/sbcl" "$run/sbcl-build"
  runtime_minos="$(minos_of "$B/sbcl/bin/sbcl")"
  echo "minos sbcl runtime $runtime_minos"
  [ -n "$runtime_minos" ] && [ "${runtime_minos%%.*}" -le 15 ] || {
    echo "mac: the SBCL runtime needs macOS ${runtime_minos:-unknown}; the floor is 15" >&2
    exit 1
  }
  ( cd "$run"/sbcl-build/sbcl-*/tests && sh run-tests.sh exhaust.impure.lisp gc.impure.lisp gc-threads.impure.lisp \
      fcb-threads.impure.lisp dynamic-extent.pure.lisp make-thread.pure.lisp interrupt-consing.impure.lisp )
  printf '%s\n' "$key" > "$B/sbcl/.key"
fi
export PATH="$B/sbcl/bin:$PATH" SBCL_HOME="$B/sbcl/lib/sbcl"
sbcl --version

step 'the stack scrub'
sbcl --control-stack-size 8MB --non-interactive --no-sysinit --no-userinit --load src/tools/sbcl/stack-check.lisp

step 'quicklisp on the pinned dist'
dist=2026-01-01
if [ ! -f "$HOME/quicklisp/setup.lisp" ]; then
  curl -fsSLo "$run/dl/quicklisp.lisp" https://beta.quicklisp.org/quicklisp.lisp
  sbcl --noinform --non-interactive --no-userinit --load "$run/dl/quicklisp.lisp" --eval '(quicklisp-quickstart:install)'
fi
cat > "$HOME/.sbclrc" <<'RC'
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))
RC
sbcl --noinform --non-interactive \
  --eval "(unless (equal (ql-dist:version (ql-dist:find-dist \"quicklisp\")) \"$dist\") (ql-dist:install-dist \"http://beta.quicklisp.org/dist/quicklisp/$dist/distinfo.txt\" :replace t :prompt nil))" \
  --eval '(format t "~&dist ~a~%" (ql-dist:version (ql-dist:find-dist "quicklisp")))'
( cd src && sbcl --dynamic-space-size 4096 --control-stack-size 8MB --noinform --non-interactive \
    --eval '(push (truename ".") asdf:*central-registry*)' \
    --eval '(ql:quickload "nodecode" :silent t)' \
    --eval '(format t "~&dependencies present~%")' )

step 'pack the tarball'
rm -rf dist
just tarball HEAD dist
ls -l dist

step 'unpack it where it never was'
mkdir -p "$run/unpacked" "$run/bin"
tar -xzf "dist/$name.tar.gz" -C "$run/unpacked"
dir="$run/unpacked/$name"
ln -sfn "$dir/nodecode" "$run/bin/nodecode"
minos=''
for bin in nodecode nodecode-launcher; do
  m="$(vtool -show-build "$dir/$bin" | awk '$1 == "minos" { print $2; exit }')"
  echo "minos $bin $m"
  [ -n "$m" ] && [ "${m%%.*}" -le 15 ] || { echo "mac: $bin needs macOS ${m:-unknown}; the floor is 15" >&2; exit 1; }
  [ -n "$minos" ] || minos="$m"
done
version="$("$dir/nodecode" --version 2>&1 | tail -n 1)"
echo "version: $version"
case "$version" in *"+$label"*) ;; *) echo "mac: the binary says '$version', not $label" >&2; exit 1 ;; esac

# The trial seams, as the lane ran them. A scratch home that is not
# $HOME/.nodecode: no step here may stand for the account's own home.
step 'the platform seams through the trial verb'
HOME_SCRATCH="$run/trial-home"
mkdir -p "$HOME_SCRATCH"
trial() {
  local out
  out="$(printf '%s\n' "$1" | NODECODE_HOME="$HOME_SCRATCH" "$dir/nodecode" trial 2>&1 || true)"
  { echo "trial: $1"; echo "$out"; } >&2
  local score
  score="$(printf '%s\n' "$out" | sed -n 's/.*nodecode-trial-score \([^ ]*\).*/\1/p' | tail -n 1)"
  [ -n "$score" ] || { echo "no score line for: $1" >&2; exit 1; }
  printf '%s' "$score"
}
expect() { local got; got="$(trial "$2")"; [ "$got" = "$1" ] || { echo "FAIL ($3): expected $1, got $got" >&2; exit 1; }; echo "ok: $3"; }
expect 3 '(+ 1 2)' arithmetic
expect 1 '(if (eq :darwin (nlk:platform)) 1 0)' platform
expect 1 '(if (= 2 (length (multiple-value-list (nlt:terminal-size)))) 1 0)' 'terminal-size without a terminal'
expect 1 '(if (equal "/bin/sh" nlk:*shell*) 1 0)' 'the shell is /bin/sh'
expect 1 '(if (equal "/usr/bin/perl" (first nlk:*session-wrapper*)) 1 0)' 'perl leads the session'
expect 1 '(multiple-value-bind (out err status) (nlk:run-bounded (nlk:shell-argv "echo hi; echo bad 1>&2; exit 4") :seconds 20) (if (and (search "hi" out) (search "bad" err) (eql status 4)) 1 0))' run-bounded
expect 1 '(if (eq :timeout (nth-value 2 (nlk:run-bounded (nlk:shell-argv "sleep 30") :seconds 1))) 1 0)' 'run-bounded timeout'
expect 1 '(multiple-value-bind (out err status) (nlk:run-bounded (nlk:session-argv (nlk:shell-argv "echo led; exit 4")) :seconds 20) (declare (ignore err)) (if (and (search "led" out) (eql status 4)) 1 0))' 'a session of its own answers its status'
expect 1 '(labels ((deep (n) (if (zerop n) (list (nle::control-stack-usage)) (cons n (deep (1- n)))))) (multiple-value-bind (used span) (nle::control-stack-usage) (if (< 0 used (car (last (deep 2000))) (floor span 2)) 1 0)))' 'control stack usage grows with depth'
expect 0 '(handler-case (progn (nle::eval-runaway-thread-probe) 0) (nle::eval-runaway () 1))' 'a shallow evaluation takes no runaway verdict'
expect 0 '(multiple-value-bind (out err status) (nlk:run-bounded (nlk:session-argv (nlk:shell-argv "python3 -c '"'"'import os,sys; sys.exit(0 if os.getsid(0) == int(sys.argv[1]) else 3)'"'"' $$")) :seconds 20) (declare (ignore out err)) (if (integerp status) status 99))' 'the shell leads a session of its own'
expect 1 '(if (nlk:pid-live-p (sb-posix:getpid)) 1 0)' 'pid-live-p self'
expect 1 '(if (nlk:pid-live-p 4000000) 0 1)' 'pid-live-p dead'
lock="$run/probe.lock"
expect 1 "(let ((lock (nlk:lock-file \"$lock\"))) (if (and lock (nlk:file-locked-p \"$lock\") (progn (nlk:unlock-file lock) (not (nlk:file-locked-p \"$lock\")))) 1 0))" lock-file
log="$run/detached.log"
expect 1 "(progn (nlk:spawn-detached (list \"/bin/sh\" \"-c\" \"sleep 1; echo detached-marker\") \"$log\") (sleep 4) (if (search \"detached-marker\" (uiop:read-file-string \"$log\")) 1 0))" spawn-detached
from="$run/from.txt"; to="$run/to.txt"
echo new > "$from"; echo old > "$to"
expect 1 "(progn (nlk:replace-file \"$from\" \"$to\") (if (and (search \"new\" (uiop:read-file-string \"$to\")) (not (probe-file \"$from\"))) 1 0))" replace-file
expect 1 '(if nlk:*source-root* 1 0)' 'the source beside the binary is found'
linked="$(printf '%s\n' '(if (and nlk:*source-root* (nlk:runtime-directory)) 1 0)' | NODECODE_HOME="$HOME_SCRATCH" "$run/bin/nodecode" trial 2>&1 || true)"
printf '%s\n' "$linked" | grep -q 'nodecode-trial-score 1' || { echo "$linked"; echo 'FAIL: the source is not found through the link' >&2; exit 1; }
echo 'ok: the source is found through the link'
expect 1 '(if (plusp (length (nlk::shipped-cells))) 1 0)' 'shipped cells travel'

step 'a headless serve'
store="$run/smoke/history.db"
mkdir -p "$(dirname "$store")"
slog="$run/serve.log"
NODECODE_HOME="$run/serve-home" "$dir/nodecode" serve --store "$store" >"$slog" 2>&1 &
pid=$!
port=''
for i in $(seq 1 120); do
  sleep 0.5
  kill -0 "$pid" 2>/dev/null || break
  if [ -f "$store.owner" ]; then
    port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("port") or "")' "$store.owner" 2>/dev/null || true)"
    [ -n "$port" ] && break
  fi
done
kill -0 "$pid" 2>/dev/null || { tail -n 40 "$slog"; echo 'mac: serve exited before publishing a port' >&2; exit 1; }
[ -n "$port" ] || { tail -n 40 "$slog"; kill "$pid"; echo 'mac: serve never published its port' >&2; exit 1; }
echo "serve published port $port"
kill "$pid"
sleep 2
if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid"; echo 'mac: serve did not stop on SIGTERM' >&2; exit 1; fi
echo 'serve stopped'

# The release feed over real TLS against a host that goes silent and never
# closes: the gateway must leave it and act on the next label.
step 'the release feed leaves a silent connection'
OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl python3 src/tools/feed-proof.py "$dir/nodecode"

sha="$(shasum -a 256 "dist/$name.tar.gz" | cut -d' ' -f1)"
printf '\nmacos-release-ok %s minos %s sha256 %s (%ss)\n' "$label" "$minos" "$sha" "$SECONDS"
MAC
chmod 0755 "$ship/mac.sh"

rm -f "$archive" "$archive.sha256"
echo "pack-macos: building $name on $mac under $mroot; the log is $log"
# The run directory is each build's own: what the last one left is replaced.
tar -C "$ship" -cf - repo mac.sh |
  ssh_mac "rm -rf \"$mroot/run\" && mkdir -p \"$mroot/run\" && tar -xf - -C \"$mroot/run\""
rc=0
ssh_mac "/bin/bash \"$mroot/run/mac.sh\" $label \"$mroot\"" 2>&1 | tee "$log" || rc=$?
[ "$rc" = 0 ] || { echo "pack-macos: the Mac run failed (rc $rc); read $log (its tree stays in $mroot/run on $mac)" >&2; exit 1; }
verdict="$(grep "^macos-release-ok $label " "$log" | tail -n 1)"
[ -n "$verdict" ] || { echo "pack-macos: the Mac never said 'macos-release-ok $label'; read $log" >&2; exit 1; }

scp -q "$mac:$mroot/run/repo/dist/$name.tar.gz" "$mac:$mroot/run/repo/dist/$name.tar.gz.sha256" "$OUT/"
local_sha="$(sha256sum "$archive" | cut -d' ' -f1)"
sidecar_sha="$(cut -d' ' -f1 < "$archive.sha256")"
mac_sha="$(printf '%s\n' "$verdict" | sed -n 's/.* sha256 \([0-9a-f]*\).*/\1/p')"
[ "$local_sha" = "$sidecar_sha" ] && [ "$local_sha" = "$mac_sha" ] || {
  echo "pack-macos: the tarball is not the bytes the Mac proved: here $local_sha, sidecar $sidecar_sha, Mac $mac_sha" >&2
  exit 1
}

# What shipped is the tree, not what the Mac says it packed (pack-windows.sh's
# proof, for a tarball): every file of src/src and of the shipped cells, the
# system definition and the installer, hashed against the tree sent.
python3 - "$archive" "$work/tree" "$name" <<'PY'
import hashlib, os, sys, tarfile

archive, tree, name = sys.argv[1], sys.argv[2], sys.argv[3]
with tarfile.open(archive) as t:
    members = {m.name: m for m in t.getmembers()}
    links = [n for n, m in members.items() if m.issym() or m.islnk()]
    if links:
        sys.exit('pack-macos: the tarball carries links, first %s' % links[:3])
    junk = [n for n in members if os.path.basename(n).startswith('._')]
    if junk:
        sys.exit('pack-macos: the tarball carries AppleDouble files, first %s' % junk[:3])
    wanted = []
    for base, prune_tests in (('src/src', False), ('src/cells', True)):
        for dirpath, dirnames, filenames in os.walk(os.path.join(tree, base)):
            if prune_tests:
                dirnames[:] = [d for d in dirnames if d != 'test']
            for f in filenames:
                wanted.append(os.path.relpath(os.path.join(dirpath, f), tree))
    wanted += ['src/nodecode.asd']
    pairs = [(rel, rel) for rel in wanted] + [('src/tools/install.sh', 'install.sh')]
    missing, differ = [], []
    for here_rel, there_rel in pairs:
        member = members.get('%s/%s' % (name, there_rel))
        if member is None or not member.isfile():
            missing.append(there_rel)
            continue
        with open(os.path.join(tree, here_rel), 'rb') as f:
            here = hashlib.sha256(f.read()).hexdigest()
        there = hashlib.sha256(t.extractfile(member).read()).hexdigest()
        if here != there:
            differ.append(there_rel)
    if missing:
        sys.exit('pack-macos: %d of %d tree files are not in the tarball, first %s' % (len(missing), len(pairs), missing[:5]))
    if differ:
        sys.exit('pack-macos: %d files of the tarball are not the tree, first %s' % (len(differ), differ[:5]))
    for required in ('nodecode', 'nodecode-launcher'):
        m = members.get('%s/%s' % (name, required))
        if m is None or not m.isfile() or m.size == 0 or not (m.mode & 0o111):
            sys.exit('pack-macos: the tarball carries no executable %s' % required)
    if not any(n.startswith('%s/src/fasl/' % name) and members[n].isfile() for n in members):
        sys.exit('pack-macos: the tarball carries no compiled cells (src/fasl/)')
    tests = [n for n in members if '/test/' in n]
    if tests:
        sys.exit('pack-macos: the tarball carries %d test paths, first %s' % (len(tests), tests[:3]))
    print('pack-macos: %d tree files byte-equal inside %s (%d members, %d bytes)'
          % (len(pairs), os.path.basename(archive), len(members), os.path.getsize(archive)))
PY

# The build tree goes; the toolchain, quicklisp and the caches stay for the
# next release.
ssh_mac "rm -rf \"$mroot/run\"" || true
echo "pack-macos: $verdict"
echo "pack-macos: $name.tar.gz sha256 $local_sha"
