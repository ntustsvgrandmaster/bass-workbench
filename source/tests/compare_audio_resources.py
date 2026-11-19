"""Compare two locally built Transport probes, with no private projects or UI automation."""
import argparse
import json
import os
from pathlib import Path
import platform
import selectors
import statistics
import subprocess
import time


def run(binary, label, trial, args):
    stem = args.output / f"{trial}-{label}"
    environment = dict(os.environ, BASS_DATA_ROOT=str(stem.with_suffix(".data")))
    records = []
    with stem.with_suffix(".stderr.txt").open("wb") as errors, stem.with_suffix(".jsonl").open("wb") as raw:
        process = subprocess.Popen([str(binary), "--measure", "--seconds", str(args.seconds),
                                    "--warmup", str(args.warmup)], env=environment,
                                   stdout=subprocess.PIPE, stderr=errors)
        selection = selectors.DefaultSelector()
        selection.register(process.stdout, selectors.EVENT_READ)
        started = time.monotonic()
        pending = b""
        try:
            while selection.get_map():
                ready = selection.select(timeout=30)
                if time.monotonic() - started > args.seconds + args.warmup + 90:
                    raise RuntimeError(f"Timed out: {label} trial {trial}")
                if not ready:
                    print(f"trial {trial} {label}: sampling ({time.monotonic()-started:.0f}s elapsed)", flush=True)
                for key, _ in ready:
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selection.unregister(key.fileobj)
                        continue
                    raw.write(chunk)
                    raw.flush()
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        record = json.loads(line)
                        records.append(record)
                        print(f"trial {trial} {label}: {record['phase']}", flush=True)
            if process.wait(timeout=5) != 0:
                raise RuntimeError(f"Probe failed: {label} trial {trial}; see {stem}.stderr.txt")
        finally:
            selection.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    result = next(r for r in records if r["phase"] == "result")
    created = next(r for r in records if r["phase"] == "created")
    playing = next(r for r in records if r["phase"] == "playing")
    stopped = next(r for r in records if r["phase"] == "stopped-5s")
    return dict(label=label, trial=trial, created=created, playing=playing,
                stopped=stopped, result=result)


def spread(values):
    return dict(median=statistics.median(values), minimum=min(values), maximum=max(values))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=120)
    parser.add_argument("--warmup", type=float, default=30)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.seconds <= 0 or args.warmup < 0 or args.repeats < 1:
        parser.error("Invalid timing or repeat count")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    args.before, args.after = args.before.resolve(), args.after.resolve()
    records = []
    for trial in range(1, args.repeats + 1):
        order = ["before", "after"] if trial % 2 else ["after", "before"]
        for label in order:
            records.append(run(getattr(args, label), label, trial, args))
            (args.output / "records.json").write_text(json.dumps(records, indent=2))
    summary = dict(platform=platform.platform(), warmup=args.warmup, seconds=args.seconds,
                   repeats=args.repeats, order=[r["label"] for r in records], groups={})
    for label in ("before", "after"):
        subset = [r for r in records if r["label"] == label]
        summary["groups"][label] = dict(
            cpuPercent=spread([r["result"]["cpuPercent"] for r in subset]),
            cpuSeconds=spread([r["result"]["cpuSeconds"] for r in subset]),
            timerCallbacks=spread([r["result"]["timerCallbacks"] for r in subset]),
            interruptWakeups=spread([r["result"]["interruptWakeups"] for r in subset])
                if all(r["result"]["interruptWakeups"] is not None for r in subset) else None,
            footprintEnd=spread([r["result"]["footprintEnd"] for r in subset])
                if all(r["result"]["footprintEnd"] is not None for r in subset) else None,
            startupSeconds=spread([r["playing"]["startupSeconds"] for r in subset]),
            briefPlayingCPU=spread([r["playing"]["cpuPercent"] for r in subset]),
            engineRunning=[r["result"]["resources"]["engineRunning"] for r in subset],
            positionUpdatesActive=[r["result"]["resources"]["positionUpdatesActive"] for r in subset],
            assertionsAfter5s=[len(r["stopped"]["assertions"]) for r in subset],
        )
    summary["matchingFixture"] = len({r["created"]["audioHash"] for r in records}) == 1
    summary["matchingDevice"] = len({r["created"]["device"] for r in records}) == 1 and all(
        r["result"]["deviceStable"] for r in records)
    summary["nominalThermal"] = all(r["result"]["thermalStart"] == 0
                                    and r["result"]["thermalEnd"] == 0 for r in records)
    summary["matchingLowPowerMode"] = len({r["created"]["lowPowerMode"] for r in records}) == 1
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
