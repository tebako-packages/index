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
