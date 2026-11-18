#!/usr/bin/env python3
"""Export one person's raw movement and heart rate from the heild site's database.

The app uploads every recording to heild.loria.is, which keeps movement in the
compressed chunks the phone made (lib/data/acc_codec.dart: zlib over
little-endian int16 x, y, z in mG) and heart rate as one row a second.
This reads both over a stretch of time and writes them unpacked, as numpy
arrays, into research/data/ — which git ignores, because it is health data.

    research/export.py --via ',web-sql heild --prod' \\
        --from 2026-11-10 --to 2026-11-17

Needs python3 with numpy. The database is reached with --via, a command
that runs psql on it and reads SQL from stdin, as ,web-sql does, read-only,
on production; or with psql directly, given --db, HEILD_DB_URL or the usual
PG* variables. See research/README.md.

What it writes:

    acc.npz   t_ms   int64  (n,)    Unix ms of each sample
              xyz    int16  (n, 3)  x, y, z in mG
              rate_hz int   the sensor's sampling rate
    hr.npz    t_ms   int64  (n,)    Unix ms of each sample
              hr     int16  (n,)    beats a minute; 0 is no reading
              contact int8  (n,)    0 no skin contact, 1 contact, 2 unknown
"""

import argparse
import os
import shlex
import subprocess
import sys
import zlib
from datetime import datetime, timezone
from pathlib import Path

import numpy as np


def quoted(value):
    """A value as a single-quoted psql meta-command argument."""
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def psql(db, sql, variables):
    """Runs sql through psql and yields each output row as a list of fields.

    Everything goes in on stdin, the settings as meta-commands and the
    variables with \\set, so that it works the same through a wrapper that
    passes no flags on, and so that psql quotes a person's name rather than
    this script pasting it into a statement.
    """
    if db.via:
        cmd = shlex.split(db.via)
    else:
        cmd = ["psql", "--no-psqlrc"] + ([db.url] if db.url else [])
    lines = ["\\set QUIET on", "\\set ON_ERROR_STOP on",
             "\\pset format unaligned", "\\pset tuples_only on",
             "\\pset fieldsep '\\t'", "\\pset pager off"]
    lines += [f"\\set {key} {quoted(value)}" for key, value in variables.items()]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            text=True)
    proc.stdin.write("\n".join(lines) + "\n" + sql)
    proc.stdin.close()
    for line in proc.stdout:
        line = line.rstrip("\n")
        if line:
            yield line.split("\t")
    if proc.wait() != 0:
        sys.exit("export: the database command failed (see above)")


def parse_time(text):
    """A date or a date and time; without a zone it is UTC, as Iceland is."""
    t = datetime.fromisoformat(text)
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return t.isoformat()


def pick_person(db, wanted):
    people = [row[0] for row in psql(
        db, "SELECT DISTINCT person FROM heild_recordings ORDER BY 1;", {})]
    if wanted:
        if wanted not in people:
            sys.exit(f"export: nobody called {wanted!r} has uploaded; "
                     f"there is {', '.join(people) or 'nobody'}")
        return wanted
    if len(people) == 1:
        return people[0]
    if not people:
        sys.exit("export: no recordings in this database")
    sys.exit("export: several people have uploaded, pick one with --person: "
             + ", ".join(people))


def export_acc(db, variables):
    sql = """
        SELECT (extract(epoch FROM start_at) * 1000)::bigint,
               (extract(epoch FROM end_at) * 1000)::bigint,
               sample_count, rate_hz, encode(data, 'hex')
        FROM heild_acc
        WHERE person = :'person' AND start_at >= :'from' AND start_at < :'to'
        ORDER BY start_at;
    """
    times, samples, rates, skipped = [], [], set(), 0
    for start, end, count, rate, blob in psql(db, sql, variables):
        xyz = np.frombuffer(zlib.decompress(bytes.fromhex(blob)), dtype="<i2")
        count = int(count)
        if xyz.size != count * 3:
            skipped += 1   # a chunk that does not hold what it says it holds
            continue
        # A chunk carries the time of its first and last sample; the ones
        # between are evenly spaced, as the sensor's clock made them.
        times.append(np.linspace(int(start), int(end), count).round().astype(np.int64))
        samples.append(xyz.reshape(count, 3))
        rates.add(int(rate))
    if skipped:
        print(f"export: skipped {skipped} movement chunks of the wrong length",
              file=sys.stderr)
    if len(rates) > 1:
        print(f"export: movement was recorded at several rates, {sorted(rates)} Hz; "
              "rate_hz holds the highest and t_ms is right for all",
              file=sys.stderr)
    if not times:
        return np.empty(0, np.int64), np.empty((0, 3), np.int16), 0
    return np.concatenate(times), np.concatenate(samples), max(rates)


def export_hr(db, variables):
    sql = """
        SELECT (extract(epoch FROM at) * 1000)::bigint, hr, contact
        FROM heild_hr
        WHERE person = :'person' AND at >= :'from' AND at < :'to'
        ORDER BY at;
    """
    rows = np.array([[int(v) for v in row] for row in psql(db, sql, variables)],
                    dtype=np.int64).reshape(-1, 3)
    return rows[:, 0], rows[:, 1].astype(np.int16), rows[:, 2].astype(np.int8)


def describe(name, t_ms):
    if t_ms.size == 0:
        return f"{name}: nothing"
    first = datetime.fromtimestamp(t_ms[0] / 1000, timezone.utc)
    last = datetime.fromtimestamp(t_ms[-1] / 1000, timezone.utc)
    return (f"{name}: {t_ms.size:,} samples, "
            f"{first:%Y-%m-%d %H:%M} to {last:%Y-%m-%d %H:%M} UTC")


def main():
    here = Path(__file__).resolve().parent
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--via", help="a command that runs psql on the database and reads "
                   "SQL from stdin, e.g. ',web-sql heild --prod'")
    p.add_argument("--db", dest="url", default=os.environ.get("HEILD_DB_URL"),
                   help="database URL for plain psql; default $HEILD_DB_URL, "
                   "else psql's own PG* defaults")
    p.add_argument("--person", help="whose data; needed only when several people have uploaded")
    p.add_argument("--from", dest="start", default="2000-01-01",
                   help="start, a date or date and time (UTC); default everything")
    p.add_argument("--to", dest="stop", default="2100-01-01",
                   help="stop, exclusive; default everything")
    p.add_argument("--out", type=Path, default=here / "data",
                   help="directory to write into; default research/data")
    args = p.parse_args()

    person = pick_person(args, args.person)
    variables = {"person": person, "from": parse_time(args.start),
                 "to": parse_time(args.stop)}
    args.out.mkdir(parents=True, exist_ok=True)

    t_ms, xyz, rate = export_acc(args, variables)
    np.savez_compressed(args.out / "acc.npz", t_ms=t_ms, xyz=xyz, rate_hz=rate)
    print(describe("movement", t_ms) + (f", {rate} Hz" if rate else ""))

    t_ms, hr, contact = export_hr(args, variables)
    np.savez_compressed(args.out / "hr.npz", t_ms=t_ms, hr=hr, contact=contact)
    print(describe("heart rate", t_ms))
    print(f"written to {args.out}/ for {person}")


if __name__ == "__main__":
    main()
