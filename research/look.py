#!/usr/bin/env python3
"""Draw a stretch of the exported data: movement, its rhythm, and heart rate.

    research/look.py --from 2026-11-17T12:45 --to 2026-11-17T13:50 \\
        --mark 2026-11-17T13:15 2026-11-17T13:28

Reads research/data/acc.npz and hr.npz (see export.py) and writes a PNG
beside them. Times are UTC. Three panels over the same time axis:

    x, y, z      the three axes, averaged over a second: which way the arm
                 is turned, and how that changes
    rhythm       a spectrogram of |a|: how fast the movement repeats. Walking
                 is a band near 1.8 Hz, the steps; a swimming stroke is
                 slower
    heart rate   one sample a second, zeros left out

--mark shades a stretch, for the times something is known to have happened.

Needs numpy, scipy and matplotlib.
"""

import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import numpy as np
from scipy.signal import spectrogram


def ms(text):
    return int(np.datetime64(text, "ms").astype(np.int64))


def main():
    data = Path(__file__).resolve().parent / "data"
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--from", dest="start", required=True)
    p.add_argument("--to", dest="stop", required=True)
    p.add_argument("--mark", nargs=2, metavar=("START", "STOP"))
    p.add_argument("--out", type=Path)
    args = p.parse_args()
    lo, hi = ms(args.start), ms(args.stop)

    acc = np.load(data / "acc.npz")
    hr = np.load(data / "hr.npz")
    rate = int(acc["rate_hz"])
    i0, i1 = np.searchsorted(acc["t_ms"], [lo, hi])
    t = acc["t_ms"][i0:i1]
    xyz = acc["xyz"][i0:i1].astype(float)
    if t.size < rate * 60:
        raise SystemExit("look: under a minute of movement in that stretch")
    when = t.astype("datetime64[ms]")

    fig, (ax_xyz, ax_spec, ax_hr) = plt.subplots(
        3, 1, figsize=(12, 8), sharex=True, constrained_layout=True)

    # One point a second is plenty to see the arm turn, and keeps a gap in
    # the recording from being drawn across.
    n = t.size // rate * rate
    sec_t = when[:n:rate]
    sec = xyz[:n].reshape(-1, rate, 3).mean(axis=1)
    for k, name in enumerate("xyz"):
        ax_xyz.plot(sec_t, sec[:, k], lw=0.8, label=name)
    ax_xyz.set_ylabel("mG, 1 s mean")
    ax_xyz.legend(loc="upper right", ncols=3, frameon=False)

    mag = np.linalg.norm(xyz, axis=1)
    f, st, power = spectrogram(mag - mag.mean(), fs=rate, nperseg=rate * 16,
                               noverlap=rate * 12)
    keep = (f >= 0.2) & (f <= 4)
    # Spectrogram time is in samples since the start, not clock time: map it
    # through the samples' own timestamps so a gap does not shift what follows.
    spec_t = when[np.clip((st * rate).astype(int), 0, t.size - 1)]
    ax_spec.pcolormesh(spec_t, f[keep], 10 * np.log10(power[keep] + 1e-9),
                       shading="auto", cmap="magma", vmin=20, vmax=55)
    ax_spec.set_ylabel("rhythm of |a|, Hz")

    k0, k1 = np.searchsorted(hr["t_ms"], [lo, hi])
    beats = hr["hr"][k0:k1].astype(float)
    beats[beats == 0] = np.nan
    ax_hr.plot(hr["t_ms"][k0:k1].astype("datetime64[ms]"), beats, lw=1, color="C3")
    ax_hr.set_ylabel("heart rate, bpm")
    ax_hr.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))

    if args.mark:
        a, b = (np.datetime64(x, "ms") for x in args.mark)
        for ax in (ax_xyz, ax_hr):
            ax.axvspan(a, b, color="C0", alpha=0.12, lw=0)
        for x in (a, b):
            ax_spec.axvline(x, color="white", lw=1, ls="--")
    fig.suptitle(f"{args.start} to {args.stop} UTC")

    out = args.out or data / f"look-{args.start.replace(':', '')}.png"
    fig.savefig(out, dpi=110)
    print(out)


if __name__ == "__main__":
    main()
