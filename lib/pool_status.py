"""Print each usage pool's headroom, reset, observed burn rate and projected
end-of-cycle usage. Invoked by pool-status.sh; not meant to be run directly.

  pool_status.py <pools.yaml> <sessions.jsonl> <log_dir>

The wrapper supplies its configured (or default) log_dir as the read boundary.

The unit that matters is sessions, not percent. Percentages are comparable
only within a pool, so a pool's headroom is reported both ways: the raw
percent, and how many sessions of its cheapest route that percent buys.

Anything unknown prints as "?" rather than a number. A pool whose route has
never been calibrated is not projected at all -- an invented burn rate is
worse than an admitted gap, because routing decisions get made off this table.
"""

import os
import sys
from datetime import datetime, timedelta

if __package__:
    from .jsonl import load_jsonl as load_sessions
else:
    from jsonl import load_jsonl as load_sessions

try:
    import yaml
except ImportError:
    sys.exit("pool-status needs PyYAML (pip install pyyaml)")

# Burn rate is averaged over at most this many days of session history, so an
# old backfilled burst does not get projected forward forever.
BURN_WINDOW_DAYS = 7
# A snapshot older than this is reported as stale; projecting off numbers from
# last week is how you talk yourself into spending a pool you already spent.
STALE_AFTER_DAYS = 1


def parse_when(value):
    """Accept 2026-09-29 or 2026-09-24T20:00."""
    if value is None:
        return None
    text = str(value).strip().replace(" ", "T")
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def topup_hint(pool, rate=None):
    """One line describing the purchase that would unblock a spent pool.

    The loop never buys anything -- it refuses and queues. This exists so the
    refusal carries the owner's own option with it rather than reading as a
    dead end. Buying plan capacity is not an API-billed fallback; it is more
    of the same plan, bought deliberately.
    """
    topup = pool.get("topup")
    if not topup:
        return ""
    grants = topup.get("grants_pct")
    cost = topup.get("cost_usd")
    sessions = ""
    if grants and isinstance(rate, (int, float)) and rate > 0:
        sessions = " (about %d more sessions at this route's rate)" % (grants / rate)
    return " A $%s top-up restores %s%%%s." % (cost, grants, sessions)


def usable_pct(pool):
    """Headroom a headless session may actually spend.

    reserve_pct is capacity held back for something other than this loop --
    on claude-pro, the orchestrator that runs the loop itself. Spending a
    reserved pool down to zero strands the thing doing the spending.
    """
    used = pool.get("used_pct")
    if used is None:
        return None
    return 100 - used - (pool.get("reserve_pct") or 0)


def pick_route(routes, backend, effort, model):
    """The route a launch will actually use.

    Matching on (backend, effort) alone is not enough once two routes share a
    backend and an effort but differ by model -- cursor at effort high is
    grok-high or Sol-via-Cursor depending on the model, and those are different
    pools at wildly different costs. The resolved model decides it.
    """
    effort = effort or ""
    exact = [r for r in routes if r.get("backend") == backend
             and (r.get("effort") or "") == effort
             and (r.get("model") or "") == (model or "")]
    if exact:
        return exact[0]
    if model:
        by_model = [r for r in routes if r.get("backend") == backend
                    and (r.get("model") or "") == model]
        if by_model:
            return by_model[0]
    # No model to disambiguate: prefer a route that does not pin one either.
    same_effort = [r for r in routes if r.get("backend") == backend
                   and (r.get("effort") or "") == effort]
    unpinned = [r for r in same_effort if not r.get("model")]
    if unpinned:
        return unpinned[0]
    if same_effort:
        return same_effort[0]
    any_backend = [r for r in routes if r.get("backend") == backend]
    return any_backend[0] if any_backend else None


def cheapest_route(routes, pool_name):
    """The lowest-cost calibrated route into a pool, and any uncalibrated one."""
    priced = [
        r for r in routes
        if r.get("pool") == pool_name and isinstance(r.get("pct_per_session"), (int, float))
    ]
    if priced:
        return min(priced, key=lambda r: r["pct_per_session"]), True
    any_route = [r for r in routes if r.get("pool") == pool_name]
    return (any_route[0] if any_route else None), False


