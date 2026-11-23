"""Unit tests for the pure parts of the driver; the BEAM run itself is
covered by `make antithesis-smoke`."""

import json

import pytest

from eparch_antithesis import smoke
from eparch_antithesis.cli import report
from eparch_antithesis.verdicts import (
    MalformedVerdict,
    Verdict,
    parse_verdict,
    verdict_lines,
)
from eparch_antithesis.workload import Broadcast, Cluster, Statem, arguments


def line(kind: str, message: str, holds: bool, details: str = "") -> str:
    payload = {"kind": kind, "message": message, "holds": holds, "details": details}
    return "EPARCH " + json.dumps(payload)


def test_verdict_lines_parse_only_prefixed_lines() -> None:
    output = [
        "Compiled",
        line("always", "a", True, 'x"\n'),
        "noise",
        line("sometimes", "b", False),
    ]
    assert list(verdict_lines(output)) == [
        Verdict("always", "a", True, 'x"\n'),
        Verdict("sometimes", "b", False, ""),
    ]


@pytest.mark.parametrize(
    "payload",
    [
        "not json",
        "[]",
        '{"kind": "never", "message": "m", "holds": true, "details": ""}',
        '{"kind": "always", "message": "", "holds": true, "details": ""}',
        '{"kind": "always", "message": "m", "holds": "yes", "details": ""}',
        '{"kind": "always", "message": "m", "holds": true}',
    ],
)
def test_malformed_verdicts_are_rejected(payload: str) -> None:
    with pytest.raises(MalformedVerdict):
        parse_verdict(payload)


def test_scenarios_render_the_dev_entry_point_vocabulary() -> None:
    assert arguments(Broadcast(burst=8, mode="kill")) == ["broadcast", "8", "kill"]
    assert arguments(Statem(seed=42)) == ["statem", "42"]
    assert arguments(Cluster(seed=7)) == ["cluster", "7"]
    with pytest.raises(ValueError, match="burst"):
        Broadcast(burst=17, mode="normal")


def test_report_routes_each_verdict_to_its_assertion() -> None:
    calls: list[tuple[str, bool, str]] = []
    report(
        [Verdict("always", "a", True, "d"), Verdict("sometimes", "s", False, "e")],
        lambda holds, message, _: calls.append(("always", holds, message)),
        lambda holds, message, _: calls.append(("sometimes", holds, message)),
    )
    assert calls == [("always", True, "a"), ("sometimes", False, "s")]


def test_smoke_requires_every_sometimes_to_be_witnessed_once() -> None:
    first, second = Statem(seed=1), Statem(seed=2)
    summary = smoke.summarise(
        [
            (
                first,
                [
                    Verdict("sometimes", "s", False, ""),
                    Verdict("always", "a", True, ""),
                ],
            ),
            (
                second,
                [
                    Verdict("sometimes", "s", True, ""),
                    Verdict("sometimes", "t", False, ""),
                ],
            ),
        ]
    )
    assert summary.witnessed == ("s",)
    assert summary.unwitnessed == ("t",)
    assert not summary.passed


def test_smoke_fails_on_any_always_violation() -> None:
    violation = Verdict("always", "a", False, "why")
    summary = smoke.summarise([(Statem(seed=1), [violation])])
    assert summary.violations == ((Statem(seed=1), violation),)
    assert "ALWAYS FAILED" in smoke.render(summary)
