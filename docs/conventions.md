# Feedstock conventions (spec 13 §9)

## Link modes and exec tiers (spec 07 §8)

| recipe `link_mode` | exec_tier | how it runs |
|--------------------|-----------|-------------|
| `dynamic` | `dynamic` | preload interposition shim (libtfs-preload) — VFS + jails, no extraction. DEFAULT. |
| `wrapped` | `wrapped` | link-time interposition archive inside the binary — no LD_PRELOAD at run time |
| `tfs-native` | `tfs-native` | source patches + libtfs linked (the ruby model) — survives static linking |
| `static` | `static` | plain static — extraction closure, no TFS, no jails |

## Hard rules

- Dynamic builds use `$ORIGIN/../lib` RPATH — relocatable, never
  install-time rewriting.
- Upstream sources pinned by sha256 in `recipe.yml`; every fetch
  verified before use.
- Patch sets follow the tamatebako/ruby naming rules
  (`tfs-<name>-<maj>-<min>-x-<slug>.patch` whole-line, exact-version
  supersede); a patch that fails `git apply --check` aborts the build.
- Releases carry per-triplet payload artifacts + this repo's
  `tpkg-registry.yaml` at the default-branch root.
- Boot-smoke runs the packaged tool's `--version` from the image (no
  extraction where the tier allows) before the release publishes.
- CI legs are one mechanical press per triplet; per-platform handling
  is a recipe feature, not a hack.

## Release hosting (locked)

Every package's BUILT PAYLOADS — platform-specific or platform-free
(universal) — are published as GitHub releases **in the package's own
feedstock repo** (artifacts + SHA256SUMS + its `tpkg-registry.yaml`).
Nothing is hosted centrally: the index repo carries only the catalog
entries pointing at each feedstock's own releases. A package's
artifacts never live in the index, and never in another org's repo.

## Payload signing (spec 09 §9; opt-in per feedstock)

A feedstock opts into OpenPGP signing with a `signing:` block in
`recipe.yml`:

```yaml
signing:
  keyid: "efc3c250f7862a48" # tamatebako root primary (low 64)
  tool:
    repo: "tamatebako/tebako"
    release: "v2.5.0"       # tebako-pkg release pin …
    sha256: "…"             # … digest-verified per platform binary
```

The rules (hello 2.12.2 is the reference implementation):

- **Key material** lives in the org secret `TEBAKO_CI_SIGNING_KEY`
  (SELECTED visibility, named per feedstock) — the CI signing subkey
  of the tamatebako root key, exported ASCII-armored. The pinned
  `keyid` names the key's PRIMARY; `tools/publish` compares it against
  the signer's self-reported primary and fails on any mismatch (a
  subkey rotates without a recipe edit; the primary pin does not).
- **What is signed:** every `.tfs` in the release, plus `SHA256SUMS`
  and `tpkg-registry.yaml` themselves — a detached `.asc` per artifact
  by naming convention (`<artifact>.asc`), published alongside. The
  registry's per-version `signature:` block pins
  `{keyid: <primary>, asc: <first artifact>.asc}`; the installer
  derives the selected artifact's own asc from the naming convention.
- **Fail closed:** a recipe that declares `signing:` with no key
  material in CI fails the publish — a signing feedstock never ships
  unsigned silently. A recipe with no `signing:` block releases
  unsigned with a loud warning (unsigned stays first-class, spec 00
  invariant 7).
- **Verification is the installer's, at fetch/install — never per
  run.** tebako ≥ 2.6.0 embeds the tamatebako root public key, so a
  signed feedstock's payloads verify with zero key registration;
  `TEBAKO_REQUIRE_SIGNED=1` fails closed on unsigned payloads.
