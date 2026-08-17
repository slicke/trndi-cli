# trndi-cli Manual - Configuration

trndi-cli reads the settings the [Trndi](https://github.com/slicke/trndi) GUI saves, so on a machine where Trndi is set up there is nothing to configure. This page is for setting up trndi-cli **without** the GUI.

## Table of Contents
- [What trndi-cli reads](#what-trndi-cli-reads)
- [The settings window](#the-settings-window)
- [Linux](#linux)
- [Windows](#windows)
- [Backends](#backends)
- [Stats thresholds](#stats-thresholds)
- [Troubleshooting](#troubleshooting)

## What trndi-cli reads

Four settings select and connect the backend:

| Key             | Meaning                                             | Values                       |
|-----------------|-----------------------------------------------------|------------------------------|
| `remote.type`   | Which backend to talk to                            | a code from [Backends](#backends) |
| `remote.target` | Backend address                                     | e.g. `https://my.nightscout.site` |
| `remote.creds`  | Credential (secret, token or password — see below)  |                              |
| `unit`          | Display unit                                        | `mmol` (default) or `mgdl`   |

Six more are optional threshold overrides — mg/dL integers, applied on top of
whatever the backend reports, in the same order the GUI applies them (see
[Stats thresholds](#stats-thresholds)):

| Key                                   | Meaning                                                     |
|---------------------------------------|-------------------------------------------------------------|
| `override.hi` / `override.lo`         | The hard high/low limits — graph red/blue, `--check` exit codes |
| `override.rangehi` / `override.rangelo` | The personal in-range band                                |
| `wizard.hi` / `wizard.lo`             | The GUI wizard's limits, used only when the backend reports none |

The rest of this page describes those values and where they live. Setting
them from trndi-cli itself is one command — see below.

## The settings window

`trndi-cli --setup` opens a Free Vision window over the settings: a backend
picker, the address and secret fields, the unit and the two hard limits.
`F9` opens the same window
from graph mode, where saving reconnects and refetches; a backend that fails to
connect is reported and the running one kept. On a machine with nothing
configured, a plain `trndi-cli` offers the window rather than only naming the
file to write.

It writes the same keys in the same place the GUI uses, so a machine can be set
up from either side. Three things worth knowing:

- **The secret is never shown.** Leave the field empty to keep the stored one;
  what you type is masked. A CareLink credential is a JSON token blob only the
  GUI can capture, and it is longer than the field allows — configure CareLink
  in the GUI, or by hand as below.
- **The address means something different per backend**, which the line under
  the fields spells out for whichever one is selected. The same rules the GUI
  applies are checked when you save.
- **Test** connects with the values on screen without saving them. It costs one
  request, and the window sits still until the backend answers.
- **The limit fields are typed in the display unit** but stored as the mg/dL
  `override.hi`/`override.lo` keys the GUI applies too, so both apps color by
  the same thresholds. Blank leaves the backend's own limits in charge.

The window needs a terminal of at least 68x22, and a terminal at all: with
input or output redirected, `--setup` refuses (exit 64) and an unconfigured run
falls back to the message and exit 1.

## Linux

Settings live in `~/.config/Trndi.cfg`, an INI file with a single `[trndi]` section. A minimal Nightscout setup:

```ini
[trndi]
remote.type=API_NS
remote.target=https://my.nightscout.site
remote.creds=my-api-secret
unit=mmol
```

Save the file and run `trndi-cli` — no restart or extra steps needed.

## Windows

The Windows GUI keeps settings in the registry rather than a file, and trndi-cli reads the same place: string values under `HKCU\SOFTWARE\Trndi`. From PowerShell or cmd:

```powershell
reg add HKCU\SOFTWARE\Trndi /v remote.type   /t REG_SZ /d API_NS
reg add HKCU\SOFTWARE\Trndi /v remote.target /t REG_SZ /d https://my.nightscout.site
reg add HKCU\SOFTWARE\Trndi /v remote.creds  /t REG_SZ /d my-api-secret
reg add HKCU\SOFTWARE\Trndi /v unit          /t REG_SZ /d mmol
```

trndi-cli's HTTP transport on Windows is libcurl, so `libcurl.dll` must be in `PATH` or next to `trndi-cli.exe`. Download the official [curl for Windows](https://curl.se/windows/) package and rename its `bin\libcurl-x64.dll` to `libcurl.dll`. Without it the exe does not start at all (Windows reports a missing DLL before any trndi-cli code runs).

## Backends

`remote.type` takes one of Trndi's stable backend codes. What `remote.target` and `remote.creds` mean depends on the backend:

| Code              | Backend                  | `remote.target`            | `remote.creds`      |
|-------------------|--------------------------|----------------------------|---------------------|
| `API_NS`          | Nightscout               | site URL                   | API secret or token |
| `API_NS3`         | Nightscout (v3 API)      | site URL                   | access token        |
| `API_DEX_USA`     | Dexcom Share (USA)       | Dexcom account name        | password            |
| `API_DEX_EU`      | Dexcom Share (Outside US)| Dexcom account name        | password            |
| `API_DEX_NEW_USA` | Dexcom (new API, USA)    | Dexcom account name        | password            |
| `API_DEX_NEW_EU`  | Dexcom (new API, Outside US) | Dexcom account name    | password            |
| `API_DEX_NEW_JP`  | Dexcom (new API, Japan)  | Dexcom account name        | password            |
| `API_TANDEM_USA`  | Tandem Source (USA)      | Tandem account email       | password            |
| `API_TANDEM_EU`   | Tandem Source (Outside US) | Tandem account email     | password            |
| `API_CARELINK_US` | CareLink (USA)           | CareLink username          | password            |
| `API_CARELINK_EU` | CareLink (Outside US)    | CareLink username          | password            |
| `API_LLU`         | LibreLinkUp              | LibreLinkUp email          | password            |
| `API_XDRIP`       | xDrip (web service)      | xDrip URL (port 17580)     | API secret          |

The GUI's display names (e.g. `NightScout`) are also accepted, but the codes above are the stable form.

## Stats thresholds

`--stats` splits the period into bands using the thresholds the backend itself
reports. On Nightscout they are the site's own settings:
`bgTargetBottom`/`bgTargetTop` bound the in-range band, `bgLow`/`bgHigh` the
very low/very high ones. Backends that report only a hard high and low (xDrip,
for instance) get a three-band breakdown instead of five.

The override keys above change that, exactly as they do in the GUI: `wizard.*`
back-fill backends that report no limits, then any `override.*` value replaces
the backend's — whatever the GUI's override checkbox says, since the GUI
applies them the same way. The result feeds every threshold consumer alike:
the graph and sparkline colors, the stats bands and the `--check` exit codes.
A personal bound that meets the hard limit folds its band away rather than
print an empty `10.0-10.0` row.

Percentages are shares of the readings in the period, and each band's duration
is its share counted at the backend's reporting interval. The `coverage` figure
compares the readings actually fetched with what an unbroken stream at that
interval would have given, so gaps — sensor changes, a backend that caps how far
back it will serve — show up there and in the "readings since" timestamp.

## Troubleshooting

trndi-cli exits with a distinct code and a message on stderr:

| Exit | Meaning | Fix |
|------|---------|-----|
| `1` | No backend configured | Run `trndi-cli --setup`, or set `remote.type` as described above |
| `2` | Unknown backend | Check `remote.type` against the table |
| `3` | Connection failed | Message includes the backend's error — check address/credentials |
| `4` | No recent reading | Backend reachable but silent > 24 h (with `--stats`: nothing in the requested window; with `--check`: also a stale fallback, so scripts never alarm on old data) — check the uploader |
| `5` | Above the high threshold | Only from `--check` — an answer, not an error |
| `6` | Below the low threshold | Only from `--check` — an answer, not an error |
| `64` | Bad command line | Unknown option, a `--stats` or `--spark` window outside its range, or `--setup` without a terminal |

`--check` prints the same line as a plain run; the exit code uses the same
thresholds the graph colors and `--stats` bands come from — the backend's own,
as adjusted by any overrides. A
personal target range narrower than the hard limits does not trip it — like the
graph, only red and blue count.

**Windows: "libcurl.dll was not found"** — this pops up before trndi-cli even runs; see the note under [Windows](#windows).

A reading older than ~10 minutes is still printed, marked `[stale, N min old]`.

**No forecast in graph mode** — that is usually the intended answer rather than a
fault. The forecast is left out when the trend is flat (a straight line ahead
carries no information), when the model's own confidence in the fit falls below
50%, when the window is too narrow to spare a quarter of the plot, and of course
under `--no-predict`. `F6` toggles it. Note that producing one costs a second
request per refresh, which is worth knowing on backends that rate-limit
aggressively — LibreLinkUp in particular.

> ⚠️ **Medical disclaimer**: trndi-cli is NOT a medical device. Data may be delayed, inaccurate or unavailable. Never make medical decisions based on this software — verify with official devices.
