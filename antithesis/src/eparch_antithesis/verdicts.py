"""Verdict lines printed by `dev/eparch_dev.gleam`, parsed at the boundary.

Each evaluated property arrives as one `EPARCH {json}` line. Parsing turns
it into an immutable `Verdict` or rejects it, so the rest of the driver
never handles untyped dictionaries.
"""

import json
from collections.abc import Iterable, Iterator, Mapping
from dataclasses import dataclass
from typing import Any, Literal

PREFIX = "EPARCH "

type Kind = Literal["always", "sometimes"]


@dataclass(frozen=True, slots=True)
class Verdict:
    """One evaluated property: `always` must hold on every evaluation,
    `sometimes` must hold at least once across runs."""

    kind: Kind
    message: str
    holds: bool
    details: str


class MalformedVerdict(ValueError):
    """A line carried the verdict prefix but not a well-formed verdict."""


def parse_verdict(payload: str) -> Verdict:
    """Parse the JSON object after the `EPARCH ` prefix."""
    try:
        raw: object = json.loads(payload)
    except json.JSONDecodeError as error:
        raise MalformedVerdict(f"not JSON: {payload!r}") from error
    if not isinstance(raw, dict):
        raise MalformedVerdict(f"not an object: {payload!r}")
    fields: Mapping[str, Any] = raw
    match fields:
        case {
            "kind": "always" | "sometimes" as kind,
            "message": str() as message,
            "holds": bool() as holds,
            "details": str() as details,
        } if message:
            return Verdict(kind=kind, message=message, holds=holds, details=details)
        case _:
            raise MalformedVerdict(f"unexpected fields: {payload!r}")


def verdict_lines(output: Iterable[str]) -> Iterator[Verdict]:
    """Every verdict in the workload's standard output, in order."""
    for line in output:
        if line.startswith(PREFIX):
            yield parse_verdict(line.removeprefix(PREFIX))
