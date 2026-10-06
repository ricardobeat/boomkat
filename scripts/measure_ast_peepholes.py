#!/usr/bin/env python3
"""Measure AST prototypes on the ES6 suite and focused controls."""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


class CpuLoad:
    def __init__(self):
        if platform.system() != 'Darwin':
            raise RuntimeError('this prototype load monitor requires macOS')
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        self.lib.mach_host_self.restype = ctypes.c_uint
        self.host = self.lib.mach_host_self()
        self.cores = os.cpu_count()

    def read(self):
        ticks = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)
        if self.lib.host_statistics(self.host, 3, ticks, ctypes.byref(count)):
            raise RuntimeError('host_statistics failed')
        return list(ticks)

    def busy(self, before, after):
        delta = [(b - a) & 0xffffffff for a, b in zip(before, after)]
        total = sum(delta)
        return 100 * (delta[0] + delta[1] + delta[3]) / total if total else 0

    def processes(self):
        output = subprocess.check_output(['ps', '-A', '-o', 'pid=,time=,args='], text=True)
        result = {}
        for line in output.splitlines():
            pid, cpu, command = line.strip().split(None, 2)
            pieces = cpu.split(':')
            seconds = sum(float(value) * 60 ** i for i, value in enumerate(reversed(pieces)))
            result[int(pid)] = (seconds, command)
        return result

    def competitors(self):
        result = []
        for pid, (_, command) in self.processes().items():
            if pid == os.getpid():
                continue
            executable = Path(command.split()[0]).name.lower()
            native = (executable in ('c3c', 'clang', 'clang++', 'cc', 'gcc', 'g++', 'qjs', 'duktape')
                      or executable.startswith(('boomkat', 'test262_runner')))
            harness = (executable.startswith(('python', 'node', 'bash', 'sh', 'just'))
                       and any(marker in command for marker in
                               ('benchmarks/', 'run_bench', 'bench_interleaved', 'measure_hot_regions', 'measure_ast_peepholes',
                                'measure_es6', 'measure_ast', 'perf_diff', 'run_test262',
                                'run_local.sh', 'bench-es6', 'test-local', 'rosetta')))
            if native or harness:
                result.append({'pid': pid, 'command': command})
        return result

    def quiet(self, policy, maximum):
        if policy == "workloads":
            last_report = 0
            while self.competitors():
                if time.monotonic() - last_report >= 30:
                    print("Waiting for benchmark jobs to finish", flush=True)
                    last_report = time.monotonic()
                time.sleep(1)
            return []
        consecutive = 0
        observations = []
        last_report = 0
        while consecutive < 2:
            before = self.read()
            competitors = self.competitors()
            time.sleep(1)
            busy = self.busy(before, self.read())
            observations.append(busy)
            quiet = not competitors and not self.competitors()
            if policy == 'idle':
                quiet = quiet and busy <= maximum
            consecutive = consecutive + 1 if quiet else 0
            if not quiet and time.monotonic() - last_report >= 30:
                print(f'Waiting for quiet window: {busy:.1f}% CPU; competitors={competitors}', flush=True)
                last_report = time.monotonic()
        return observations[-2:]


