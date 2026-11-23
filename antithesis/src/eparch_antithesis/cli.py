"""Command line: `eparch-antithesis {broadcast,statem,cluster,smoke}`.

`broadcast`, `statem` and `cluster` are Antithesis test commands: Antithesis supplies
the randomness and the SDK records each verdict. `smoke` runs everything
locally and exits non-zero on any failure.
"""

import argparse
import json
from collections.abc import Callable, Iterable, Sequence
from typing import Any

from eparch_antithesis import smoke, workload
from eparch_antithesis.verdicts import Verdict
from eparch_antithesis.workload import Broadcast, Cluster, Scenario, Statem

BURSTS = (1, 2, 4, 8, 16)

type Assertion = Callable[[bool, str, dict[str, Any]], None]


def report(
    verdicts: Iterable[Verdict], always: Assertion, sometimes: Assertion
) -> None:
    """Send each verdict to the SDK assertion of its kind."""
    for verdict in verdicts:
        assertion = always if verdict.kind == "always" else sometimes
        assertion(verdict.holds, verdict.message, {"details": verdict.details})


def antithesis_scenario(name: str) -> Scenario:
    """Pick a scenario with Antithesis-controlled randomness."""
    from antithesis.random import get_random, random_choice

    match name:
        case "broadcast":
            return Broadcast(
                burst=random_choice(list(BURSTS)),
                mode=random_choice(["normal", "kill"]),
            )
        case "cluster":
            return Cluster(seed=get_random() % 2**31)
        case _:
            return Statem(seed=get_random() % 2**31)


def run_antithesis(name: str) -> None:
    from antithesis.assertions import always, sometimes

    scenario = antithesis_scenario(name)
    verdicts = workload.run(scenario)
    print(
        json.dumps({"scenario": str(scenario), "verdicts": len(verdicts)}), flush=True
    )
    report(verdicts, always, sometimes)


def run_smoke() -> int:
    summary = smoke.summarise(
        (scenario, workload.run(scenario)) for scenario in smoke.SCENARIOS
    )
    print(smoke.render(summary))
    return 0 if summary.passed else 1


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="eparch-antithesis", description=__doc__)
    parser.add_argument("command", choices=["broadcast", "statem", "cluster", "smoke"])
    args = parser.parse_args(argv)
    if args.command == "smoke":
        return run_smoke()
    run_antithesis(args.command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
