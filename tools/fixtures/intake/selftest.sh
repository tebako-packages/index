#!/usr/bin/env bash
# selftest.sh — hermetic self-test of tools/intake_review.rb against the
# checked-in fixtures (the test-probe-registry-row.yml idiom: the truth
# table runs on file://, never the network).
#
#   bash tools/fixtures/intake/selftest.sh
#
# The fixtures carry __ROOT__ / __KEYID__ placeholders: this script
# materializes a run tree under a temp dir — an ephemeral OpenPGP key
# (generated per run, thrown away; no key material is ever checked in),
# detached signatures over the fixture artifacts, and the placeholder
# substitutions — then asserts:
#
#   good-feedstock      → exit 0, verdict GREEN
#   bad-sha-feedstock   → exit 1, the report names Sha256Mismatch
#
# Ruby (stdlib) + gpg are the only requirements (the workflow's legs).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REVIEW="$HERE/../../intake_review.rb"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$GNUPGHOME"' EXIT

export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"

# An ephemeral ed25519 primary, never saved anywhere but the temp dir.
gpg --batch --no-tty --pinentry-mode loopback --passphrase "" \
  --quick-generate-key "intake fixture <fixture@example.com>" ed25519 sign never
KEYID="$(gpg --batch --no-tty --with-colons --list-keys \
  | awk -F: '/^pub:/ {print $5; exit}' | tr 'A-F' 'a-f')"
gpg --batch --no-tty --export "intake fixture <fixture@example.com>" > "$WORK/key.asc"

cp -R "$HERE/good-feedstock" "$HERE/bad-sha-feedstock" "$WORK/"
for f in "$WORK"/*/release-*/*.tfs; do
  gpg --batch --no-tty --yes --pinentry-mode loopback --passphrase "" \
    --detach-sign -u "$KEYID" --output "$f.asc" "$f"
done

materialize() {
  sed -e "s|__ROOT__|$WORK|g" -e "s|__KEYID__|$KEYID|g" "$1"
}

materialize "$HERE/good-feedstock/tpkg-registry.yaml" > "$WORK/good-feedstock/tpkg-registry.yaml"
materialize "$HERE/bad-sha-feedstock/tpkg-registry.yaml" > "$WORK/bad-sha-feedstock/tpkg-registry.yaml"
materialize "$HERE/head-good.yaml" > "$WORK/head-good.yaml"
materialize "$HERE/head-bad-sha.yaml" > "$WORK/head-bad-sha.yaml"
materialize "$HERE/base.yaml" > "$WORK/base.yaml"

fail=0

echo "== leg 1: a valid submission is GREEN"
if ruby "$REVIEW" --base "$WORK/base.yaml" --head "$WORK/head-good.yaml" \
     --allow-file-refs --report "$WORK/verdict-good.md"; then
  grep -q "verdict: GREEN" "$WORK/verdict-good.md" \
    && echo "ok: GREEN verdict" || { echo "FAIL: report lacks the GREEN verdict"; fail=1; }
else
  echo "FAIL: the good fixture went red"; fail=1
fi

echo "== leg 2: a doctored sha256 is RED with the named error"
rc=0
ruby "$REVIEW" --base "$WORK/base.yaml" --head "$WORK/head-bad-sha.yaml" \
  --allow-file-refs --report "$WORK/verdict-bad.md" || rc=$?
if [ "$rc" -eq 1 ] && grep -q "Sha256Mismatch" "$WORK/verdict-bad.md"; then
  echo "ok: red, Sha256Mismatch named"
else
  echo "FAIL: expected exit 1 naming Sha256Mismatch (got exit $rc)"; fail=1
fi

echo "== leg 3: a catalog change with no submission is RED (NoSubmission)"
rc=0
ruby "$REVIEW" --base "$WORK/base.yaml" --head "$WORK/base.yaml" \
  --allow-file-refs > /dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then echo "ok: red"; else echo "FAIL: expected exit 1 (got $rc)"; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "selftest: all legs green"
else
  echo "selftest: FAILURES" >&2
fi
exit "$fail"
