"""Independent oracle over callback receipts; run one bounded BEAM per command."""
import argparse
import glob
import json
import os
import subprocess

def evaluate(r, always, sometimes):
    prefix = list(range(1, r['n'] + 1)) + ['gate']
    checks = []
    if r['first'] == 'confirmed':
        ordered = r['at_return'] == prefix
        always(ordered, 'Confirmed prefix equals completed callback trace', r)
        checks.append(ordered)
    recovered = r['pressure'] == 'sync_busy' and r['final'] == 'confirmed'
    sometimes(recovered, 'A saturated manager accepts a later fence', r)
    if r['final'] == 'confirmed':
        excluded = 'gate' not in r['late'] and not any(isinstance(x, int) for x in r['late'])
        always(excluded, 'Late registration excludes the accepted prefix', r)
        checks.append(excluded)
        if r['pressure'] == 'sync_busy':
            clean = all('pressure' not in r[key] for key in ('early', 'late'))
            always(clean, 'Busy publication leaves no callback receipt', r)
            checks.append(clean)
        fence = all(r[key].count('fence') == 1 for key in ('early', 'late'))
        always(fence, 'Confirmed fence reaches both current handlers once', r)
        checks.append(fence)
    # The parent held the gate throughout this call. Timeout is inconclusive;
    # any other non-busy reply contradicts the positive cap of one.
    if r['pressure'] != 'sync_timeout':
        bounded = r['pressure'] == 'sync_busy'
        always(bounded, 'Occupied sync slot rejects another publication', r)
        checks.append(bounded)
    return all(checks), recovered and r['first'] == 'confirmed'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--burst', type=int, choices=range(1, 17))
    parser.add_argument('--smoke', action='store_true', help='require a completed witness locally')
    args = parser.parse_args()
    if args.smoke:
        # Exercise the same oracle inside devenv without installing the SDK.
        def always(ok, label, details):
            if not ok:
                raise AssertionError((label, details))
        def sometimes(ok, label, details):
            pass  # Reachability is required by the completion check below.
        n = args.burst or 8
    else:
        from antithesis.assertions import always, sometimes
        from antithesis.random import random_choice
        n = args.burst or random_choice([1, 2, 4, 8, 16])
    paths = glob.glob(os.environ.get('EPARCH_EBIN', '/app/build/dev/erlang/*/ebin'))
    cmd = ['erl', '+S', '2:2', '-noshell', '-pa', *paths, os.environ.get('PROBE_EBIN', '/app'),
           '-eval', 'probe:run(), halt().', '-extra', str(n)]
    output = subprocess.check_output(cmd, text=True, timeout=65)
    records = [json.loads(s[7:]) for s in output.splitlines() if s.startswith('EPARCH ')]
    if len(records) != 1 or records[0]['n'] != n:
        raise RuntimeError(f'missing or malformed probe result: {output}')
    report = records[0]
    print(json.dumps(report), flush=True)
    safe, complete = evaluate(report, always, sometimes)
    if not safe or (args.smoke and not complete):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
