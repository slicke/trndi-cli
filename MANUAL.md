# trndi-cli Manual - Configuration

trndi-cli reads the settings the [Trndi](https://github.com/slicke/trndi) GUI saves, so on a machine where Trndi is set up there is nothing to configure. This page is for setting up trndi-cli **without** the GUI.

## Table of Contents
- [What trndi-cli reads](#what-trndi-cli-reads)
- [Linux](#linux)
- [Windows](#windows)
- [Backends](#backends)
- [Stats thresholds](#stats-thresholds)
- [Troubleshooting](#troubleshooting)

## What trndi-cli reads

Only four settings are used:

| Key             | Meaning                                             | Values                       |
|-----------------|-----------------------------------------------------|------------------------------|
| `remote.type`   | Which backend to talk to                            | a code from [Backends](#backends) |
| `remote.target` | Backend address                                     | e.g. `https://my.nightscout.site` |
| `remote.creds`  | Credential (secret, token or password — see below)  |                              |
| `unit`          | Display unit                                        | `mmol` (default) or `mgdl`   |

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
reports — nothing about them is configured in trndi-cli. On Nightscout they are
the site's own settings: `bgTargetBottom`/`bgTargetTop` bound the in-range band,
`bgLow`/`bgHigh` the very low/very high ones. Backends that report only a hard
high and low (xDrip, for instance) get a three-band breakdown instead of five.

Percentages are shares of the readings in the period, and each band's duration
is its share counted at the backend's reporting interval. The `coverage` figure
compares the readings actually fetched with what an unbroken stream at that
interval would have given, so gaps — sensor changes, a backend that caps how far
back it will serve — show up there and in the "readings since" timestamp.

## Troubleshooting

trndi-cli exits with a distinct code and a message on stderr:

| Exit | Meaning | Fix |
|------|---------|-----|
| `1` | No backend configured | Set `remote.type` as described above |
| `2` | Unknown backend | Check `remote.type` against the table |
| `3` | Connection failed | Message includes the backend's error — check address/credentials |
| `4` | No recent reading | Backend reachable but silent > 24 h (with `--stats`: nothing in the requested window) — check the uploader |
| `64` | Bad command line | Unknown option, or a `--stats` window outside 1–168 hours |

**Windows: "libcurl.dll was not found"** — this pops up before trndi-cli even runs; see the note under [Windows](#windows).

A reading older than ~10 minutes is still printed, marked `[stale, N min old]`.

> ⚠️ **Medical disclaimer**: trndi-cli is NOT a medical device. Data may be delayed, inaccurate or unavailable. Never make medical decisions based on this software — verify with official devices.
