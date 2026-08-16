<img src="doc/img/trndi-cli.png" alt="" width="120" align="right">

[![Build](https://github.com/slicke/trndi-cli/actions/workflows/build.yml/badge.svg)](https://github.com/slicke/trndi-cli/actions/workflows/build.yml) [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

# trndi-cli - Trndi in your terminal

## Shows your CGM data in the console — one-shot or as a TUI graph

### Supports the same backends as [Trndi](https://github.com/slicke/trndi): _Nightscout - Dexcom - FreeStyle Libre - Tandem Source - CareLink - xDrip_

trndi-cli is a small GUI-dependancy-free companion to the [Trndi](https://github.com/slicke/trndi) desktop app, built on the very same API and platform layer (vendored as a submodule). If Trndi is set up on your machine, trndi-cli needs **no configuration at all** — it reads the same settings.

```
$ trndi-cli
12.9 mmol/L → (±0.0)  21:55
```

With `--graph`, a Free Vision text UI shows the last hours as a bar graph — red above your high threshold, blue below the low one, green in range — refreshed every 5 minutes:

![The graph mode: eight hours of readings as coloured bars, with a shaded forecast past the divider on the right](doc/img/graph.png)

`F5` refetches, `F9` opens the settings window and `Alt-X` leaves; the key bar sits along the bottom of the terminal.

Past the divider on the right is a half-hour forecast, drawn in shade rather than solid so it never reads as measured data. It comes from Trndi's own prediction model — a robust weighted regression with a curvature term — and appears only when the fit is worth showing: a flat trend or a noisy sensor leaves it out entirely, and the header carries the horizon and the model's own confidence. `F6` toggles it, `--no-predict` starts without it. It knows nothing about insulin or carbs, so treat it as the shape of the last half hour continued, not a plan.

With `--stats` it summarises a period instead — average, spread, GMI and the time-in-range bands, taken from the same thresholds the graph colors use:

![The --stats output: average, standard deviation, GMI, extremes and a five-band time-in-range breakdown with bars](doc/img/stat.png)

## Usage

```
trndi-cli               print the current reading and exit
trndi-cli --check       ... with the range in the exit code, for scripts
trndi-cli --graph       interactive TUI graph (F5 refresh, F6 forecast, F9 settings, Alt-X exit)
trndi-cli --no-predict  ... with the forecast hidden from the start
trndi-cli --stats       summarise the last 24 h
trndi-cli --stats 6     ... or any window from 1 to 168 hours
trndi-cli --setup       settings window: backend, address, secret, unit
trndi-cli --help        options
```

Exit codes: `0` OK · `1` not configured · `2` unknown backend · `3` connection failed · `4` no recent reading. `--check` adds `5` above the high threshold and `6` below the low one — the same thresholds the graph colors use — so a cron job can alarm without parsing the output:

```bash
trndi-cli --check >/dev/null; [ $? -eq 6 ] && notify-send -u critical "Low glucose"
```

## Building

Linux:

```bash
git clone --recurse-submodules https://github.com/slicke/trndi-cli
cd trndi-cli && make        # needs fpc 3.2+ with the Free Vision units
./bin/trndi-cli
```

Windows (PowerShell, FPC from a [Lazarus](https://www.lazarus-ide.org/) install found automatically):

```powershell
.\make.ps1
```

Running on Windows needs `libcurl.dll` ([curl.se/windows](https://curl.se/windows/), rename `libcurl-x64.dll`) next to the exe or in `PATH`.

## Configuration

Configured Trndi GUI = done. Without the GUI, `--setup` opens a settings window in the same Free Vision style as the graph — backend, address, secret and unit, with a Test button that connects before you save. `F9` opens the same window from graph mode.

```
╔═[■]═════════════════════ Trndi settings ═════════════════════════╗
║   Backend                        Address / account               ║
║   NightScout                ▲    https://my.nightscout.site      ║
║   NightScout v3             ■                                    ║
║   Dexcom (USA)              ▒    Secret / password               ║
║   Dexcom (Outside USA)      ▒                                    ║
║   Dexcom New (USA)          ▒    Stored - type to replace        ║
║   Dexcom New (Outside USA)  ▒    Unit                            ║
║   Dexcom New (Japan)        ▒    (*) mmol/L                      ║
║   Tandem t:connect (USA)    ▼    ( ) mg/dL                       ║
║                                                                  ║
║  Address: the Nightscout site URL. Secret: API secret or access  ║
║   token.                                                         ║
║  Saved in /home/you/.config/Trndi.cfg                            ║
║                                                                  ║
║                                 OK      ►  Test  ◄    Cancel     ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

The stored secret is never loaded into its field: leaving it empty keeps it, and what you type is masked. It writes exactly what the GUI reads, in the place the GUI reads it, so the two stay interchangeable. The values can also be set by hand — see the [manual](MANUAL.md).

## License

GPLv3, like Trndi — see [LICENSE](LICENSE).

> ⚠️ **Medical disclaimer**: trndi-cli is NOT a medical device. Data may be delayed, inaccurate or unavailable. Never make medical decisions based on this software — verify with official devices.
