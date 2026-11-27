# tebako-packages/index

The catalog of the `tebako-packages` org — a registry-of-registries for
tebako toolkit payloads (the conda-forge feedstock model: one repo per
package, each with its own release line).

## For users

```console
$ tebako setup            # seeds the official aggregate registry (one time)
$ tebako install inkscape
```

`tebako setup` seeds the **aggregate registry**
(tebako-packages/registry) — the one document that carries every
published payload row. Payloads install from their own feedstock's
releases (verified, cached machine-wide, shims registered).

This repo's `tpkg-registry.yaml` is the **catalog of the feedstock
registries** (registry-of-registries) — the maintainer view of what
feeds the aggregate. Note: the CLI does not chase `packages:` entries
yet (adding this repo with `add-registry` registers zero payload rows —
resolution goes through the aggregate).

## For maintainers

Each package is a **feedstock repo** in this org, created from
`templates/feedstock/`. A feedstock carries:

- `recipe.yml` — upstream source (url + sha256), versions, build
  system, link mode (`dynamic` | `wrapped` | `tfs-native` |
  `static`), deps on other feedstocks, platforms (triplets).
- `patches/` — per-version patch sets (tamatebako/ruby naming rules:
  whole-line `-x-` default, exact-version supersede).
- `manifests/` — payload manifest templates (spec 03: IDENTITY /
  PROVIDES / DEPENDS).
- `.github/workflows/` — build matrix per triplet, boot-smoke,
  release per (tool × upstream version), filling the manifest from
  the recipe.

Release tags: `<upstream-version>` (e.g. `1.3.2`); `-N` suffix only for
a packaging re-release of the same upstream (`1.3.2-2`).

Landing a new package: copy the template, fill the recipe, open the
feedstock, then add its registry entry to `tpkg-registry.yaml` here.
See `docs/conventions.md`.

## For community publishers

The catalog is open to third-party feedstocks — the **community
feedstock lane**. Open a feedstock from `templates/feedstock/` in your
own org (signed with your own key) or propose one for adoption into
`tebako-packages`, then open a PR here adding your `packages:` row. The
`intake-review` workflow gates the submission — schema, reachability,
sha256 pins, signatures, monotonicity — and posts a report-only verdict;
a human maintainer merges. The rules: `docs/community-feedstock.md`
(the provisioning checklist) and `docs/governance.md` (review
expectation, abuse reports, the `status: withdrawn` takedown mechanism
and SLA, conduct).

## Fleet jobs

- **`pin-roll`** — daily: rolls every Tebakofile repo's tools pins to the
  latest tebako release (bump PRs, byte-verified by `tools/reanchor.rb`).
- **`vuln-scan`** — weekly (Monday 04:23 UTC): the mechanical
  vulnerability process (tamatebako/tebako#1123). Scans every feedstock
  payload's SBOM of record with a pinned osv-scanner and keeps one
  rolling `vulnerability-scan` issue per feedstock repo current — never a
  red cron on vulnerability content, always loud on scanner/infra
  failure. The process doc (triage SLA, the `osv-scanner.toml` override
  mechanism) is `docs/vulnerability-process.md` in tamatebako/tebako;
  fleet-global ignores live in `vulnscan/osv-scanner.toml` here.

## Shared actions

- **`.github/actions/probe-registry-row`** — the "is the row published
  yet?" gate for feedstock CI: does `<payload>@<version>` exist in a
  published registry (optionally on an expected runtime constraint)? A
  registry fetch failure fails the step (a transient error is never
  absence); a missing or skewed row sets `published=false` so gated
  legs skip loudly instead of running red. Feedstock workflows consume
  the one implementation here — never a per-repo copy:

  ```yaml
  - id: probe
    uses: tebako-packages/index/.github/actions/probe-registry-row@main
    with:
      registry-url: https://raw.githubusercontent.com/<org>/<feedstock>/main/tpkg-registry.yaml
      payload: <name>
      version: <version>
      constraint: <expected runtime constraint>   # optional — empty means presence is enough
  ```
