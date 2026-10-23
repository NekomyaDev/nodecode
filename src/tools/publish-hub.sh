#!/usr/bin/env bash
# publish-hub.sh --- put Nodecode's cell index where the organism reads it.
#
# The index is written in nodecode-ai/cells, by pull request. This serves
# index.json as it stands at one commit of that repository (main's head unless
# another is named) at nodecode.ai/dl/cells/index.json, the address
# *HUB-INDEX-URL* reads (cells.lisp), then proves the served bytes. The file
# is read from GitHub at the commit, never from a checkout here, so what is
# served is what merged; and only a commit whose check passes here -- the
# repository's .github/check.sh at that commit, every entry installed and
# loaded against a release in a scratch home -- is served, since the
# organism refuses a broken index whole. The release is nodecode on PATH, or
# NODECODE_HUB_CHECK_BINARY. The one dl/ directory answers at the
# apex and at preview alike, so a release that still reads preview's address
# reads the same bytes.
set -euo pipefail
REF="${1:-main}"
repo="${NODECODE_HUB_REPO:-nodecode-ai/cells}"
. "$(dirname "${BASH_SOURCE[0]}")/publish-config.sh"
host="$(publish_setting NODECODE_PUBLISH_HOST)" || exit 1
remote_dir="$(publish_setting NODECODE_PUBLISH_REMOTE_DIR)/cells" || exit 1
base_url="${NODECODE_PUBLISH_BASE_URL:-https://nodecode.ai}"
url="${base_url%/}/dl/cells/index.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
binary="${NODECODE_HUB_CHECK_BINARY:-$(command -v nodecode || true)}"
test -x "$binary" || { echo "publish-hub: no nodecode release to check with (NODECODE_HUB_CHECK_BINARY)" >&2; exit 1; }
commit="$(gh api "repos/$repo/commits/$REF" --jq .sha)"
mkdir -p "$work/repo/.github"
for file in index.json .github/check.sh .github/check.lisp; do
  gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/$file?ref=$commit" > "$work/repo/$file"
done
bash "$work/repo/.github/check.sh" "$binary" || {
  printf 'publish-hub: %s at %s fails its check here; nothing is served.\n' "$repo" "$commit" >&2
  exit 1
}
cp "$work/repo/index.json" "$work/index.json"
# One rename on the host, so a reader gets the old file or the new, never half.
chmod 0644 "$work/index.json"
ssh -o BatchMode=yes "$host" "mkdir -p '$remote_dir'"
scp -q "$work/index.json" "$host:$remote_dir/.index.json.$commit"
ssh -o BatchMode=yes "$host" "mv -f '$remote_dir/.index.json.$commit' '$remote_dir/index.json'"
# /dl keeps a file with a dot in its name a minute at the edge (web's dl route).
attempt=1
while :; do
  if curl -fsS -o "$work/served" "$url" 2>/dev/null && cmp -s "$work/index.json" "$work/served"; then
    break
  fi
  [ "$attempt" -lt 12 ] || {
    printf 'publish-hub: %s still serves other bytes after %ss; the new file is on the host.\n' "$url" "$((attempt * 15))" >&2
    exit 1
  }
  sleep 15
  attempt=$((attempt + 1))
done
printf 'publish-hub: %s serves %s at %s\n' "$url" "$repo" "$commit"
