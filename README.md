# tebako-packages/index

The catalog of the `tebako-packages` org — a registry-of-registries for
tebako toolkit payloads (the conda-forge feedstock model: one repo per
package, each with its own release line).

## For users

```console
$ tebako add-registry tfs:github:tebako-packages/index
$ tebako install inkscape@1.3.2
```

One explicit `add-registry` exposes the whole catalog. Payloads install
from their own feedstock's releases (verified, cached machine-wide,
shims registered).

## For maintainers

Each package is a **feedstock repo** in this org, created from
`templates/feedstock/`. A feedstock carries:

- `recipe.yml` — upstream source (url + sha256), versions, build
  system, link mode → exec tier (`dynamic` | `wrapped` | `tfs-native` |
  `static`), deps on other feedstocks, platforms (triplets).
- `patches/` — per-version patch sets (tamatebako/ruby naming rules:
  whole-line `-x-` default, exact-version supersede).
- `manifests/` — payload manifest templates (spec 03: IDENTITY /
  PROVIDES / DEPENDS, `exec_tier`, `exec_closure`).
- `.github/workflows/` — build matrix per triplet, boot-smoke,
  release per (tool × upstream version), filling the manifest from
  the recipe.

Release tags: `<upstream-version>` (e.g. `1.3.2`); `-N` suffix only for
a packaging re-release of the same upstream (`1.3.2-2`).

Landing a new package: copy the template, fill the recipe, open the
feedstock, then add its registry entry to `tpkg-registry.yaml` here.
See `docs/conventions.md`.
