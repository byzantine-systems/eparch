# Broadcast workload

Run from the repository root in the project devenv:

```sh
gleam build --warnings-as-errors
out=$(mktemp -d)
erlc -Werror -o "$out" antithesis/probe.erl
EPARCH_EBIN='build/dev/erlang/*/ebin' PROBE_EBIN="$out" python3 antithesis/driver.py --smoke
```

The smoke run checks the same receipt trace as the hosted test and requires a completed witness. It needs Erlang/OTP 27+ (`json:encode/1`) and Python 3, but no SDK or container. The image and config under this directory are deployment inputs for the Antithesis test template. The SDK reports safety and reachability separately in that environment.
