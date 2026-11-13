"""Bridge from eparch's Gleam workload verdicts to Antithesis SDK assertions.

The scenarios and their oracle live in `dev/eparch/workload` and are
type-checked against the public Gleam API. This package only runs one
bounded BEAM per Antithesis command, parses its verdicts, and reports each
through the SDK assertion of the same name.
"""
