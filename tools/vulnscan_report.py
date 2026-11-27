#!/usr/bin/env python3
"""vulnscan_report.py — aggregate osv-scanner results into the rolling issue.

Reads every `*.osv.json` (osv-scanner 2.7.x `--format=json` output) in a
directory, dedupes findings across legs by OSV id set, and renders:

  findings.json  the canonical deduped finding set (machine-readable)
  issue-body.md  the rolling issue's body (the current-state document)
  ids.txt        the comma-joined id list for the body's dedupe marker

Exit codes: 0 rendered; 2 usage/input error (a named failure, never a
silent empty report — the workflow treats it as an infra failure).
"""

import json
import sys
from pathlib import Path

MARKER_PREFIX = "<!-- vulnscan-ids:"
MARKER_SUFFIX = "-->"


def sev_score(value):
    """groups[].max_severity arrives as a score string ("7.5") or "" —
    anything unparsable sorts as unscored (0), never crashes the report."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def collect(osv_dir: Path):
    """One finding per OSV group, merged across every scanned SBOM leg."""
    findings = {}
    legs = []
    files = sorted(osv_dir.glob("*.osv.json"))
    if not files:
        sys.exit("vulnscan_report: no *.osv.json files in " + str(osv_dir))
    for path in files:
        doc = json.loads(path.read_text())
        # The leg name rides the file name (the scan loop writes
        # <leg>.osv.json per <leg>.cdx.json) — a clean scan emits
        # "results": [] with no source records at all.
        leg = path.name.removesuffix(".osv.json")
        if leg not in legs:
            legs.append(leg)
        for result in doc.get("results", []):
            for pkg in result.get("packages", []):
                pinfo = pkg.get("package", {})
                pname = "{}@{}".format(pinfo.get("name", "?"), pinfo.get("version", "?"))
                for group in pkg.get("groups", []):
                    ids = sorted(set(group.get("ids", [])) | set(group.get("aliases", [])))
                    if not ids:
                        continue
                    primary = group["ids"][0]
                    aliases = [a for a in ids if a != primary]
                    sev = group.get("max_severity") or ""
                    f = findings.setdefault(primary, {
                        "id": primary,
                        "aliases": sorted(set(aliases)),
                        "max_severity": sev,
                        "packages": {},
                    })
                    if sev and sev_score(sev) > sev_score(f["max_severity"]):
                        f["max_severity"] = sev
                    f["aliases"] = sorted(set(f["aliases"]) | set(aliases))
                    hit = f["packages"].setdefault(pname, set())
                    hit.add(leg)
    for f in findings.values():
        f["packages"] = {p: sorted(legs_) for p, legs_ in sorted(f["packages"].items())}
    ordered = sorted(findings.values(), key=lambda f: (-sev_score(f["max_severity"]), f["id"]))
    return ordered, legs


def render_body(findings, legs, repo, tag, lane, run_url, when):
    lines = []
    lines.append("## Vulnerability scan findings — {} @ {}".format(repo, tag))
    lines.append("")
    lines.append(
        "The rolling issue of the weekly SBOM→CVE scan "
        "(tebako-packages/index's `vuln-scan` workflow; the process doc is "
        "`docs/vulnerability-process.md` in tamatebako/tebako). One issue per "
        "feedstock, deduped by OSV id — the body is the current state; the "
        "comment log carries the per-run deltas."
    )
    lines.append("")
    ids = ",".join(f["id"] for f in findings)
    lines.append("**Last run:** {} ({}) · lane: `{}` · {} SBOM leg(s): {}".format(
        run_url, when, lane, len(legs), ", ".join("`{}`".format(leg) for leg in legs)))
    lines.append("")
    lines.append("{} {} {}".format(MARKER_PREFIX, ids, MARKER_SUFFIX))
    lines.append("")
    if findings:
        lines.append("| id | aliases | max CVSS | affected packages (legs) |")
        lines.append("|---|---|---|---|")
        for f in findings:
            pkgs = "; ".join(
                "{} ({})".format(p, ", ".join(legs_)) for p, legs_ in f["packages"].items())
            alias = ", ".join(f["aliases"]) if f["aliases"] else "—"
            sev = f["max_severity"] or "unscored"
            lines.append("| [{}](https://osv.dev/vulnerability/{}) | {} | {} | {} |".format(
                f["id"], f["id"], alias, sev, pkgs))
    else:
        lines.append("**No findings.** Every scanned component is clean against the OSV database.")
    lines.append("")
    lines.append(
        "Triage: see the process doc. A false positive or accepted risk is "
        "silenced by an `[[IgnoredVulns]]` row with a `reason` in this repo's "
        "`osv-scanner.toml` — never by editing this issue."
    )
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) != 8:
        sys.exit("usage: vulnscan_report.py <osv-dir> <out-dir> <repo> <tag> <lane> <run-url> <when>")
    osv_dir, out_dir, repo, tag, lane, run_url, when = (
        Path(argv[1]), Path(argv[2]), argv[3], argv[4], argv[5], argv[6], argv[7])
    findings, legs = collect(osv_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "findings.json").write_text(json.dumps({
        "repo": repo, "tag": tag, "lane": lane, "run": run_url, "at": when,
        "legs": legs, "findings": findings,
    }, indent=2) + "\n")
    (out_dir / "issue-body.md").write_text(render_body(findings, legs, repo, tag, lane, run_url, when))
    (out_dir / "ids.txt").write_text(",".join(f["id"] for f in findings) + "\n")
    print("vulnscan_report: {} finding(s) across {} leg(s)".format(len(findings), len(legs)))


if __name__ == "__main__":
    main(sys.argv)
