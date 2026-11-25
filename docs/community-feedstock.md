# Provisioning a community feedstock

The commons is a curated federation: anyone publishes tebako payloads
from their own feedstock, and this index is the curated door. There is no
central server to apply to — a feedstock is a git repo built from
`templates/feedstock/`, its releases are its storage, and its
`tpkg-registry.yaml` is its public face. This page is the provisioning
checklist: what you do, what we provision, and what must never happen.

The lane has two arms:

- **External (your org or account).** The feedstock lives in a repo you
  control, signed with your own OpenPGP key. You provision everything;
  we only review the intake PR.
- **Adopted (the `tebako-packages` org).** The feedstock is created for
  you in the org, signed with the org's CI signing subkey. We provision
  the repo; you author the recipe.

Both arms end the same way: an **intake PR** against this repository
that adds your feedstock's row to `tpkg-registry.yaml`, gated by the
`intake-review` workflow and merged by a human (never auto-merged).

## What you do (both arms)

1. **Copy the template.** `templates/feedstock/` carries `recipe.yml`,
   `manifests/payload.yaml`, `patches/`, and the `build-payload`
   workflow (recipe → matrix build → boot-smoke → release). Fill the
   recipe; follow `docs/conventions.md` (link modes, patch naming,
   release hosting).
2. **Pin everything you fetch.** Upstream source by `sha256`; the image
   tooling and signer by release + `sha256` per platform
   (`tools/reanchor.rb` rolls the org pins; an external feedstock pins
   the same fields from the same releases).
3. **Sign your releases.** The recipe/Tebakofile `signing:` block names
   your key's **primary** keyid (low 64 bits, 16 lowercase hex — the
   identity, not a rotating subkey) and the digest-pinned signer tool.
   CI signs every `.tfs` plus `SHA256SUMS` and `tpkg-registry.yaml` with
   a detached `.asc` per artifact. A declared `signing:` block with no
   key material in CI **fails the publish** — never strip the block to
   force a release through.
4. **Publish your public key** (external arm) at a stable `https://`
   URL — armored, one key, the URL outlives re-releases. The intake
   review fetches it from that URL; your row's `key_url:` declares it.
   (Adopted feedstocks skip this: the org root key is published at
   <https://www.tebako.org/.well-known/tebako-key.asc> and embedded in
   the installers.)
5. **Cut a release** (`<upstream-version>`, `-N` suffix for packaging
   re-releases of the same upstream). The tag publishes your
   `tpkg-registry.yaml` at the default-branch root.
6. **Open the intake PR** against `tebako-packages/index` adding one
   row to `tpkg-registry.yaml`:

   ```yaml
   packages:
     - name: <payload>            # the registry row's name — one feedstock, one payload
       kind: app | data | toolkit
       summary: <one line>
       registry: tfs:github:<your-org>/<your-feedstock>
       key_url: https://<your-host>/<your-key>.asc   # external arm only
   ```

   The PR changes `tpkg-registry.yaml` and nothing else (the lane's
   scope gate fails anything wider).
7. **Read the verdict, respond to the review.** The `intake-review`
   workflow posts its report as a PR comment. A maintainer merges or
   declines; the lane never auto-merges.

## What the intake review gates (fail closed, named errors)

- **Schema** — your registry parses as a `schema_version: 1` payload
  registry (the spec 04 §2 grammar; unknown fields are tolerated, so a
  `status: withdrawn` governance row never breaks a parse).
- **Payload present** — the registry carries a payload under your row's
  name.
- **Monotonicity** — an update only adds versions; nothing already
  published disappears or sorts older (yanking is `status: withdrawn`
  via `docs/governance.md`, never a deletion).
- **Reachability** — every artifact URL answers HEAD 200.
- **Integrity** — every artifact downloads and hashes to its row's
  `sha256` pin.
- **Authenticity** — every artifact's detached signature verifies
  against the tamatebako root key, or against your declared `key_url`
  key; the signing key's **primary** must equal the row's pinned keyid.
- **Signed, always** — a version row without a `signature:` block is
  `UnsignedSubmission`. Unsigned stays first-class in self-hosted
  registries (spec 00 invariant 7); the *curated commons* indexes signed
  payloads only.

## What we provision (adopted arm — the tebako#1104 runbook, per repo)

When a community feedstock is adopted into `tebako-packages`, a
maintainer executes the new-repo provisioning runbook (tamatebako/tebako#1104)
on it, and the contributor sees none of it:

1. **ci team grant** — `PUT /orgs/tebako-packages/teams/ci/repos/tebako-packages/<repo>`
   with `push`, so the shared CI machinery can act on the repo.
2. **Secret selections** — the org signing secret
   (`TEBAKO_CI_SIGNING_KEY`) is SELECTED visibility, added per repo via
   the secret's `/repositories` endpoint (the `/selected-repositories`
   sub-path 404s — recorded in tebako#1104).
3. **Repo variables** — signing enables and keyids, per the feedstock's
   `signing:` block.
4. **Branch protection** — linear history, the required check set for a
   feedstock (the build matrix legs + boot-smoke), and **auto-merge
   disabled for intake-adjacent flows** (the aggregate's drift PRs are
   the one sanctioned auto-merge; a community submission never is).
5. **CLA + CodeQL** — the org's contributor agreement workflow and
   CodeQL scanning enabled.
6. **Commit identity** — the repo's first commits carry a real git
   identity (the repo's git config), never an invented bot address.
7. **Registry-source addition** — the feedstock's row lands in this
   index (the intake PR above); for org feedstocks the aggregate
   (`tebako-packages/registry`, `feedstocks.txt`) picks the repo up so
   `tebako setup` users resolve it.

## What you must never do

- **No unsigned releases.** Not "temporarily", not "while the key is
  sorted out". The intake lane rejects them (`UnsignedSubmission`), and
  a feedstock that once published signed rows must never ship an
  unsigned one.
- **No un-pinned fetches.** Every URL a build consumes carries a
  `sha256` pin — upstream tarballs, toolchains, registry rows. An
  un-pinned fetch is a supply-chain hole the review cannot see.
- **No hand-edited registries.** `tpkg-registry.yaml` is generated by
  `tools/publish` at release time. A hand edit diverges from the release
  it claims to describe (the review's hash gates catch it), and the next
  publish overwrites it.
- **No committed key material.** Private keys live only in CI secrets.
  (Test fixtures generate throwaway keys at run time — even fixture
  private halves are never checked in.)
- **No tag rewrites.** A published tag is immutable; a packaging fix is
  a new tag (`1.3.2-2`). Re-pointing a tag silently changes what an
  already-published registry row means.
- **No yank-by-deletion.** Withdrawing a payload is `status: withdrawn`
  through the governance process (`docs/governance.md`), never deleting
  the row, the tag, or the release assets. Deletions crash downstream
  caches into archaeology; a withdrawn row is a named error at resolve
  time.
- **No widened CI permissions.** The feedstock workflow's token stays at
  its template grants; a feedstock never needs admin on anything.
