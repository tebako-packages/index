# Governance — the commons' rules of conduct and removal

The tebako commons is a **curated federation**, not an open firehose and
not a central server. Anyone may self-host a registry and no governance
applies to that; this page governs the curated surface — the feedstocks
this index catalogs — and it is written **before** third-party publish
opens, as a launch prerequisite (tebako-packages/index#23).

## The review expectation

Every community submission is reviewed by a human maintainer before
merge. The `intake-review` workflow's verdict is **report-only**: it
posts its evidence as a PR comment, and it never auto-merges — not on
green, not ever. Automation gates the mechanical properties (schema,
reachability, hashes, signatures, monotonicity); the maintainer gates
everything automation cannot see (naming squatting, license posture,
upstream provenance, a `key_url` that appeared out of nowhere). A
submission with a green verdict and no human review is unmerged, by
design.

## Reporting abuse

A payload in the commons is malware, abusive, infringing, or its
feedstock has gone rogue (re-signed rows under a new key, tag rewrites,
un-pinned fetches):

- **Public report:** open an issue on this repository
  (`tebako-packages/index`) titled `[abuse] <payload>` — what, where,
  and the evidence.
- **Sensitive report** (an actively exploited payload, a private
  disclosure): the org-wide security contact and advisory process land
  with the org `SECURITY.md` follow-up; until it lands, mark the issue
  `[abuse] [sensitive]` and a maintainer will move the discussion to a
  private channel before detail is posted.

**Triage SLA:** a maintainer acknowledges an abuse report within
**3 business days** and states the outcome class: no-action,
quarantine, or takedown.

## The takedown mechanism — `status: withdrawn`

Withdrawal is a **registry row state**, never a deletion:

1. The feedstock's own `tpkg-registry.yaml` — the authored authority for
   its rows — marks the affected version row:

   ```yaml
   - version: '1.2.3'
     status: withdrawn
     reason: confirmed-malicious — <one line, link to the advisory>
     withdrawn_at: '2026-11-25'
     platforms: …           # the row stays, for evidence
   ```

2. The aggregate (`tebako-packages/registry`) flows the row verbatim —
   `status: withdrawn` included — on its next regeneration.
3. Readers speak the schema's evolution law: a resolver that knows the
   field refuses the row with a **named error** (a withdrawn payload is
   a resolution failure you can act on, never a crash — the
   yank-discipline lesson of the metanorma-iso incident); an older
   reader ignores the unknown field and the row is inert metadata. The
   resolver-side refusal lands with the registry chase
   (tamatebako/tebako#1100); the store's `.sha256` sidecars already pin
   what an installed machine has, so a withdrawal never reaches backward
   to break an existing install.

Two grades, one mechanism:

- **Quarantine** — the row is marked `status: withdrawn` pending triage
  outcome. Reversible by re-publish (a new version; the withdrawn row
  stays withdrawn in the record).
- **Takedown** — confirmed-malicious or legally required removal: the
  row is withdrawn, the catalog row is removed from this index (a
  governance PR, not the intake lane), and the release assets are
  deleted or kept as evidence case-by-case (legal holds win).

Row removal happens **only** through this process. The intake lane
itself refuses removals (`RowRemoval`): nobody — contributor or
maintainer — deletes a published row by opening a PR.

## The takedown SLA

A **confirmed-malicious** payload is withdrawn — `status: withdrawn`
merged into the feedstock's registry and the catalog row pulled — within
**24 hours of confirmation**. Propagation to the aggregate rides its
next scheduled regeneration (6-hour cadence, or immediately by
dispatch), so the effective public-index withdrawal is inside
**30 hours**. A suspected payload under triage takes the quarantine
posture at the maintainer's discretion ahead of confirmation.

## Conduct

One expectation covers the whole commons: be the kind of participant a
curator never has to think about — honest submissions, no malware, no
naming squatting, no harassment in the review lane, no pressure on
maintainers to skip the gates. Violations are enforced proportionally:
a declined PR, a quarantined payload, a feedstock removed from the
catalog, or a report to the hosting platform. The org has not yet
adopted a formal code of conduct; adopting the Contributor Covenant (or
recording an equivalent) across `tebako-packages` is a named follow-up
alongside the org `SECURITY.md` work — this paragraph is the standing
expectation until it lands.

## Appeals

A maintainer's outcome can be appealed by replying on the same issue or
PR; a second maintainer reviews. Governance decisions are recorded in
public — the issue, the PR, and the registry rows themselves are the
record.
