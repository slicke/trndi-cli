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

With `--graph`, a Free Vision text UI shows the last hours as a bar graph — red above your high threshold, blue below the low one, green in range, and where you have set a personal target range, yellow and cyan for the room between it and those limits — refreshed every 5 minutes:

![The graph mode: eight hours of readings as coloured bars, with a shaded forecast past the divider on the right](doc/img/graph.png)

`F5` refetches, `F9` opens the settings window and `Q` leaves (`Alt-X` and `Ctrl-X` do too); the key bar sits along the bottom of the terminal. The thresholds the colors mean sit at the right-hand end of that bar — `hi 10.0  lo 3.9`, the numbers in the same red and blue — so the graph explains its own palette. They need a terminal about 85 columns wide; below that the keys have the row to themselves. A personal in-range band, where one is set, is drawn as two green gridlines across the plot, with the bars above and below it in yellow and cyan.
The arrow keys walk a cursor across the bars — the header shows the exact value and time of the highlighted reading, `Home`/`End` jump to the oldest and newest — and stepping right past the newest reading (or `Esc`) returns the header to the live view. A refresh keeps the cursor on its reading.

`F6` (or starting with `--predict`) adds a half-hour forecast past a divider on the right, drawn in shade rather than solid so it never reads as measured data. It comes from Trndi's own prediction model — a robust weighted regression with a curvature term — and appears only when the fit is worth showing: a flat trend or a noisy sensor leaves it out entirely, and the header carries the horizon and the model's own confidence (`forecast ▒ +30 min 66%`). It is off by default and knows nothing about insulin or carbs, so treat it as the shape of the last half hour continued, not a plan.

With `--stats` it summarises a period instead — average, spread, GMI and the time-in-range bands, taken from the same thresholds the graph colors use:

![The --stats output: average, standard deviation, GMI, extremes and a five-band time-in-range breakdown with bars](doc/img/stat.png)

With `--spark` the last hours become a single line — the graph's shape and colors as a sparkline, followed by the current reading — sized to fit a status bar, MOTD or prompt:

```
$ trndi-cli --spark
▃▃▄▅▅▅▅▄▄▃▃▂▂▂▁▁▁▂▃▃▃▄▅▇██████▇▇▆▆▅  7.1 mmol/L ↘ (-0.4)  20:15
```

On a terminal the glyphs are colored by the same thresholds as the graph; piped — into a status bar module, say — they come out plain, as does setting `NO_COLOR`.

