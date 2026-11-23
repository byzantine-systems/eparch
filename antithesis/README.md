# Antithesis workload

The scenarios and their oracle are Gleam code in `dev/eparch/workload`,
type-checked against the public API and run by `gleam test`
(`test/workload_test.gleam`) as ordinary properties:

- `broadcast`: one event manager with worker actors. `normal` checks the
  snapshot and admission claims; `kill` kills the manager mid-confirmation
  and checks every client result.
- `statem`: the logical machine and `gen_statem` must deliver the same
  trace for a seeded script, postponed inputs must be redelivered in FIFO
  order, and failed starts must leave the caller's mailbox empty.
- `cluster`: three loopback `peer` nodes. A client calls a `Global` state
  machine on one host and publishes to an event manager on the other,
  under seeded partitions and kills. Checks reply integrity, at-most-once
  effects, no late replies, and how unreachable or dead managers are
  reported. Needs OTP 25+.

`dev/eparch_dev.gleam` prints one `EPARCH {json}` verdict per evaluated
property.

## Driver (`eparch-antithesis`)

This directory is also a small uv project. Its `eparch-antithesis` command
runs one bounded BEAM per Antithesis test command, parses the verdicts into
typed values, and reports each through the Antithesis SDK assertion of the
same name (`always` or `sometimes`). Antithesis supplies the randomness.

The repository devenv provides Python 3.14, uv and pyrefly, and syncs this
project's virtual environment (dev group included) on shell entry. From the
repository root:

```sh
make antithesis-smoke   # every scenario, no SDK or container needed
make antithesis-check   # pytest + pyrefly for the driver itself
```

The smoke run fails if any `always` verdict fails or any `sometimes`
verdict is never witnessed. CI runs both targets. A single scenario can be
run with `gleam dev -- broadcast 8 kill`, `gleam dev -- statem 42` or
`gleam dev -- cluster 42`.

## Deployment

Hosted Antithesis runs container images: `Dockerfile` builds the workload
image (Gleam dev build plus this package installed into `/opt/sdk`), and
`config/` holds the compose file the test template uses. The image installs
the package with pip from `pyproject.toml`, so only the SDK pin applies there,
not `uv.lock`.

The research notes in `scratchbook/` are local working files and are not
committed.
