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

```
╔═[■]══════════════════════ Trndi ═══════════════════════╗
║ 11.6 mmol/L -> (-0.7)  22:20  -  updated 22:23:21      ║
║  18.6 |                  ▄▄██▄                          ║
║    15 +················██████████▄·····················║
║       |             ▄███████████████▄        ▄██▄       ║
║    10 +··▄█▄▄██▄██████████████████████▄▄···█████████···║
║   6.2 |█████████████████████████████████████████████   ║
║        14:55         16:10         17:25         18:40 ║
╚═════════════════════════════════════════════════════════╝
 Alt-X Exit  F5 Refresh
```

## Usage

```
trndi-cli             print the current reading and exit
trndi-cli --graph     interactive TUI graph (F5 refresh, Alt-X exit)
trndi-cli --help      options
```

Exit codes: `0` OK · `1` not configured · `2` unknown backend · `3` connection failed · `4` no recent reading.

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

Configured Trndi GUI = done. Without the GUI, set the few values by hand — see the [manual](MANUAL.md).

## License

GPLv3, like Trndi — see [LICENSE](LICENSE).

> ⚠️ **Medical disclaimer**: trndi-cli is NOT a medical device. Data may be delayed, inaccurate or unavailable. Never make medical decisions based on this software — verify with official devices.
