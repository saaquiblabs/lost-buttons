# Performance

Lost Buttons should cost you nothing you can notice. These are real measurements, with the
commands to repeat them on your own Mac.

## Results

Measured on 2026-11-20 on an Apple Silicon MacBook with macOS 27.2, using a Kreo Chimera
(an affected mouse). Each run lasted 60 seconds. The button-reading code is the same in 0.1.0
and 0.2.0; 0.2.0 only adds the app bundle around it.

| | Idle (no affected mouse) | In use (moving, scrolling, ~30 Back/Forward presses) |
|---|---|---|
| CPU time over 60 s | 0.00 s | 0.50 s |
| Average CPU | 0.0% | 0.7% of one core (peak 1.4%) |
| Wakeups per second | 0 | about 1 |
| Memory (resident) | 5–7 MB | about 5 MB |
| Threads | 1 | 2 |
| Network sockets | none | none |

**Why idle is zero.** Lost Buttons doesn't poll. With no affected mouse plugged in, it sleeps until
macOS tells it a device appeared. It never opens your keyboard, trackpad or any mouse whose
buttons already work.

**Why in use is not zero.** An affected mouse sends a report every time it moves, not only when a
button is pressed, and Lost Buttons has to look at each one to catch the hidden button bits. That
look is a few bit checks per report. Half a second of CPU spread over a busy minute is less than
the Activity Monitor window you'd use to see it.

## How to measure it yourself

Find the process:

```bash
P=$(pgrep -x lost-buttons); echo $P
```

Total CPU time it has used so far (run before and after; the difference is the cost of the minute):

```bash
ps -o time=,rss= -p $P
```

One sample per second for 60 seconds. Columns: CPU %, memory, idle wakeups, energy impact, threads.
Ignore the first line: `top` can't compute CPU for its first sample.

```bash
top -l 61 -s 1 -pid $P -stats pid,cpu,mem,idlew,power,threads
```

No network, and which files it has open:

```bash
lsof -i -a -p $P      # prints nothing: no sockets
lsof -p $P | wc -l
```

For the idle run, unplug the affected mouse first. For the in-use run, start `top` and then use the
mouse normally for the full minute.
