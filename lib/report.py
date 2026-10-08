"""Join the session log to real merge outcomes and report what work actually
cost. Invoked by report.sh; not meant to be run directly.

  report.py <sessions.jsonl> <outcomes.json> <pools.yaml> <log_dir>

The wrapper supplies log_dir from project configuration as the read boundary.

The question this answers is the one the raw log cannot: not "how many
sessions did we run" but "what did a merged PR cost, and on which route". An
item that merged after one cheap session and an item that merged after nine
expensive ones look identical in a session count.

Cost is in pool points (pct_per_session from pools.yaml), because that is the
only unit comparable across providers. Sessions on a route with no calibrated
rate are counted but not priced, and the report says how many those were
rather than quietly treating them as free.
"""

import json
import os
import sys
from collections import defaultdict

if __package__:
    from .jsonl import load_jsonl
else:
    from jsonl import load_jsonl

try:
    import yaml
except ImportError:
    sys.exit("report needs PyYAML (pip install pyyaml)")

MERGED = ("MERGED", "merged")


def item_key(row):
    kind = row.get("kind") or ""
    prefix = "pr" if kind.startswith("pr-") else "issue"
    return "%s-%s" % (prefix, row.get("item"))


def known(rows, field):
    """Values of `field` for the rows that have one. A missing or null field is
    unknown (the backend cannot say, or the record predates it) and is left out
    rather than counted as zero."""
    return [r[field] for r in rows if isinstance(r.get(field), (int, float))]


def group(rows, keyfn):
    out = defaultdict(list)
    for row in rows:
        out[keyfn(row)].append(row)
    return out


def quality_line(label, rows):
    retries = known(rows, "retried_dead_ends")
    compactions = known(rows, "compactions")
    biggest = known(rows, "tool_output_max_chars")
    volume = known(rows, "tool_output_chars")
    retry_rate = ("%d/%d = %3.0f%%" % (sum(1 for v in retries if v), len(retries),
                                       100.0 * sum(1 for v in retries if v) / len(retries))
                  if retries else "unknown")
    return "%-26s %8d  %-15s %5s  %-9s %11s  %11s" % (
        label, len(rows), retry_rate,
        "%.1f" % (sum(retries) / len(retries)) if retries else "-",
        "%d (n=%d)" % (sum(compactions), len(compactions)) if compactions else "unknown",
        "{:,}".format(max(biggest)) if biggest else "unknown",
        "{:,}".format(int(sum(volume) / len(volume))) if volume else "unknown")