With `--agp` (or `F7` in graph mode) the last two weeks fold onto a single 24-hour axis as an [Ambulatory Glucose Profile](https://en.wikipedia.org/wiki/Ambulatory_glucose_profile) — the view diabetes clinics work from. Per half hour of the day, the median glucose across all days is drawn solid, the 25–75% band in medium shade and the 5–95% band in light shade, colored by the same thresholds as everything else: a band widening at 07:00 says breakfast is inconsistent, a median dipping at 03:00 says the nights run low. In graph mode the arrow keys walk the half-hour slots with the exact percentiles in the header, and `F5` refetches the profile.

The profile needs several days of history in one request, which the backend decides: Nightscout, xDrip and Tandem serve the full two weeks, while Dexcom Share, FreeStyle Libre and CareLink only hand out the last day or so — there the chart is honestly declined with a message, since percentiles over one day would just be that day.

With `--csv` the readings themselves come out, one per line, for a spreadsheet or a script — local time, value and delta in the display unit, the trend the backend attached, and the range band the reading falls in by the same thresholds the graph colors and `--stats` use, so time in range can be recounted elsewhere:

```
$ trndi-cli --csv 2 > today.csv
$ head -3 today.csv
time,value,unit,delta,trend,level
2026-09-09T19:48:55,7.4,mmol/L,0.2,Flat,in-range
2026-09-09T19:53:55,7.6,mmol/L,0.2,FortyFiveUp,in-range
```

`--device` lists what the backend knows about the hardware behind the readings — sensor life and state, reservoir, pump and transmitter batteries, whether delivery is suspended, and the basal rate in force (both the commanded and the programmed rate where a looping pump reports them). Only rows the backend actually reported are printed, since a missing figure is unknown rather than empty. Nightscout v3, Tandem Source and CareLink carry this; plain CGM backends (Dexcom Share, LibreLinkUp, xDrip) do not, and a Nightscout site fed only by a phone uploader has nothing to say either — both end with exit 4 and a line saying so:

```
$ trndi-cli --device
Device status — CareLink
  Sensor        3 d 6 h left (78 h)
  Sensor state  NO_ERROR_MESSAGE
  Reservoir     112 U (62%)
  Pump battery  75%
  Basal         0.85 U/h commanded, 0.90 U/h programmed  at 21:05
```

`--unit mgdl` (or `mmol`) shows one run in the other unit without touching the stored setting — for a script that feeds a mg/dL widget on a machine whose GUI shows mmol/L, say. Everything follows it: the reading line, the graph scale, the stats, the sparkline, the AGP and the CSV export.

Trndi's multi-user mode carries over: on a machine following more than one person, `--profile` names which account a run reads — `-p Anna --graph` in one terminal, `-p Bertil --check` in a cron job — and a bare `--profile` lists the accounts. They are the same accounts the GUI manages, matched case-insensitively, and the graph names its account in the frame title so two windows side by side stay tellable apart. On a machine without the GUI, `--setup --profile Anna` creates the account on save.

## Usage

```
trndi-cli               print the current reading and exit
trndi-cli --check       ... with the range in the exit code, for scripts
trndi-cli --graph       interactive TUI graph (arrows inspect readings, F5 refresh,
                        F6 forecast, F7 AGP, F9 settings, Q exits)
trndi-cli --predict     ... with the forecast drawn from the start
trndi-cli --stats       summarise the last 24 h
trndi-cli --stats 6     ... or any window from 1 to 168 hours
trndi-cli --spark       the last 3 h as a one-line sparkline
trndi-cli --spark 8     ... or any window from 1 to 24 hours
trndi-cli --agp         time-of-day percentile profile of the last 14 days
trndi-cli --agp 7       ... or any window from 3 to 28 days
trndi-cli --csv         the last 24 h of readings as CSV, oldest first
trndi-cli --csv 72      ... or any window from 1 to 168 hours
trndi-cli --device      sensor life, reservoir, batteries and basal, where reported
trndi-cli --unit mgdl   any mode above in mg/dL (or mmol) for this run only
trndi-cli --profile     list the accounts of Trndi's multi-user mode
trndi-cli -p Anna ...   any mode above against that account's settings
trndi-cli --setup       settings window: backend, address, secret, unit, limits
trndi-cli --help        options
trndi-cli --version     version, the vendored Trndi build and the compiler
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

Haiku (r1beta5 or newer):

```bash
pkgman install fpc devel:libcurl
make        # install goes to /boot/home/config/non-packaged
```

Windows (PowerShell, FPC from a [Lazarus](https://www.lazarus-ide.org/) install found automatically):

```powershell
.\make.ps1
```

Running on Windows needs `libcurl.dll` next to the exe or in `PATH`: download the package from [curl.se/windows](https://curl.se/windows/) and rename its `libcurl-x64.dll` to `libcurl.dll`.

### Windows on ARM64

A native ARM64 build ships under [Releases](https://github.com/slicke/trndi-cli/releases)
as `trndi-cli-windows-arm64.exe`. To build it yourself, cross-compile from
Linux: it needs FPC **trunk** (3.2.2 cannot target `aarch64-win64`) and **llvm-mingw**
rather than binutils, because FPC assembles this target with clang and not GAS.
The container below carries both, so nothing is installed on the host:

```bash
podman run --rm -v "$PWD:/src:Z" -w /src docker.io/mstorsjo/llvm-mingw:latest sh -c '
  set -e
  apt-get update -qq && apt-get install -y -qq fpc make git
  # gitlab.freepascal.org is unreachable on some networks; this is the project mirror.
  git clone --quiet --depth 1 --branch main https://github.com/fpc/FPCSource.git /tmp/fpcsrc
  cd /tmp/fpcsrc
  # Without BINUTILSPREFIX, FPC looks for an assembler called aarch64-win64-clang
  # and the RTL build dies on its very first unit.
  make crossall crossinstall CPU_TARGET=aarch64 OS_TARGET=win64 \
       BINUTILSPREFIX=aarch64-w64-mingw32- INSTALL_PREFIX=/tmp/fpctrunk
  cd /src && V=$(ls /tmp/fpctrunk/lib/fpc)
  # -Fu<dir>/* is what a generated fpc.cfg would supply: the packages live in
  # subdirectories, so without it DateUtils (rtl-objpas) is not found.
  make FPC=/tmp/fpctrunk/lib/fpc/$V/ppcrossa64 \
       FPCEXTRA="-Twin64 -Paarch64 -XPaarch64-w64-mingw32- \
                 -Fu/tmp/fpctrunk/lib/fpc/$V/units/aarch64-win64/* -otrndi-cli.exe"
'
```

Building the cross compiler is the slow part — it compiles the RTL and the full
package set for the target — so cache `/tmp/fpctrunk` if you do this more than
once.

At runtime the ARM64 build needs an ARM64 `libcurl.dll`, not the x64 one: take
`win64a-mingw` from [curl.se/windows](https://curl.se/windows/) and rename its
`libcurl-arm64.dll` to `libcurl.dll`. The exe imports it at load time, so without it the program
does not start at all rather than failing when it first makes a request.

Every green build on `main` publishes binaries for Linux (x86-64, ARM64 and i686), FreeBSD, Haiku and Windows (x64 and ARM64) under [Releases](https://github.com/slicke/trndi-cli/releases).

`sudo make install` puts the binary in `/usr/local/bin` together with tab completion for bash, zsh and fish (`PREFIX`/`DESTDIR` respected for packagers). The completions also work on their own: `make install-completions`, or source `completions/trndi-cli.bash` from your `.bashrc`.

## Configuration

Configured Trndi GUI = done. Without the GUI, `--setup` opens a settings window in the same Free Vision style as the graph — a `[1] Connection` page with the backend, address and secret, a `[2] Display` page with the unit, the limits and the in-range band (`Alt-1` and `Alt-2` switch), and a Test button that connects before you save. `F9` opens the same window from graph mode.

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
