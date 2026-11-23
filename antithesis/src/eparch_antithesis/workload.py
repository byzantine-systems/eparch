"""Run one Gleam workload scenario in a fresh, bounded BEAM."""

import glob
import os
import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Literal

from eparch_antithesis.verdicts import Verdict, verdict_lines

DEFAULT_EBIN = "/app/build/dev/erlang/*/ebin"
TIMEOUT_SECONDS = 120

type Mode = Literal["normal", "kill"]


@dataclass(frozen=True, slots=True)
class Broadcast:
    burst: int
    mode: Mode

    def __post_init__(self) -> None:
        if not 1 <= self.burst <= 16:
            raise ValueError(f"burst must be within 1..16, got {self.burst}")


@dataclass(frozen=True, slots=True)
class Statem:
    seed: int


@dataclass(frozen=True, slots=True)
class Cluster:
    seed: int


type Scenario = Broadcast | Statem | Cluster


def arguments(scenario: Scenario) -> list[str]:
    """The `eparch_dev` command line for a scenario."""
    match scenario:
        case Broadcast(burst=burst, mode=mode):
            return ["broadcast", str(burst), mode]
        case Statem(seed=seed):
            return ["statem", str(seed)]
        case Cluster(seed=seed):
            return ["cluster", str(seed)]


class WorkloadError(RuntimeError):
    """The BEAM failed, timed out, or printed no verdicts."""


def code_paths(pattern: str | None = None) -> list[str]:
    """Code paths for the compiled eparch dev build (`EPARCH_EBIN` glob)."""
    paths = sorted(glob.glob(pattern or os.environ.get("EPARCH_EBIN", DEFAULT_EBIN)))
    if not paths:
        raise WorkloadError("no compiled ebin directories; run `gleam build` first")
    return paths


def command(scenario: Scenario, paths: Sequence[str]) -> list[str]:
    return [
        "erl",
        "+S",
        "2:2",
        "-noshell",
        "-pa",
        *paths,
        "-eval",
        "eparch_dev:main().",
        "-extra",
        *arguments(scenario),
    ]


def run(scenario: Scenario, paths: Sequence[str] | None = None) -> list[Verdict]:
    """Run a scenario and return its verdicts."""
    argv = command(scenario, code_paths() if paths is None else paths)
    try:
        completed = subprocess.run(
            argv, capture_output=True, text=True, timeout=TIMEOUT_SECONDS, check=True
        )
    except subprocess.CalledProcessError as error:
        raise WorkloadError(
            f"{scenario} exited with {error.returncode}: {error.stderr}"
        ) from error
    except subprocess.TimeoutExpired as error:
        raise WorkloadError(f"{scenario} exceeded {TIMEOUT_SECONDS}s") from error
    verdicts = list(verdict_lines(completed.stdout.splitlines()))
    if not verdicts:
        raise WorkloadError(f"{scenario} printed no verdicts: {completed.stdout!r}")
    return verdicts