def quality_report(everything, sessions, items, outcomes):
    """How the sessions went, not what they cost. Every average here is over the
    sessions that could report the field, and says how many that was."""
    print()
    print("Session quality  (retry = a call repeated after an identical one already failed)")
    print()
    print("%-26s %8s  %-15s %5s  %-9s %11s  %11s" % (
        "BACKEND / TIER", "SESSIONS", "RETRIED", "AVG", "COMPACTS", "MAX OUTPUT", "AVG OUTPUT"))
    for (backend, tier), rows in sorted(group(sessions, lambda r: (r.get("backend"), r.get("tier") or "none")).items()):
        print(quality_line("%s / %s" % (backend, tier), rows))
    print("  (unknown = the backend gives no way to tell, or the session predates the field;")
    print("   RETRIED is sessions with at least one retry / sessions that could report it)")

    seeded = group(sessions, lambda r: {True: "with state file", False: "without state file"}.get(r.get("state_seeded"), "state n/a"))
    if len(seeded) > 1 or "state n/a" not in seeded:
        print()
        print("%-26s %8s  %-15s %5s  %-9s %11s  %11s" % (
            "STATE FILE", "SESSIONS", "RETRIED", "AVG", "COMPACTS", "MAX OUTPUT", "AVG OUTPUT"))
        for label in sorted(seeded):
            print(quality_line(label, seeded[label]))

    print()
    print("How sessions ended")
    kinds = group(everything, lambda r: r.get("termination") or "unrecorded")
    for label in sorted(kinds, key=lambda k: -len(kinds[k])):
        by_backend = defaultdict(int)
        for row in kinds[label]:
            by_backend[row.get("backend")] += 1
        print("  %-13s %4d   %s" % (label, len(kinds[label]),
              ", ".join("%s %d" % kv for kv in sorted(by_backend.items()))))

    # Rounds to merge: review rounds an item took, joined to its outcome.
    rounds = {}
    for row in sessions:
        if row.get("kind") == "pr-fix-findings":
            rounds[item_key(row)] = rounds.get(item_key(row), 0) + 1
    merged = {k: n for k, n in rounds.items() if outcomes.get(k) in MERGED}
    print()
    print("Review rounds to merge")
    if not merged:
        print("  no merged PRs with review rounds in the log yet")
    else:
        print("  %d merged PRs, %.1f rounds on average (max %d)"
              % (len(merged), sum(merged.values()) / len(merged), max(merged.values())))
        print("  " + ", ".join("%s x%d" % kv for kv in sorted(merged.items(), key=lambda kv: -kv[1])))
    open_rounds = {k: n for k, n in rounds.items() if k not in merged}
    if open_rounds:
        print("  not merged: " + ", ".join("%s x%d (%s)" % (k, n, outcomes.get(k, "?"))
                                          for k, n in sorted(open_rounds.items())))

    # Attempts per item at each tier, and whether escalating past the first
    # tier actually resolved the item (see agent-loop#10). An item with only
    # one tier in its history was never escalated, by definition.
    tiered = {k: e for k, e in items.items() if e["tiers"]}
    print()
    print("Tier escalation")
    if not tiered:
        print("  no tiered sessions in the log yet (runs without --tier do not carry a tier)")
    else:
        escalated = {k: e for k, e in tiered.items() if len(e["tiers"]) > 1}
        print("  %d items ran on a tier; %d of them escalated past their first tier"
              % (len(tiered), len(escalated)))
        if escalated:
            tier_rank = {"mechanical": 0, "standard": 1, "frontier": 2}
            resolved = [k for k in escalated if outcomes.get(k) in MERGED]
            print("  %d of %d escalated items went on to merge" % (len(resolved), len(escalated)))
            for key in sorted(escalated):
                e = escalated[key]
                tiers = sorted(e["tiers"], key=lambda t: tier_rank.get(t, 99))
                print("    %-12s %d attempts, tiers %s -> %s"
                      % (key, e["sessions"], "/".join(tiers), outcomes.get(key, "?")))


