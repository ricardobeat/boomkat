#!/usr/bin/env python3
"""Build a C3 target, applying explicit Intl and Temporal feature overrides."""
import argparse
import json
import platform
import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', nargs='?', default='boomkat')
    parser.add_argument('--intl', choices=['default', 'none', 'small', 'full', 'system'], default='default')
    parser.add_argument('--temporal', choices=['default', 'true', 'false'], default='default')
    parser.add_argument('--collator', choices=['default', 'true', 'false'], default='default')
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    targets = json.loads((ROOT / 'project.json').read_text())['targets']
    if args.target not in targets:
        parser.error(f'unknown target: {args.target}')
    if args.intl == 'system':
        parser.error('intl=system requires an ICU backend; available native modes are none, small and full')
    intl_enabled = args.intl != 'none' if args.intl != 'default' else 'INTL' in targets[args.target].get('features', [])
    if args.collator == 'true' and not intl_enabled:
        parser.error('collator=true requires intl=small or intl=full')
    command = ['c3c', 'build', args.target]
    if args.intl != 'default':
        command += ['-U' if args.intl == 'none' else '-D', 'INTL']
        command += ['-D' if args.intl == 'full' else '-U', 'INTL_FULL']
    if args.collator != 'default':
        command += ['-D' if args.collator == 'true' else '-U', 'INTL_COLLATOR']
    elif args.intl != 'default':
        command += ['-D' if args.intl == 'full' else '-U', 'INTL_COLLATOR']
    if args.temporal != 'default':
        command += ['-D' if args.temporal == 'true' else '-U', 'TEMPORAL']
    if args.debug:
        command += ['-O0']
    if platform.system() == 'Darwin' and targets[args.target]['type'] == 'executable':
        command += ['-z', '-Wl,-exported_symbols_list,scripts/no_exports.exp']
    if args.dry_run:
        print(shlex.join(command))
        return 0
    result = subprocess.run(command, cwd=ROOT).returncode
    if result == 0:
        name = targets[args.target].get('name', args.target)
        kind = targets[args.target]['type']
        system = platform.system()
        if kind == 'static-lib':
            name += '.lib' if system == 'Windows' else '.a'
        elif kind == 'dynamic-lib':
            name += '.dll' if system == 'Windows' else '.dylib' if system == 'Darwin' else '.so'
        elif system == 'Windows':
            name += '.exe'
        marker = ROOT / 'out' / ('.profile-' + name)
        if args.intl != 'default' or args.temporal != 'default' or args.collator != 'default' or args.debug:
            marker.touch()
        else:
            marker.unlink(missing_ok=True)
    return result


if __name__ == '__main__':
    raise SystemExit(main())
