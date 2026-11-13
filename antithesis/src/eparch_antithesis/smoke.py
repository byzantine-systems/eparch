"""Local smoke evaluation: every scenario once, no SDK or container needed.

A smoke run passes when no `always` verdict failed and every `sometimes`
message was witnessed by at least one verdict that held.
"""

from collections.abc import Iterable
from dataclasses import dataclass

from eparch_antithesis.verdicts import Verdict
from eparch_antithesis.workload import Broadcast, Scenario, Statem

SCENARIOS: tuple[Scenario, ...] = (
    Broadcast(burst=8, mode="normal"),
    Broadcast(burst=8, mode="kill"),
    *(Statem(seed=seed) for seed in range(1, 11)),
)


@dataclass(frozen=True, slots=True)
class Summary:
    violations: tuple[tuple[Scenario, Verdict], ...]
    unwitnessed: tuple[str, ...]
    witnessed: tuple[str, ...]

    @property
    def passed(self) -> bool:
        return not self.violations and not self.unwitnessed


def summarise(runs: Iterable[tuple[Scenario, Iterable[Verdict]]]) -> Summary:
    """Fold scenario results into a smoke verdict."""
    violations: list[tuple[Scenario, Verdict]] = []
    sometimes: dict[str, bool] = {}
    for scenario, verdicts in runs:
        for verdict in verdicts:
            match verdict.kind:
                case "always" if not verdict.holds:
                    violations.append((scenario, verdict))
                case "always":
                    pass
                case "sometimes":
                    sometimes[verdict.message] = (
                        sometimes.get(verdict.message, False) or verdict.holds
                    )
    return Summary(
        violations=tuple(violations),
        unwitnessed=tuple(sorted(m for m, held in sometimes.items() if not held)),
        witnessed=tuple(sorted(m for m, held in sometimes.items() if held)),
    )


def render(summary: Summary) -> str:
    lines = [
        f"ALWAYS FAILED {scenario}: {verdict.message}\n  {verdict.details}"
        for scenario, verdict in summary.violations
    ]
    lines += [f"SOMETIMES NEVER SEEN: {message}" for message in summary.unwitnessed]
    if summary.passed:
        lines.append(
            f"smoke ok: {len(summary.witnessed)} sometimes witnessed, "
            "no always violated"
        )
    return "\n".join(lines)