def main():
    sessions_path, outcomes_path, pools_path = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        everything = load_jsonl(sessions_path, sys.argv[4])
    except ValueError as exc:
        sys.exit(str(exc))
    if not everything:
        sys.exit("no sessions in %s" % sessions_path)
    # A refusal is a launch that never ran: it belongs in the termination counts
    # below, not in cost, session counts or per-item history.
    sessions = [r for r in everything if r.get("termination") != "pool-refused"]
    if not sessions:
        sys.exit("no sessions in %s (only pool refusals)" % sessions_path)
    outcomes = {}
    if os.path.exists(outcomes_path):
        with open(outcomes_path, encoding="utf-8") as handle:
            outcomes = json.load(handle)
    with open(pools_path, encoding="utf-8") as handle:
        config = yaml.safe_load(handle)

    routes = config.get("routes") or []
    rate_of = {}
    name_of = {}
    for route in routes:
        key = (route.get("backend"), route.get("effort") or "")
        rate_of[key] = route.get("pct_per_session")
        name_of[key] = route.get("name")

    def route_for(row):
        key = (row.get("backend"), row.get("effort") or "")
        if key in name_of:
            return key
        return (row.get("backend"), "")

    # Per item: sessions, priced cost, routes used, tiers used, and whether it merged.
    items = defaultdict(lambda: {"sessions": 0, "cost": 0.0, "unpriced": 0,
                                 "routes": defaultdict(int), "pools": set(), "tiers": set()})
    by_route = defaultdict(lambda: {"sessions": 0, "cost": 0.0, "unpriced": 0})
    unpriced_total = 0

    for row in sessions:
        key = route_for(row)
        rate = rate_of.get(key)
        label = name_of.get(key) or "%s/%s" % (row.get("backend"), row.get("effort") or "default")
        entry = items[item_key(row)]
        entry["sessions"] += 1
        entry["routes"][label] += 1
        entry["pools"].add(row.get("pool"))
        if row.get("tier"):
            entry["tiers"].add(row["tier"])
        stats = by_route[label]
        stats["sessions"] += 1
        if isinstance(rate, (int, float)):
            entry["cost"] += rate
            stats["cost"] += rate
        else:
            entry["unpriced"] += 1
            stats["unpriced"] += 1
            unpriced_total += 1

    total_cost = sum(e["cost"] for e in items.values())

    print("Cost by outcome  (%d sessions across %d items)" % (len(sessions), len(items)))
    print()
    print("%-12s %-9s %9s %9s  %s" % ("ITEM", "OUTCOME", "SESSIONS", "POOL PTS", "ROUTES USED"))
    for key in sorted(items, key=lambda k: -items[k]["cost"]):
        entry = items[key]
        used = ", ".join("%s x%d" % (r, n) for r, n in
                         sorted(entry["routes"].items(), key=lambda kv: -kv[1]))
        print("%-12s %-9s %9d %9s  %s" % (
            key, outcomes.get(key, "?"), entry["sessions"],
            "%.2f" % entry["cost"] if entry["cost"] else "-", used))

    print()
    print("%-16s %9s %9s %7s" % ("ROUTE", "SESSIONS", "POOL PTS", "SHARE"))
    for label in sorted(by_route, key=lambda k: -by_route[k]["cost"]):
        stats = by_route[label]
        share = (100.0 * stats["cost"] / total_cost) if total_cost else 0.0
        note = "" if not stats["unpriced"] else "   (%d unpriced)" % stats["unpriced"]
        print("%-16s %9d %9.2f %6.1f%%%s" % (label, stats["sessions"], stats["cost"], share, note))

    # The routing question: which work reached merged without ever needing a
    # frontier session, and what share of the spend did it represent.
    cheap_pools = {"cursor-models", "cursor-auto"}
    merged = [k for k, e in items.items() if outcomes.get(k) in MERGED]
    cheap_only = [k for k in merged if items[k]["pools"] <= cheap_pools]
    needed_frontier = [k for k in merged if k not in cheap_only]
    cheap_cost = sum(items[k]["cost"] for k in cheap_only)
    frontier_cost = sum(items[k]["cost"] for k in needed_frontier)
    merged_cost = cheap_cost + frontier_cost

    print()
    print("Grok-suitable work (merged without ever needing a codex/claude session)")
    if not merged:
        print("  no merged items in the log yet -- run report.sh again once some land")
    else:
        print("  %d of %d merged items, %.2f of %.2f pool points (%.1f%% of merged spend)"
              % (len(cheap_only), len(merged), cheap_cost, merged_cost,
                 100.0 * cheap_cost / merged_cost if merged_cost else 0.0))
        print("  %d needed a frontier session, costing %.2f points (%.1f%%)"
              % (len(needed_frontier), frontier_cost,
                 100.0 * frontier_cost / merged_cost if merged_cost else 0.0))
        if cheap_only:
            print("  cheap-only: " + ", ".join(sorted(cheap_only)))
        if needed_frontier:
            print("  needed frontier: " + ", ".join(sorted(needed_frontier)))

    quality_report(everything, sessions, items, outcomes)

    if unpriced_total:
        print()
        print("  ! %d of %d sessions ran on a route with no calibrated rate and are "
              "counted but not priced." % (unpriced_total, len(sessions)))
    unknown = sum(1 for k in items if k not in outcomes)
    if unknown:
        print("  ! %d items have no recorded outcome; re-run report.sh to refresh them."
              % unknown)


if __name__ == "__main__":
    main()
