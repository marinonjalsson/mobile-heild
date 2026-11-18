# research

Work on the raw recordings outside the app: what the movement and heart-rate
data can tell, starting with whether a swim can be told from everything else.
Nothing here is built into the app.

`data/` is ignored by git. It holds health data; keep it that way.

## Getting the data

`export.py` reads one person's raw movement and heart rate from the heild site's
database — the app uploads every recording there — and writes them unpacked
into `data/`. It needs `python3` with `numpy`.

    research/export.py --via ',web-sql heild --prod' \
        --from 2026-11-10 --to 2026-11-17

The database is the production one, since that is where the uploads are; a
local heild database has none. `--via` names a command that runs psql on it
and reads SQL from stdin: `,web-sql`, from the web cli, which reads the
credentials where they live and opens production read-only. Without `--via`
the script runs `psql` itself, on `--db URL`, `$HEILD_DB_URL` or the `PG*`
variables.

The script only reads. `--person` is needed only when several people have
uploaded; `--from` and `--to` default to everything. A week is some tens of
megabytes and takes under a minute.

## What it writes

| File | Array | Type | What |
|---|---|---|---|
| `acc.npz` | `t_ms` | int64 (n,) | Unix ms of each sample |
| | `xyz` | int16 (n, 3) | x, y, z in mG; at rest \|a\| is about 1000 |
| | `rate_hz` | int | the sensor's sampling rate |
| `hr.npz` | `t_ms` | int64 (n,) | Unix ms of each sample, one a second |
| | `hr` | int16 (n,) | beats a minute; 0 is no reading |
| | `contact` | int8 (n,) | 0 no skin contact, 1 contact, 2 unknown |

```python
import numpy as np
acc = np.load('research/data/acc.npz')
t = acc['t_ms'].astype('datetime64[ms]')
magnitude = np.linalg.norm(acc['xyz'].astype(float), axis=1)
```

Movement is not continuous: there is a gap wherever the sensor was not
recording, so look at `t_ms` before assuming samples are evenly spaced.

## Looking at it

`look.py` draws a stretch as three panels over one time axis — the three
axes, the rhythm of |a| as a spectrogram, and heart rate — into `data/`.
Needs `scipy` and `matplotlib` as well.

    research/look.py --from 2026-11-17T12:45 --to 2026-11-17T13:50 \
        --mark 2026-11-17T13:15 2026-11-17T13:28

## What is known so far

The sensor is worn on the upper forearm, just below the elbow. Which way
the axes point depends on that, so anything learnt from orientation holds
only while it is worn the same way.

Labelled stretches, UTC:

| When | What |
|---|---|
| 2026-11-17 13:15–13:28 | At the pool. Freestyle, 200 m in a 50 m pool: four lengths of 50–60 s from 13:20:45, 10–20 s at the wall between them. |

In that swim |a| repeats at 0.8 Hz with a harmonic at 1.6 Hz, where walking
sits near 1.8 Hz; z averages about zero where it is about −500 mG the rest
of the day; heart rate climbs from 90 to 110–125 bpm.

A crude rule — 20 s windows with std of |a| over 200 mG and a dominant
rhythm of 0.6–1.0 Hz — finds the swim, and in the eight days to 17 Nov
three other sustained stretches not yet labelled: 10 Nov 16:59–17:12,
11 Nov 20:26–20:34, 12 Nov 21:11–21:21. One swim is too few to trust it.