def check(config_path, backend, effort, model):
    """Pre-flight one route. Exit 0 to proceed, 90 when the pool cannot afford
    another session.

    The constraint this enforces is "plan-included usage only": when a pool is
    spent the work is queued or paused, never failed over to a paid route. So
    there is deliberately no override flag -- if a refusal is wrong, the fix is
    to re-read the dashboard and update pools.yaml, not to wave it through.
    """
    with open(config_path, encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    pools = config.get("pools") or {}
    routes = config.get("routes") or []

    route = pick_route(routes, backend, effort, model)
    if route is None:
        print("POOL_UNKNOWN: no route in pools.yaml for backend=%s effort=%s model=%s; proceeding"
              % (backend, effort or "default", model or "default"))
        return 0

    pool_name = route.get("pool")
    pool = pools.get(pool_name) or {}

    if pool.get("off_limits"):
        print("POOL_OFF_LIMITS: %s is reserved and must never be used by this loop." % pool_name)
        return 90

    if pool.get("session_window_spent"):
        print("POOL_SPENT: %s 5h session window is exhausted (weekly used %s%%). "
              "Wait for that window to reset -- do not fall back to a paid route."
              % (pool_name, pool.get("used_pct") if pool.get("used_pct") is not None else "?"))
        return 90

    used = pool.get("used_pct")
    rate = route.get("pct_per_session")
    reserve = pool.get("reserve_pct") or 0

    if used is None or not isinstance(rate, (int, float)) or rate <= 0:
        # An uncalibrated route on a reserved pool is refused rather than run:
        # a reserve means "be careful here", and being careful with a cost you
        # cannot predict means not spending it. Calibrate it deliberately --
        # drop the reserve for one run -- instead of discovering the rate by
        # eating the reserve.
        if reserve:
            print("POOL_RESERVED: %s holds %d%% back for non-loop use and route '%s' has no "
                  "calibrated rate, so this session's cost cannot be shown to fit. Use another "
                  "route, or lower the reserve deliberately to calibrate."
                  % (pool_name, reserve, route.get("name")))
            return 90
        print("POOL_UNCALIBRATED: %s / route %s has no usable rate yet; proceeding, and this "
              "session will help calibrate it" % (pool_name, route.get("name")))
        return 0

    left = usable_pct(pool)
    sessions_left = left / rate
    if sessions_left < 1:
        print("POOL_SPENT: %s has %.0f%% spendable%s, below the %.2f%% one '%s' session costs. "
              "Queue or pause this work -- do not fall back to a paid route. Resets %s."
              % (pool_name, left, (" after a %d%% reserve" % reserve) if reserve else "",
                 rate, route.get("name"), pool.get("resets") or "?")
              + topup_hint(pool, rate))
        return 90
    if sessions_left < 3:
        print("POOL_LOW: %s has %.0f%% spendable, about %.1f more '%s' sessions. Resets %s."
              % (pool_name, left, sessions_left, route.get("name"), pool.get("resets") or "?")
              + topup_hint(pool, rate))
        return 0
    print("POOL_OK: %s has %.0f%% spendable, about %.0f more '%s' sessions."
          % (pool_name, left, sessions_left, route.get("name")))
    return 0


def route_for_tier(config_path, tier):
    """Pick the cheapest route in a tier whose pool can still afford a session.

    Prints "backend<TAB>effort<TAB>model<TAB>name<TAB>pool" and exits 0, or
    exits 90 when nothing in the tier has headroom. It does not widen the
    search to another tier: tier is the quality bar the work needs, so the
    answer to "nothing affordable clears it" is to wait for a reset, not to
    send the work somewhere that cannot do it -- or somewhere paid.

    Routes with no calibrated rate sort last: prefer a route whose cost is
    known over one that might be anything.
    """
    with open(config_path, encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    pools = config.get("pools") or {}
    candidates = [r for r in (config.get("routes") or []) if r.get("tier") == tier]
    if not candidates:
        print("TIER_UNKNOWN: no route in pools.yaml has tier '%s'" % tier, file=sys.stderr)
        return 90

    def sort_key(route):
        rate = route.get("pct_per_session")
        known = isinstance(rate, (int, float))
        return (0 if known else 1, rate if known else 0.0)

    tried = []
    for route in sorted(candidates, key=sort_key):
        pool_name = route.get("pool")
        pool = pools.get(pool_name) or {}
        if pool.get("off_limits"):
            tried.append("%s (pool %s is off limits)" % (route.get("name"), pool_name))
            continue
        if pool.get("session_window_spent"):
            tried.append("%s (pool %s 5h session window is spent)" % (route.get("name"), pool_name))
            continue
        used = pool.get("used_pct")
        rate = route.get("pct_per_session")
        reserve = pool.get("reserve_pct") or 0
        left = usable_pct(pool)
        if used is not None and isinstance(rate, (int, float)) and rate > 0:
            if left / rate < 1:
                tried.append("%s (pool %s has %.0f%% spendable, needs %.2f%%)"
                             % (route.get("name"), pool_name, left, rate))
                continue
        elif reserve:
            # Same rule as the pre-flight check: an unknown cost cannot be
            # shown to fit inside a reserved pool, so it is not chosen here.
            tried.append("%s (pool %s reserves %d%% and the route is uncalibrated)"
                         % (route.get("name"), pool_name, reserve))
            continue
        print("%s\t%s\t%s\t%s\t%s" % (
            route.get("backend"), route.get("effort") or "",
            route.get("model") or "", route.get("name"), pool_name))
        return 0

    print("TIER_EXHAUSTED: no affordable route for tier '%s'. Tried: %s. Queue this work "
          "until a pool resets -- do not fall back to a paid route."
          % (tier, "; ".join(tried)), file=sys.stderr)
    return 90


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--route":
        # --route <config> <tier>
        sys.exit(route_for_tier(sys.argv[2], sys.argv[3]))

    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        # --check <config> <backend> <effort> [model]
        sys.exit(check(sys.argv[2], sys.argv[3],
                       sys.argv[4] if len(sys.argv) > 4 else "",
                       sys.argv[5] if len(sys.argv) > 5 else ""))

    config_path, sessions_path = sys.argv[1], sys.argv[2]
    with open(config_path, encoding="utf-8") as handle:
        config = yaml.safe_load(handle)

    pools = config.get("pools") or {}
    routes = config.get("routes") or []
    try:
        sessions = load_sessions(sessions_path, sys.argv[3])
    except ValueError as exc:
        sys.exit(str(exc))
    now = datetime.now()

    # Observed burn: sessions per pool inside the window, priced at the route
    # each session actually used where that route is calibrated.
    rate_by_route = {
        (r.get("backend"), r.get("effort") or ""): r.get("pct_per_session") for r in routes
    }
    # Burn is only meaningful inside the current cycle: a session from the
    # previous one was paid for out of a balance that has already reset.
    window_start_for = {}
    for name, pool in pools.items():
        start = now - timedelta(days=BURN_WINDOW_DAYS)
        resets = parse_when(pool.get("resets"))
        cycle_days = pool.get("cycle_days")
        if resets is not None and cycle_days:
            start = max(start, resets - timedelta(days=float(cycle_days)))
        window_start_for[name] = start

    observed = {}
    first_seen = {}
    for row in sessions:
        pool = row.get("pool")
        if row.get("termination") == "pool-refused":
            continue  # nothing ran, so nothing was spent
        when = datetime.fromtimestamp(row.get("ts_start") or 0)
        if not pool or when < window_start_for.get(pool, now):
            continue
        first_seen[pool] = min(first_seen.get(pool, when), when)
        rate = rate_by_route.get((row.get("backend"), row.get("effort") or ""))
        if rate is None:
            rate = rate_by_route.get((row.get("backend"), ""))
        entry = observed.setdefault(pool, {"sessions": 0, "pct": 0.0, "priced": 0})
        entry["sessions"] += 1
        if rate is not None:
            entry["pct"] += rate
            entry["priced"] += 1

    print("Pool status  (%s)" % now.strftime("%Y-%m-%d %H:%M"))
    print()
    header = ("POOL", "USED", "LEFT", "RESETS", "DAYS", "CHEAPEST ROUTE",
              "PCT/SES", "SESSIONS", "BURN/DAY", "PROJECTED")
    print("%-16s %5s %5s %-17s %5s  %-15s %8s %9s %9s %10s" % header)

    notes = []
    for name, pool in pools.items():
        if pool.get("off_limits"):
            print("%-16s %5s %5s %-17s %5s  %-15s %8s %9s %9s %10s"
                  % (name, "-", "-", "-", "-", "OFF LIMITS", "-", "-", "-", "-"))
            continue

        used = pool.get("used_pct")
        # LEFT is what a headless session may actually spend, not the raw
        # remainder: a reserved pool has less available than it appears to.
        left = usable_pct(pool)
        reserve = pool.get("reserve_pct") or 0
        if reserve:
            notes.append("%s: %d%% of the %d%% remaining is reserved for non-loop use, "
                         "leaving %d%% spendable" % (name, reserve, 100 - used, left))
        resets = parse_when(pool.get("resets"))
        days_left = None if resets is None else max(0.0, (resets - now).total_seconds() / 86400)

        route, calibrated = cheapest_route(routes, name)
        route_name = route.get("name") if route else "(no route)"
        rate = route.get("pct_per_session") if (route and calibrated) else None

        sessions_left = "?" if (rate in (None, 0) or left is None) else "~%d" % (left / rate)

        stats = observed.get(name)
        burn = None
        if stats and stats["priced"]:
            # Average over the cycle so far, not over the time since the first
            # session: a loop that only started using a pool yesterday would
            # otherwise project yesterday's intensity as its steady state.
            since = window_start_for.get(name) or first_seen[name]
            elapsed = max(0.5, (now - since).total_seconds() / 86400)
            burn = stats["pct"] / elapsed
        projected = None
        if burn is not None and used is not None and days_left is not None:
            projected = used + burn * days_left
            if projected > 100 and burn > 0:
                empty_in = left / burn
                notes.append(
                    "%s: at this cycle's average burn (%.1f%%/day over %d sessions) it is "
                    "spent in ~%.1f days, %.1f days before it resets."
                    % (name, burn, stats["sessions"], empty_in, days_left - empty_in)
                    + topup_hint(pool, rate))

        flag = ""
        if projected is not None and projected > 100:
            flag = "  OVER"
        if pool.get("contended"):
            flag += "  contended"

        if pool.get("session_window_spent"):
            notes.append("%s: 5h session window is spent; weekly used is still %s%% -- headless "
                         "launches on this pool are refused until that window resets"
                         % (name, used))
        snapshot = parse_when(pool.get("snapshot"))
        if snapshot is not None and (now - snapshot).days > STALE_AFTER_DAYS:
            notes.append("%s: snapshot is %d days old; re-read the dashboard before trusting this row"
                         % (name, (now - snapshot).days))
        if route and not calibrated:
            notes.append("%s: route '%s' has never been calibrated, so sessions left and "
                         "projection are unknown" % (name, route_name))

        print("%-16s %4s%% %4s%% %-17s %5s  %-15s %8s %9s %9s %10s%s" % (
            name,
            "?" if used is None else used,
            "?" if left is None else left,
            pool.get("resets") or "?",
            "?" if days_left is None else "%.1f" % days_left,
            route_name,
            "?" if rate is None else "%.2f" % rate,
            sessions_left,
            "?" if burn is None else "%.2f%%" % burn,
            "?" if projected is None else "%.0f%%" % projected,
            flag,
        ))

    if not sessions:
        notes.append("no sessions recorded yet; burn rate and projection need "
                     "%s (run backfill-sessions.sh to seed it)" % os.path.basename(sessions_path))

    if notes:
        print()
        for note in notes:
            print("  ! " + note)

    print()
    print("  Percent is comparable only within a pool. Route the work by PCT/SES:")
    print("  the cheapest route that clears the task's bar, escalating only on failure.")


if __name__ == "__main__":
    main()