def execute(binary, path, own_children, child_lock):
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        with child_lock:
            start = time.perf_counter()
            process = subprocess.Popen([str(binary), '--script', str(path)], cwd=ROOT,
                                       stdout=stdout, stderr=stderr)
            own_children.add(process.pid)
        _, status, usage = os.wait4(process.pid, 0)
        elapsed = time.perf_counter() - start
        process.returncode = os.waitstatus_to_exitcode(status)
        stdout.seek(0)
        output = stdout.read()
        stderr.seek(0)
        error = stderr.read()
        if process.returncode or b'FAIL' in output:
            raise RuntimeError((binary, path, process.returncode, output, error))
        return {'wall_ms': elapsed * 1000,
                'cpu_s': usage.ru_utime + usage.ru_stime,
                'peak_rss_bytes': usage.ru_maxrss,
                'output_sha256': hashlib.sha256(output).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rounds', type=int, default=9)
    parser.add_argument('--max-background-percent', type=float, default=5)
    parser.add_argument('--load-policy', choices=('workloads', 'idle'), default='workloads')
    parser.add_argument('--filter', default='*')
    parser.add_argument('--paths', nargs='*', type=Path)
    parser.add_argument('--variants', default='baseline,inline,methods,derived,strings,spread,combined')
    parser.add_argument('--baseline', type=Path, default=ROOT / 'out/boomkat-ast-baseline')
    parser.add_argument('--output', type=Path, default=ROOT / 'benchmarks/ast-peepholes/results.json')
    args = parser.parse_args()
    names = args.variants.split(',')
    if args.rounds < 1 or 'baseline' not in names:
        parser.error('positive rounds and a baseline variant are required')
    variants = {name: ROOT / 'out' / ('boomkat-hot-' + name) for name in names}
    variants['baseline'] = args.baseline.resolve()
    for binary in variants.values():
        if not binary.is_file():
            raise RuntimeError('missing binary: ' + str(binary))
    files = sorted((ROOT / 'benchmarks/es6').glob('bench_' + args.filter + '.js'))
    if args.filter == '*':
        files += [ROOT / 'benchmarks/bench_ic_proto.js', ROOT / 'benchmarks/bench_function_call.js',
                  ROOT / 'benchmarks/bench_loop.js']
    if args.paths:
        files = [(ROOT / path).resolve() for path in args.paths]
    monitor = CpuLoad()
    report = {'generated_at': datetime.now(timezone.utc).isoformat(),
              'platform': platform.platform(), 'cpu_count': monitor.cores,
              'compiler': subprocess.check_output(['c3c', '--version'], text=True).strip(),
              'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'metric': 'fresh-process wall time including startup, compilation, execution and teardown',
              'max_background_cpu_percent': args.max_background_percent,
              'load_policy': args.load_policy,
              'rounds': args.rounds, 'warmup_rounds': 1, 'rows': [], 'rejected_batches': [],
              'binaries': {name: {'bytes': binary.stat().st_size,
                                  'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
                           for name, binary in variants.items()}}
    rng = random.Random(103)
    for path in files:
        row = {'path': str(path.relative_to(ROOT)), 'samples': {name: [] for name in variants},
               'load_checks': []}
        iteration = -1
        while iteration < args.rounds:
            idle = monitor.quiet(args.load_policy, args.max_background_percent)
            order = list(variants)
            rng.shuffle(order)
            processes_before = monitor.processes()
            cpu_before = monitor.read()
            batch_start = time.perf_counter()
            competing = {}
            stopped = threading.Event()
            child_lock = threading.Lock()
            def watch():
                while not stopped.wait(0.25):
                    with child_lock:
                        for process in monitor.competitors():
                            if process['pid'] not in own_children:
                                competing[process['pid']] = process
            own_children = set()
            watcher = threading.Thread(target=watch, daemon=True)
            samples = {}
            watcher.start()
            try:
                for name in order:
                    samples[name] = execute(variants[name], path, own_children, child_lock)
            finally:
                stopped.set()
                watcher.join()
            elapsed = time.perf_counter() - batch_start
            cpu_after = monitor.read()
            processes_after = monitor.processes()
            own_cpu = sum(value['cpu_s'] for value in samples.values())
            background = max(0, monitor.busy(cpu_before, cpu_after)
                             - 100 * own_cpu / (elapsed * monitor.cores))
            external = []
            for pid, (cpu, command) in processes_after.items():
                if pid not in processes_before or pid == os.getpid():
                    continue
                percent = 100 * max(0, cpu - processes_before[pid][0]) / elapsed
                if percent > 20:
                    external.append({'pid': pid, 'command': command, 'cpu_percent_one_core': percent})
            load = {'idle_percent_busy': idle, 'background_percent_busy': background,
                    'external_processes_over_20_percent': external,
                    'competing_workloads': list(competing.values()) + monitor.competitors(), 'order': order}
            loaded = bool(load['competing_workloads'])
            if args.load_policy == 'idle':
                loaded = loaded or background > args.max_background_percent or bool(external)
            if loaded:
                report['rejected_batches'].append({'path': row['path'], 'iteration': iteration, **load})
                print(f"{path.name}: discarded batch; competing workloads={load['competing_workloads']}", flush=True)
                args.output.write_text(json.dumps(report, indent=2) + '\n')
                continue
            if len({sample['output_sha256'] for sample in samples.values()}) != 1:
                raise RuntimeError('output mismatch: ' + str(path))
            if iteration >= 0:
                row['load_checks'].append(load)
                for name, sample in samples.items():
                    row['samples'][name].append(sample)
            iteration += 1
        row['median_ms'] = {name: statistics.median(sample['wall_ms'] for sample in group)
                            for name, group in row['samples'].items()}
        baseline = row['median_ms']['baseline']
        row['speedup'] = {name: baseline / median for name, median in row['median_ms'].items()}
        report['rows'].append(row)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(path.name, {name: round(value, 3) for name, value in row['speedup'].items()}, flush=True)
    es6 = [row for row in report['rows'] if row['path'].startswith('benchmarks/es6/')]
    report['es6_geomean_speedup'] = {name: math.exp(statistics.mean(math.log(row['speedup'][name]) for row in es6))
                                        for name in variants} if es6 else {}
    report['es6_total_ms'] = {name: sum(row['median_ms'][name] for row in es6) for name in variants}
    args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
