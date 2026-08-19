(*
 * trndi-cli
 * Medical and Non-Medical Usage Alert
 *
 * Copyright (c) Björn Lindh
 * GitHub: https://github.com/slicke/trndi-cli
 *
 * This program is distributed under the terms of the GNU General Public License,
 * Version 3, as published by the Free Software Foundation. You may redistribute
 * and/or modify the software under the terms of this license.
 *
 * A copy of the GNU General Public License should have been provided with this
 * program. If not, see <http://www.gnu.org/licenses/gpl.html>.
 *
 * ================================== IMPORTANT ==================================
 * MEDICAL DISCLAIMER:
 * - This software is NOT a medical device and must NOT replace official continuous
 *   glucose monitoring (CGM) systems or any healthcare decision-making process.
 * - The data provided may be delayed, inaccurate, or unavailable.
 * - DO NOT make medical decisions based on this software.
 * - VERIFY all data using official devices and consult a healthcare professional for
 *   medical concerns or emergencies.
 *
 * LIABILITY LIMITATION:
 * - The software is provided "AS IS" and without any warranty—expressed or implied.
 * - Users assume all risks associated with its use. The developers disclaim all
 *   liability for any damage, injury, or harm, direct or incidental, arising
 *   from its use.
 *
 * INSTRUCTIONS TO DEVELOPERS & USERS:
 * - Any modifications to this file must include a prominent notice outlining what was
 *   changed and the date of modification (as per GNU GPL Section 5).
 * - Distribution of a modified version must include this header and comply with the
 *   license terms.
 *
 * BY USING THIS SOFTWARE, YOU AGREE TO THE TERMS AND DISCLAIMERS STATED HERE.
 *)

{**
  Console front end for Trndi. By default prints the current BG reading with
  trend arrow and delta, then exits. With --graph it opens a Free Vision TUI
  showing the reading and a block-character graph, refreshing every 5 minutes
  (F5 forces a refresh). With --stats it summarises a period of history:
  average, variability, GMI and the time-in-range distribution. With --spark
  the recent history becomes a one-line sparkline, colored by the same
  thresholds as the graph. With --agp (or F7 in graph mode) the last two
  weeks fold onto one 24-hour axis as a median line with percentile bands —
  an Ambulatory Glucose Profile. With --check the exit code carries where
  the reading sits: 0 in range, 5 high, 6 low.

  Settings are read from the GUI's config (~/.config/Trndi.cfg on Linux), so
  a machine with a configured Trndi needs no setup. With --profile every mode
  runs against one of the GUI's multi-user accounts instead of the default
  one; a bare --profile lists them.
}
program trndicli;

{$mode objfpc}{$H+}

uses
{$IF DEFINED(UNIX) OR DEFINED(HAIKU)}
cthreads, // MUST be first: trndi.native.async starts a worker thread; without
          // a thread driver the RTL aborts with RE 232 (uncatchable).
          // Haiku needs it too but does not define UNIX, hence the OR — the
          // same guard Trndi.lpr uses.
{$ENDIF}
SysUtils, DateUtils,
{$IFDEF WINDOWS}
Windows,
{$ELSE}
termio, // IsATTY, for deciding whether the sparkline gets colors
{$ENDIF}
App, Objects, Drivers, Views, Menus, FVConsts, Video,
trndi.native, trndi.native.console,
trndi.api, trndi.api.registry, trndi.types, trndi.funcs.core,
trndicli.settings;

const
  cmRefresh = 1000;                   // FV user command for F5/refresh
  cmPredict = 1001;                   // ... and for F6/forecast toggle
  cmSetup = 1002;                     // ... and for F9/settings window
  cmAGP = 1003;                       // ... and for F7/AGP view toggle
  POLL_INTERVAL_MS = 5 * 60 * 1000;   // graph mode refetch cadence
  // Fetch more than any reasonable terminal is wide (one column per
  // reading); Draw shows the newest readings that fit the window.
  GRAPH_SPAN_MIN = 480;               // minutes of history in the graph
  GRAPH_MAX_READINGS = 480;           // covers 8 h even for 1-min uploaders
  // Dexcom Share refuses anything above its own window instead of serving
  // what it can: 24 h, and 288 readings at the 5-minute cadence it assumes.
  // FetchReadingsSafe retries inside these when a backend throws.
  SHARE_MAX_MINUTES = MinsPerDay;
  SHARE_MAX_READINGS = 288;
  // Half an hour ahead, matching the GUI's overlay. The model knows nothing
  // about insulin or carbs, so a longer horizon would only look precise.
  PREDICT_COUNT = 6;
  PREDICT_MIN_CONF = 0.5;             // below this the fit is not worth drawing
  // The AGP folds days onto one 24-hour axis, so its window is counted in
  // days: 14 is the clinical standard, 28 the most any backend serves in one
  // request (Tandem caps at about four weeks). Below 3 distinct days the
  // percentiles would just echo single readings, so the chart refuses.
  AGP_DEFAULT_DAYS = 14;
  AGP_MIN_DAYS = 3;     // = AGP_MIN_DATA_DAYS: a smaller request cannot succeed
  AGP_MAX_DAYS = 28;
  AGP_MIN_DATA_DAYS = 3;
  // Fixed half-hour time-of-day buckets: 14 days give ~84 samples per bucket,
  // enough for an honest p5/p95, and the cache is independent of the terminal
  // width — columns map onto buckets at draw time.
  AGP_BUCKETS = 48;
  AGP_BUCKET_MINS = 30;

  // TUI attributes and glyphs, shared by the bar graph and the AGP view.
  // Raw byte attrs on a black canvas — the terminal driver only emits the 8
  // base colors. Glyphs are CP437: the FV draw buffer is byte-oriented and
  // the Video unit maps them to Unicode.
  attrText = $0F;     // white on black
  attrLabel = $07;    // gray on black
  chFull = #219;      // CP437 full block
  chHalf = #220;      // CP437 lower half block
  // The forecast reuses the bar geometry but a lighter texture, so it reads as
  // the same measurement drawn weaker rather than as a different thing. Color
  // stays free to mean level, as it does for the history. The AGP view leans
  // on the same scale: solid median, shaded percentile bands.
  chPredFull = #177;  // CP437 medium shade
  chPredHalf = #176;  // CP437 light shade, as the half step
  chDivider = #179;   // CP437 vertical line: the "now" boundary
  MARGIN = 8;         // room for scale labels: "  12.3 |"

var
  gApi: TrndiAPI = nil;
  gUnit: BGUnit = mmol;
  gCurrent: BGReading;
  gHaveCurrent: boolean = false;
  gStale: boolean = false;
  gReadings: BGResults = nil;
  gLastFetch: QWord = 0;
  gStatus: string = '';
  // Why the last FetchReadingsSafe came back empty ('' = it did not fail).
  gFetchErr: string = '';
  // ... and the same for the current-reading fetch.
  gCurrentErr: string = '';
  gPredictions: BGResults = nil;
  // The forecast is opt-in (--predict or F6): model output next to measured
  // data confuses more than it helps someone who did not ask for it.
  gPredictEnabled: boolean = false;
  gPredictOK: boolean = false;
  gPredictConf: double = 0;
  gPredictStable: boolean = false;
  // Graph-mode cursor: index into gReadings while the arrow keys browse the
  // history, -1 when the header shows the live reading. gFirstVis is the
  // oldest index the last Draw fit on screen, so the cursor stops at the
  // window's left edge instead of walking onto readings that are not drawn.
  gSel: integer = -1;
  gFirstVis: integer = 0;

type
  // One time-of-day slot of the AGP: how many readings landed there across
  // all fetched days, and the percentiles over them. All values in mg/dL.
  TAgpBucket = record
    n: integer;
    p5, p25, p50, p75, p95: double;
  end;

var
  // The AGP cache, shared by the F7 view and --agp. Fetched lazily (a 14-day
  // query is far too heavy for the 5-minute poll) and kept until F5, F9 or
  // exit. gAgpErr carries the reason there is no profile ('' = none yet).
  gAgpMode: boolean = false;          // TUI: F7 swapped the graph for the AGP
  gAgp: array[0..AGP_BUCKETS - 1] of TAgpBucket;
  gAgpValid: boolean = false;
  gAgpErr: string = '';
  gAgpDaysReq: integer = AGP_DEFAULT_DAYS;
  gAgpDaysGot: integer = 0;           // distinct calendar days with data
  gAgpCount: integer = 0;             // readings that landed in buckets
  gAgpOldest: TDateTime = 0;
  gAgpSel: integer = -1;              // bucket cursor, -1 = summary header

function TrndiAppName: string;
begin
  Result := 'Trndi';
end;

{------------------------------------------------------------------------------
  Data access
 ------------------------------------------------------------------------------}

// Build and connect a backend from a set of settings. Reports rather than
// halts, since graph mode swaps backends with the TUI on the screen — there
// stderr is invisible and halting would take the window with it.
function OpenBackend(const s: TCliSettings; out api: TrndiAPI;
out err: string): boolean;
begin
  Result := false;
  err := '';
  api := CreateBackend(s.backend, s.target, s.creds);
  if api = nil then
  begin
    err := Format('Unknown backend "%s" in settings.', [s.backend]);
    exit;
  end;
  if not api.connect then
  begin
    err := api.errormsg;
    FreeAndNil(api);
    exit;
  end;
  // User thresholds on top of what the backend reported, exactly as the GUI
  // lays them on (umain_init.inc): the wizard pair only where the backend
  // supplied no high limit of its own (401 is initCGMCore's untouched
  // default), the override pair always. Same keys, same order, so the graph,
  // spark, stats bands and --check agree with the desktop app.
  if api.cgmHi = 401 then
  begin
    if s.wizHi > 0 then
      api.cgmHi := s.wizHi;
    if s.wizLo > 0 then
      api.cgmLo := s.wizLo;
  end;
  if s.ovrLo > 0 then
    api.cgmLo := s.ovrLo;
  if s.ovrHi > 0 then
    api.cgmHi := s.ovrHi;
  if s.ovrRangeLo > 0 then
    api.cgmRangeLo := s.ovrRangeLo;
  if s.ovrRangeHi > 0 then
    api.cgmRangeHi := s.ovrRangeHi;
  Result := true;
end;

// An unconfigured machine is the one case where the settings window is worth
// pushing: the alternative is telling the user which file to write by hand.
// Only on a terminal, though — a piped or scripted run keeps the old message
// and the old exit code.
function OfferSetup: boolean;
var
  ans: string;
begin
  Result := false;
  if not ConsoleIsInteractive then
  begin
    writeln(stderr, 'No backend configured. Run trndi-cli --setup, or the ' +
      'Trndi GUI setup (no remote.type in ', SettingsLocation, ').');
    exit;
  end;
  writeln(stderr, 'No backend configured (no remote.type in ',
    SettingsLocation, ').');
  write(stderr, 'Open the settings window now? [Y/n] ');
  readln(ans);
  ans := LowerCase(Trim(ans));
  if (ans = '') or (ans = 'y') or (ans = 'yes') then
    Result := RunSetup;
end;

// Connect the backend stored in the GUI settings; halts with a message and
// a distinct exit code when configuration or connection fails.
procedure ConnectBackend;
var
  s: TCliSettings;
  err: string;
begin
  s := LoadSettings;
  if s.backend = '' then
  begin
    if not OfferSetup then
      halt(1);
    s := LoadSettings;
    if s.backend = '' then
      halt(1);
  end;

  if s.mmol then
    gUnit := mmol
  else
    gUnit := mgdl;

  if not BackendExists(s.backend) then
  begin
    writeln(stderr, 'Unknown backend "', s.backend, '" in settings.');
    halt(2);
  end;

  if not OpenBackend(s, gApi, err) then
  begin
    writeln(stderr, 'Could not connect: ', err);
    halt(3);
  end;
end;

// Fetch the current reading; falls back to the last reading in a wider
// window, flagging it stale. Reports rather than raises, on the same grounds
// as FetchReadingsSafe: under the TUI there is nowhere for an exception to
// go but through the screen.
procedure FetchCurrent;
begin
  gCurrentErr := '';
  gHaveCurrent := false;
  gStale := false;
  try
    gHaveCurrent := gApi.getCurrent(gCurrent);
    if not gHaveCurrent then
    begin
      gHaveCurrent := gApi.getLast(gCurrent);
      gStale := gHaveCurrent;
    end;
  except
    on E: Exception do
    begin
      gCurrentErr := E.Message;
      gHaveCurrent := false;
      gStale := false;
    end;
  end;
end;

// One line: value, trend arrow, delta, reading time, staleness marker.
// FV's draw buffer is byte-based, so the TUI needs the ASCII arrow set and
// no multi-byte characters (the '±' that format's '%+' token emits for a
// zero delta included) — utf=false gives that variant.
function CurrentLine(utf: boolean = true): string;
begin
  if not gHaveCurrent then
    exit('No reading available');
  if utf then
    Result := gCurrent.format(gUnit, BG_MSG_DEF) + ' ' +
      BG_TREND_ARROWS_UTF[gCurrent.trend]
  else
    Result := gCurrent.format(gUnit, BG_MSG_DEF) + ' ' +
      BG_TREND_ARROWS[gCurrent.trend];
  if not gCurrent.deltaEmpty then
    Result := Result + ' (' + gCurrent.format(gUnit, BG_MSG_SIG_SHORT, BGDelta) + ')';
  if not utf then
    Result := StringReplace(Result, '±', '+-', [rfReplaceAll]);
  Result := Result + '  ' + FormatDateTime('hh:nn', gCurrent.date);
  if gStale then
    Result := Result + Format('  [stale, %d min old]',
      [MinutesBetween(Now, gCurrent.date)]);
end;

// predictReadings runs a history fetch of its own, so it costs a second
// request per refresh — only spend it when the main fetch produced something.
// A backend that just failed will not forecast either, and LibreLinkUp in
// particular is unhappy about needless calls.
procedure FetchPredictions;
begin
  gPredictOK := false;
  gPredictConf := 0;
  gPredictStable := false;
  SetLength(gPredictions, 0);
  if (not gPredictEnabled) or (Length(gReadings) = 0) then
    exit;
  try
    gPredictOK := gApi.predictReadings(PREDICT_COUNT, gPredictions);
  except
    // The forecast is an extra: a failed one drops the overlay, it does not
    // cost the graph that was fetched successfully.
    on Exception do
    begin
      gPredictOK := false;
      SetLength(gPredictions, 0);
      exit;
    end;
  end;
  // Snapshot right away: both properties describe the most recent
  // predictReadings call on the shared api object.
  gPredictConf := gApi.predictionConfidence;
  gPredictStable := gApi.stablePrediction;
end;

// getReadings, with the request clamped to Dexcom Share's hard caps on
// failure: the Dexcom backends raise above (1440 min, 288 readings) rather
// than serving what they can. Backends that serve weeks (Tandem, CareLink)
// answer the wide request, so the caps are a fallback rather than a ceiling
// applied up front.
//
// Never propagates: a request that fails even clamped — a dropped
// connection, an expired session — leaves the reason in gFetchErr and
// returns nothing, so callers report it. An exception escaping here would
// take the whole TUI down with it, terminal state and all.
function FetchReadingsSafe(minutes, maxN: integer): BGResults;
var
  clampedMin, clampedMax: integer;
begin
  Result := nil;
  gFetchErr := '';
  try
    Result := gApi.getReadings(minutes, maxN);
    exit;
  except
    on E: Exception do
      gFetchErr := E.Message;
  end;

  clampedMin := minutes;
  clampedMax := maxN;
  if clampedMin > SHARE_MAX_MINUTES then
    clampedMin := SHARE_MAX_MINUTES;
  if clampedMax > SHARE_MAX_READINGS then
    clampedMax := SHARE_MAX_READINGS;
  // The same guard rejects a request for nothing, so keep the floor too.
  if clampedMin < 1 then
    clampedMin := 1;
  if clampedMax < 1 then
    clampedMax := 1;
  // Already within the caps: whatever went wrong was not the request size,
  // so repeating it verbatim would only cost a second round trip.
  if (clampedMin = minutes) and (clampedMax = maxN) then
    exit;

  try
    Result := gApi.getReadings(clampedMin, clampedMax);
    gFetchErr := '';
  except
    on E: Exception do
    begin
      gFetchErr := E.Message;
      Result := nil;
    end;
  end;
end;

// Graph mode data: history, the current reading and the forecast.
procedure FetchAll;
var
  selDate: TDateTime;
  i: integer;
begin
  // Keep an active cursor anchored to its reading, not its index: a refresh
  // (the 5-minute poll included) shifts every index as new readings arrive.
  selDate := 0;
  if (gSel >= 0) and (gSel <= High(gReadings)) then
    selDate := gReadings[gSel].date;
  FetchCurrent;
  gReadings := FetchReadingsSafe(GRAPH_SPAN_MIN, GRAPH_MAX_READINGS);
  SortReadingsAscending(gReadings);
  FetchPredictions;
  gLastFetch := GetTickCount64;
  if gFetchErr <> '' then
    gStatus := 'fetch failed: ' + gFetchErr
  else
    gStatus := 'updated ' + FormatDateTime('hh:nn:ss', Now);
  if selDate > 0 then
  begin
    // Rolled out of the fetch window entirely: back to live.
    gSel := -1;
    for i := High(gReadings) downto 0 do
      if abs(gReadings[i].date - selDate) < 1 / SecsPerDay then
      begin
        gSel := i;
        break;
      end;
  end;
end;

// Thresholds and computed figures are plain mg/dL numbers rather than
// BGReadings, so BGReading.format is out of reach — format them here instead.
// Valid for differences (SD) as well: the conversion has no offset.
function FmtBG(mgdlVal: double): string;
begin
  if gUnit = mmol then
    Result := Format('%.1f', [mgdlVal * TrndiAPI.toMMOL])
  else
    Result := Format('%.0f', [mgdlVal]);
end;

function FmtDuration(mins: integer): string;
begin
  if mins < 60 then
    Result := Format('%d min', [mins])
  else if mins mod 60 = 0 then
    Result := Format('%d h', [mins div 60])
  else
    Result := Format('%d h %d min', [mins div 60, mins mod 60]);
end;

{------------------------------------------------------------------------------
  AGP data: fold days of history onto one 24-hour axis of percentile buckets
 ------------------------------------------------------------------------------}

// Insertion sort over the first n elements; a bucket holds a few hundred
// values at most, so anything cleverer would only add code.
procedure SortDoubles(var a: array of double; n: integer);
var
  i, j: integer;
  v: double;
begin
  for i := 1 to n - 1 do
  begin
    v := a[i];
    j := i - 1;
    while (j >= 0) and (a[j] > v) do
    begin
      a[j + 1] := a[j];
      Dec(j);
    end;
    a[j + 1] := v;
  end;
end;

// Percentile with linear interpolation (the R-7/spreadsheet definition) over
// the first n elements of an ascending array. Interpolating rather than
// taking the nearest rank keeps the bands from jumping in whole-row steps
// between adjacent buckets. Callers guarantee n >= 1.
function Percentile(const a: array of double; n: integer; p: double): double;
var
  rank: double;
  lo: integer;
begin
  if n = 1 then
    exit(a[0]);
  rank := p / 100 * (n - 1);
  lo := Trunc(rank);
  if lo >= n - 1 then
    exit(a[n - 1]);
  Result := a[lo] + (rank - lo) * (a[lo + 1] - a[lo]);
end;

// Fetch `days` of history and reduce it to the per-time-of-day percentile
// buckets in gAgp. Whatever the backend actually served decides gAgpDaysGot;
// fewer than AGP_MIN_DATA_DAYS distinct days leaves gAgpValid false with the
// explanation in gAgpErr. Dexcom lands there by construction: even the
// clamped fallback request cannot reach past its last 24 hours.
function FetchAgp(days: integer): boolean;
var
  readings: BGResults;
  vals: array[0..AGP_BUCKETS - 1] of array of double;
  fill: array[0..AGP_BUCKETS - 1] of integer;
  seen: array[0..AGP_MAX_DAYS] of boolean;
  cutoff: TDateTime;
  interval, span, maxN, i, b, d: integer;
begin
  Result := false;
  gAgpValid := false;
  gAgpErr := '';
  gAgpSel := -1;
  interval := gApi.getReportingInterval;
  if interval < 1 then
    interval := 5;
  span := days * MinsPerDay;
  maxN := span div interval + 16;   // slack for backends counting from "now"
  readings := FetchReadingsSafe(span, maxN);
  if gFetchErr <> '' then
  begin
    gAgpErr := 'history fetch failed: ' + gFetchErr;
    exit;
  end;

  for b := 0 to AGP_BUCKETS - 1 do
  begin
    vals[b] := nil;
    fill[b] := 0;
    gAgp[b].n := 0;
  end;
  for d := 0 to AGP_MAX_DAYS do
    seen[d] := false;

  // Bucket by local wall-clock time of day — the one DST transition day per
  // half-year smears a single bucket by an hour, same as printed AGPs do.
  cutoff := IncMinute(Now, -span);
  gAgpCount := 0;
  gAgpOldest := 0;
  for i := 0 to High(readings) do
  begin
    if readings[i].date < cutoff then
      continue;
    b := (HourOf(readings[i].date) * 60 + MinuteOf(readings[i].date))
      div AGP_BUCKET_MINS;
    if b > AGP_BUCKETS - 1 then
      b := AGP_BUCKETS - 1;
    if fill[b] = Length(vals[b]) then
      SetLength(vals[b], fill[b] + 64);
    vals[b][fill[b]] := readings[i].convert(mgdl);
    Inc(fill[b]);
    Inc(gAgpCount);
    if (gAgpOldest = 0) or (readings[i].date < gAgpOldest) then
      gAgpOldest := readings[i].date;
    // Distinct 24-hour periods since the cutoff, not calendar dates: an
    // N-day window touches N+1 dates, which would report "N+1 of N days".
    d := Trunc(readings[i].date - cutoff);
    if (d >= 0) and (d <= AGP_MAX_DAYS) then
      seen[d] := true;
  end;

  gAgpDaysGot := 0;
  for d := 0 to AGP_MAX_DAYS do
    if seen[d] then
      Inc(gAgpDaysGot);

  // A profile over one or two days would just echo single readings dressed
  // up as percentiles. Dexcom Share, LibreLinkUp and CareLink land here:
  // their services only serve the last day or so of history.
  if gAgpCount = 0 then
  begin
    gAgpErr := Format('no readings in the last %d days', [days]);
    exit;
  end;
  if gAgpDaysGot < AGP_MIN_DATA_DAYS then
  begin
    gAgpErr := Format('backend returned %s of history; AGP needs %d days',
      [FmtDuration(round((Now - gAgpOldest) * MinsPerDay)), AGP_MIN_DATA_DAYS]);
    exit;
  end;

  for b := 0 to AGP_BUCKETS - 1 do
    if fill[b] > 0 then
    begin
      SortDoubles(vals[b], fill[b]);
      gAgp[b].n := fill[b];
      gAgp[b].p5 := Percentile(vals[b], fill[b], 5);
      gAgp[b].p25 := Percentile(vals[b], fill[b], 25);
      gAgp[b].p50 := Percentile(vals[b], fill[b], 50);
      gAgp[b].p75 := Percentile(vals[b], fill[b], 75);
      gAgp[b].p95 := Percentile(vals[b], fill[b], 95);
    end;

  gAgpDaysReq := days;
  gAgpValid := true;
  Result := true;
end;

{------------------------------------------------------------------------------
  Free Vision TUI (graph mode)
 ------------------------------------------------------------------------------}

type
  PBGGraphView = ^TBGGraphView;
  TBGGraphView = object(TView)
    procedure Draw; virtual;
    procedure DrawAgp;
  end;

  PBGWindow = ^TBGWindow;
  TBGWindow = object(TWindow)
    constructor Init(var R: TRect);
  end;

  TTrndiTui = object(TApplication)
    constructor Init;
    procedure InitStatusLine; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure Idle; virtual;
  end;

var
  GraphWin: PBGWindow = nil;

// Fixed three-color scheme on a black canvas: red high, green in range,
// blue low. The terminal driver only emits the 8 base colors (no intensity),
// so anything subtler lands wherever the terminal theme happens to put it.
function LevelAttr(lvl: BGValLevel): byte;
begin
  case lvl of
  BGHigh:
    Result := $04;  // red on black
  BGLOW:
    Result := $01;  // blue on black
  else
    Result := $02;  // green on black (incl. the personal-limit sublevels)
  end;
end;

// The AGP view: every fetched day folded onto one 24-hour axis. Per
// time-of-day column the median is drawn solid, the 25-75% band in medium
// shade and the 5-95% band in light shade — the forecast's "shade means
// derived, not measured" convention. Cells are colored by the glucose level
// at their own height, so the thresholds appear as horizontal color
// boundaries: the top of a wide band goes red exactly where it crosses the
// high limit, which is the pattern worth spotting.
procedure TBGGraphView.DrawAgp;
var
  B: TDrawBuffer;
  y, x, bk, gh, plotW, h: integer;
  minV, maxV, pad, v, step, band, rowTop, rowBot, tick, midMgdl: double;
  isTick, any: boolean;
  lbl: string;
  attr: byte;

  // Percentiles are stored in mg/dL; the scale runs in display units.
  function Disp(mgdlVal: double): double;
  begin
    if gUnit = mmol then
      Result := mgdlVal * TrndiAPI.toMMOL
    else
      Result := mgdlVal;
  end;

begin
  gh := Size.Y - 2; // row 0 is the header, the last row the time legend
  plotW := Size.X - MARGIN;

  // Header: the highlighted bucket while the arrow keys browse, otherwise a
  // summary with the glyph legend; fetch feedback and the "not enough
  // history" verdict take precedence over both.
  MoveChar(B, ' ', attrText, Size.X);
  if gAgpErr <> '' then
    lbl := ' AGP: ' + gAgpErr + '  -  F7 returns to the graph'
  else if not gAgpValid then
    lbl := Format(' AGP: fetching %d days of history...', [gAgpDaysReq])
  else if gAgpSel >= 0 then
  begin
    lbl := ' ' + Format('%.2d:%.2d-%.2d:%.2d',
      [gAgpSel * AGP_BUCKET_MINS div 60, gAgpSel * AGP_BUCKET_MINS mod 60,
      ((gAgpSel + 1) * AGP_BUCKET_MINS div 60) mod 24,
      (gAgpSel + 1) * AGP_BUCKET_MINS mod 60]);
    if gAgp[gAgpSel].n = 0 then
      lbl := lbl + '  no readings'
    else
      lbl := lbl + Format('  median %s  25-75%%: %s-%s  5-95%%: %s-%s' +
        '  (%d readings)',
        [FmtBG(gAgp[gAgpSel].p50), FmtBG(gAgp[gAgpSel].p25),
        FmtBG(gAgp[gAgpSel].p75), FmtBG(gAgp[gAgpSel].p5),
        FmtBG(gAgp[gAgpSel].p95), gAgp[gAgpSel].n]);
    lbl := lbl + '  -  Esc returns';
  end
  else
  begin
    lbl := Format(' AGP %d days (%d with data), %d readings  -  ' +
      chFull + ' median  ' + chPredFull + ' 25-75%%  ' + chPredHalf +
      ' 5-95%%', [gAgpDaysReq, gAgpDaysGot, gAgpCount]);
    if gStatus <> '' then
      lbl := lbl + '  -  ' + gStatus;
  end;
  MoveStr(B, Copy(lbl, 1, Size.X), attrText);
  WriteLine(0, 0, Size.X, 1, B);

  if (not gAgpValid) or (gh < 2) or (plotW < 2) then
  begin
    for y := 1 to Size.Y - 1 do
    begin
      MoveChar(B, ' ', attrText, Size.X);
      WriteLine(0, y, Size.X, 1, B);
    end;
    exit;
  end;

  // Scale over the widest band drawn, padded so it never touches the edges.
  any := false;
  minV := 0;
  maxV := 0;
  for bk := 0 to AGP_BUCKETS - 1 do
    if gAgp[bk].n > 0 then
    begin
      if not any then
      begin
        minV := Disp(gAgp[bk].p5);
        maxV := Disp(gAgp[bk].p95);
        any := true;
      end;
      if Disp(gAgp[bk].p5) < minV then
        minV := Disp(gAgp[bk].p5);
      if Disp(gAgp[bk].p95) > maxV then
        maxV := Disp(gAgp[bk].p95);
    end;
  if gUnit = mmol then
  begin
    pad := 0.3;
    step := 5;   // legend tick every 5 mmol/L
  end
  else
  begin
    pad := 6;
    step := 50;  // ... and every 50 mg/dL
  end;
  minV := minV - pad;
  maxV := maxV + pad;
  band := (maxV - minV) / gh;

  for y := 1 to Size.Y - 2 do
  begin
    MoveChar(B, ' ', attrText, Size.X);

    // Does a multiple of the legend step fall inside this row's value band?
    rowTop := maxV - (y - 1) * band;
    rowBot := rowTop - band;
    tick := Trunc(rowTop / step) * step;
    isTick := (y > 1) and (y < Size.Y - 2) and (tick > rowBot);

    // Scale labels: exact bounds on the edge rows, legend steps between
    if (y = 1) or (y = Size.Y - 2) then
    begin
      if y = 1 then
        v := maxV
      else
        v := minV;
      if gUnit = mmol then
        lbl := Format('%6.1f', [v])
      else
        lbl := Format('%6.0f', [v]);
      MoveStr(B, lbl, attrLabel);
    end
    else if isTick then
    begin
      lbl := Format('%6.0f', [tick]);
      MoveStr(B, lbl, attrLabel);
    end;
    MoveChar(B[MARGIN - 1], '|', attrLabel, 1);

    // Dotted gridline under the bands on legend rows
    if isTick then
    begin
      MoveChar(B[MARGIN - 1], '+', attrLabel, 1);
      for x := 0 to plotW - 1 do
        MoveChar(B[MARGIN + x], #250, attrLabel, 1);
    end;

    // Bands: whole-cell resolution — these are vertical ranges, not bar
    // tops, so the half-block trick does not apply. The cursor's bucket
    // trades level color for white, as the bar cursor does.
    midMgdl := rowTop - band / 2;
    if gUnit = mmol then
      midMgdl := midMgdl / TrndiAPI.toMMOL;
    for x := 0 to plotW - 1 do
    begin
      bk := x * AGP_BUCKETS div plotW;
      if gAgp[bk].n = 0 then
        continue;
      if bk = gAgpSel then
        attr := attrText
      else
        attr := LevelAttr(gApi.getLevel(midMgdl));
      if (Disp(gAgp[bk].p50) <= rowTop) and (Disp(gAgp[bk].p50) > rowBot) then
        MoveChar(B[MARGIN + x], chFull, attr, 1)
      else if (Disp(gAgp[bk].p25) < rowTop) and (Disp(gAgp[bk].p75) > rowBot) then
        MoveChar(B[MARGIN + x], chPredFull, attr, 1)
      else if (Disp(gAgp[bk].p5) < rowTop) and (Disp(gAgp[bk].p95) > rowBot) then
        MoveChar(B[MARGIN + x], chPredHalf, attr, 1);
    end;
    WriteLine(0, y, Size.X, 1, B);
  end;

  // Time legend: fixed clock hours — this axis is time of day, not a
  // scrolling window.
  MoveChar(B, ' ', attrLabel, Size.X);
  for h := 0 to 3 do
  begin
    x := h * 6 * 60 div AGP_BUCKET_MINS * plotW div AGP_BUCKETS;
    if x + 5 <= plotW then
      MoveStr(B[MARGIN + x], Format('%.2d:00', [h * 6]), attrLabel);
  end;
  // Cursor marker under the first column of its bucket.
  if gAgpSel >= 0 then
    for x := 0 to plotW - 1 do
      if x * AGP_BUCKETS div plotW = gAgpSel then
      begin
        MoveChar(B[MARGIN + x], '^', attrText, 1);
        break;
      end;
  WriteLine(0, Size.Y - 1, Size.X, 1, B);
end;

// How many forecast columns to draw: none when the user turned it off, when
// the backend could not produce one, when the trend is flat (a straight line
// ahead says nothing) or when the fit was too noisy to be worth showing.
function PredictColumns: integer;
begin
  if (not gPredictEnabled) or (not gPredictOK) or gPredictStable or
    (gPredictConf < PREDICT_MIN_CONF) then
    exit(0);
  Result := Length(gPredictions);
end;

procedure TBGGraphView.Draw;
var
  B: TDrawBuffer;
  y, x, i, gh, gw, first, pn, histW, horizon: integer;
  minV, maxV, pad, v, step, band, rowTop, tick: double;
  isTick: boolean;
  lbl: string;
  attr: byte;

  // Map a value onto the current row's half-steps and emit the right glyph.
  procedure PlotCell(col: integer; value: double; attr: byte; full, half: char);
  var
    halves: integer;
  begin
    halves := round((value - minV) / (maxV - minV) * gh * 2);
    if halves < 1 then
      halves := 1;
    // Row y covers half-steps (gh-y)*2+1 .. (gh-y)*2+2 counted from the bottom
    if halves >= (gh - y + 1) * 2 then
      MoveChar(B[col], full, attr, 1)
    else if halves = (gh - y) * 2 + 1 then
      MoveChar(B[col], half, attr, 1);
  end;

begin
  if gAgpMode then
  begin
    DrawAgp;
    exit;
  end;

  gh := Size.Y - 2; // row 0 is the header, the last row the time legend
  gw := Size.X - MARGIN;

  if gSel > High(gReadings) then
    gSel := High(gReadings);  // history shrank under the cursor (-1 if empty)

  // Split the plot between history and forecast. The forecast never takes
  // more than a quarter of the width: on a narrow window shorten the horizon
  // rather than crowd out measured data, and drop it entirely once even that
  // leaves too little to be worth a divider.
  pn := PredictColumns;
  if pn > gw div 4 then
    pn := gw div 4;
  if pn < 2 then
    pn := 0;
  if pn > 0 then
    histW := gw - pn - 1      // one column for the divider
  else
    histW := gw;

  // Header: the reading under the cursor while the arrow keys browse the
  // history, the live line otherwise. The cursor's column is the one drawn
  // in white below.
  MoveChar(B, ' ', attrText, Size.X);
  if gSel >= 0 then
    lbl := ' ' + FormatDateTime('hh:nn', gReadings[gSel].date) + '  ' +
      gReadings[gSel].format(gUnit, BG_MSG_DEF) +
      '  -  arrow keys browse, Esc returns to live'
  else
  begin
    lbl := ' ' + CurrentLine(false);
    if gStatus <> '' then
      lbl := lbl + '  -  ' + gStatus;
    if (pn > 0) and (Length(gReadings) > 0) then
    begin
      horizon := round((gPredictions[pn - 1].date - gReadings[High(gReadings)].date)
        * 24 * 60);
      // Say "forecast" outright: a bare shade glyph with a percentage reads
      // as noise to anyone who has not met the shaded bars yet.
      lbl := lbl + Format('  -  forecast %s +%d min %.0f%%',
        [chPredFull, horizon, gPredictConf * 100]);
    end;
  end;
  MoveStr(B, Copy(lbl, 1, Size.X), attrText);
  WriteLine(0, 0, Size.X, 1, B);

  if (Length(gReadings) = 0) or (gh < 2) or (gw < 2) then
  begin
    MoveChar(B, ' ', attrText, Size.X);
    if gh >= 1 then
    begin
      MoveStr(B, ' (no readings)', attrLabel);
      WriteLine(0, 1, Size.X, 1, B);
    end;
    for y := 2 to Size.Y - 1 do
    begin
      MoveChar(B, ' ', attrText, Size.X);
      WriteLine(0, y, Size.X, 1, B);
    end;
    exit;
  end;

  // Newest readings to the left of the divider; one column per reading.
  first := Length(gReadings) - histW;
  if first < 0 then
    first := 0;
  gFirstVis := first;  // the cursor's left stop, see HandleEvent

  // Scale across everything drawn, forecast included so it cannot clip,
  // padded so bars never touch the edges.
  minV := gReadings[first].convert(gUnit);
  maxV := minV;
  for i := first to High(gReadings) do
  begin
    v := gReadings[i].convert(gUnit);
    if v < minV then
      minV := v;
    if v > maxV then
      maxV := v;
  end;
  for i := 0 to pn - 1 do
  begin
    v := gPredictions[i].convert(gUnit);
    if v < minV then
      minV := v;
    if v > maxV then
      maxV := v;
  end;
  if gUnit = mmol then
  begin
    pad := 0.3;
    step := 5;   // legend tick every 5 mmol/L
  end
  else
  begin
    pad := 6;
    step := 50;  // ... and every 50 mg/dL
  end;
  minV := minV - pad;
  maxV := maxV + pad;
  band := (maxV - minV) / gh;

  for y := 1 to Size.Y - 2 do
  begin
    MoveChar(B, ' ', attrText, Size.X);

    // Does a multiple of the legend step fall inside this row's value band?
    rowTop := maxV - (y - 1) * band;
    tick := Trunc(rowTop / step) * step;
    isTick := (y > 1) and (y < Size.Y - 2) and (tick > rowTop - band);

    // Scale labels: exact bounds on the edge rows, legend steps between
    if (y = 1) or (y = Size.Y - 2) then
    begin
      if y = 1 then
        v := maxV
      else
        v := minV;
      if gUnit = mmol then
        lbl := Format('%6.1f', [v])
      else
        lbl := Format('%6.0f', [v]);
      MoveStr(B, lbl, attrLabel);
    end
    else if isTick then
    begin
      lbl := Format('%6.0f', [tick]);
      MoveStr(B, lbl, attrLabel);
    end;
    MoveChar(B[MARGIN - 1], '|', attrLabel, 1);

    // Dotted gridline under the bars on legend rows
    if isTick then
    begin
      MoveChar(B[MARGIN - 1], '+', attrLabel, 1);
      for x := 0 to gw - 1 do
        MoveChar(B[MARGIN + x], #250, attrLabel, 1);
    end;

    // Bars: value mapped to half-block steps from the bottom. The cursor's
    // column trades its level color for white — the header carries the value.
    for x := 0 to histW - 1 do
    begin
      i := first + x;
      if i > High(gReadings) then
        break;
      if i = gSel then
        attr := attrText
      else
        attr := LevelAttr(gApi.getLevel(gReadings[i].convert(mgdl)));
      PlotCell(MARGIN + x, gReadings[i].convert(gUnit), attr, chFull, chHalf);
    end;

    // Forecast, past the "now" divider: same geometry and level colors, drawn
    // in shade rather than solid so it cannot be read as measured data.
    if pn > 0 then
    begin
      MoveChar(B[MARGIN + histW], chDivider, attrLabel, 1);
      for x := 0 to pn - 1 do
        PlotCell(MARGIN + histW + 1 + x, gPredictions[x].convert(gUnit),
          LevelAttr(gApi.getLevel(gPredictions[x].convert(mgdl))),
          chPredFull, chPredHalf);
    end;
    WriteLine(0, y, Size.X, 1, B);
  end;

  // Time legend: the reading time under every 15th column. Only under the
  // history — the forecast's own times are implied by the horizon in the
  // header, and a future clock time under a shaded bar invites reading it as
  // an appointment.
  MoveChar(B, ' ', attrLabel, Size.X);
  x := 0;
  while x + 5 <= histW do
  begin
    i := first + x;
    if i > High(gReadings) then
      break;
    MoveStr(B[MARGIN + x], FormatDateTime('hh:nn', gReadings[i].date), attrLabel);
    Inc(x, 15);
  end;
  // Cursor marker under its column, on top of any time label there.
  if (gSel >= first) and (gSel - first < histW) then
    MoveChar(B[MARGIN + gSel - first], '^', attrText, 1);
  WriteLine(0, Size.Y - 1, Size.X, 1, B);
end;

constructor TBGWindow.Init(var R: TRect);
var
  IR: TRect;
  gv: PBGGraphView;
begin
  // The account in the frame title, so two graphs side by side on the same
  // machine are tellable apart; the default account keeps the plain name.
  if ActiveProfileName <> '' then
    inherited Init(R, 'Trndi - ' + ActiveProfileName, wnNoNumber)
  else
    inherited Init(R, 'Trndi', wnNoNumber);
  // The window fills the desktop and has to keep doing so when the terminal
  // changes size under it (see TTrndiTui.Idle).
  GrowMode := gfGrowHiX + gfGrowHiY;
  GetExtent(IR);
  IR.Grow(-1, -1);
  gv := New(PBGGraphView, Init(IR));
  gv^.GrowMode := gfGrowHiX + gfGrowHiY;
  Insert(gv);
end;

constructor TTrndiTui.Init;
var
  R: TRect;
begin
  inherited Init;
  DeskTop^.GetExtent(R);
  GraphWin := New(PBGWindow, Init(R));
  DeskTop^.Insert(GraphWin);
end;

procedure TTrndiTui.InitStatusLine;
var
  R: TRect;
begin
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
  // The first and last entries are display only (kbNoKey maps nothing): the
  // exit keys and the arrow keys reach HandleEvent on their own, these just
  // say they do something.
  // #27#26 are CP437's left/right arrows, same route as the block glyphs.
  StatusLine := New(PStatusLine, Init(R,
    NewStatusDef(0, $FFFF,
      NewStatusKey('~Q~ Exit', kbNoKey, 0,
      NewStatusKey('~F5~ Refresh', kbF5, cmRefresh,
      NewStatusKey('~F6~ Forecast', kbF6, cmPredict,
      NewStatusKey('~F7~ AGP', kbF7, cmAGP,
      NewStatusKey('~F9~ Settings', kbF9, cmSetup,
      NewStatusKey('~'#27#26'~ Inspect', kbNoKey, 0,
      nil)))))),
    nil)));
end;

// Settings changed under a running graph. The new backend replaces the old one
// only once it has connected: a typo in the settings window should cost a
// message, not the session's data.
procedure ReloadBackend;
var
  s: TCliSettings;
  api: TrndiAPI;
  err: string;
begin
  s := LoadSettings;
  if not OpenBackend(s, api, err) then
  begin
    ShowError('Could not connect with the new settings: ' + err +
      #13#13 + 'The previous backend is still in use.');
    exit;
  end;
  gApi.Free;
  gApi := api;
  if s.mmol then
    gUnit := mmol
  else
    gUnit := mgdl;
  FetchAll;
end;

// Repaint and flush before a blocking fetch: Redraw only fills the video
// buffer, and the driver's own flush waits for the event loop this handler
// is still holding up. Without the explicit flush the "fetching..." header
// would appear only after the wait it announces.
procedure ShowFetching;
begin
  if GraphWin <> nil then
    GraphWin^.Redraw;
  UpdateScreen(false);
end;

procedure TTrndiTui.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evCommand) and (Event.Command = cmRefresh) then
  begin
    // F5 refreshes what is on screen: the AGP where that is the view — its
    // cache never rides the 5-minute poll — and the live data elsewhere.
    if gAgpMode then
    begin
      gAgpValid := false;
      gAgpErr := '';
      ShowFetching;
      FetchAgp(gAgpDaysReq);
    end
    else
      FetchAll;
    if GraphWin <> nil then
      GraphWin^.Redraw;
    ClearEvent(Event);
  end
  else if (Event.What = evCommand) and (Event.Command = cmPredict) then
  begin
    // Inert in the AGP view: a percentile-of-days chart has no "next 30 min".
    if not gAgpMode then
    begin
      gPredictEnabled := not gPredictEnabled;
      // Turning it back on mid-session has nothing to draw yet, so pay for the
      // fetch here rather than leaving the key press look like it did nothing.
      if gPredictEnabled and (not gPredictOK) then
        FetchPredictions;
      if GraphWin <> nil then
        GraphWin^.Redraw;
    end;
    ClearEvent(Event);
  end
  else if (Event.What = evCommand) and (Event.Command = cmAGP) then
  begin
    gAgpMode := not gAgpMode;
    gAgpSel := -1;
    // The first toggle pays for the history fetch; after that the cache
    // holds until F5, new settings or exit.
    if gAgpMode and (not gAgpValid) and (gAgpErr = '') then
    begin
      ShowFetching;
      FetchAgp(gAgpDaysReq);
    end;
    if GraphWin <> nil then
      GraphWin^.Redraw;
    ClearEvent(Event);
  end
  else if (Event.What = evCommand) and (Event.Command = cmSetup) then
  begin
    if ExecSetupDialog then
    begin
      ReloadBackend;
      // New backend, new thresholds and history: the cached profile is
      // another backend's data, so it must not survive the switch.
      gAgpValid := false;
      gAgpErr := '';
      if gAgpMode then
      begin
        ShowFetching;
        FetchAgp(gAgpDaysReq);
      end;
    end;
    // Redraw either way: the dialog covered the graph while it was open.
    if GraphWin <> nil then
      GraphWin^.Redraw;
    ClearEvent(Event);
  end
  else if Event.What = evKeyDown then
  begin
    // Leaving. Free Vision's own exit key is Alt-X, but Haiku hands Alt to
    // the system as its command modifier — its Terminal answers Alt-X itself
    // and the application never sees it — so the key bar advertises plain Q,
    // which no terminal claims, and Alt-X and Ctrl-X keep working for the
    // fingers that already know them. Nothing here reads text, so a bare
    // letter is free: the settings window is modal and takes its own keys.
    if (Event.KeyCode = kbAltX) or (Event.KeyCode = kbCtrlX) or
      (UpCase(Event.CharCode) = 'Q') then
    begin
      ClearEvent(Event);
      EndModal(cmQuit);
      exit;
    end;
    if gAgpMode then
    begin
      // The bucket cursor: same moves as the reading cursor below, over the
      // 48 time-of-day slots. Empty buckets stay selectable — the header
      // saying "no readings" is how a nightly sensor gap shows itself.
      if not gAgpValid then
        exit;
      case Event.KeyCode of
      kbLeft:
        if gAgpSel < 0 then
          gAgpSel := AGP_BUCKETS - 1
        else if gAgpSel > 0 then
          Dec(gAgpSel);
      kbRight:
        if gAgpSel < 0 then
          exit
        else
        begin
          // Stepping past the last bucket lands back on the summary header.
          Inc(gAgpSel);
          if gAgpSel > AGP_BUCKETS - 1 then
            gAgpSel := -1;
        end;
      kbHome:
        gAgpSel := 0;
      kbEnd:
        gAgpSel := AGP_BUCKETS - 1;
      kbEsc:
        if gAgpSel < 0 then
          exit
        else
          gAgpSel := -1;
      else
        exit;
      end;
    end
    else
    begin
      // The reading cursor. One column per reading, so Left/Right step one
      // reading at a time; the left stop is the oldest column on screen —
      // older readings exist but have no column to put the cursor on.
      if Length(gReadings) = 0 then
        exit;
      case Event.KeyCode of
      kbLeft:
        if gSel < 0 then
          gSel := High(gReadings)
        else if gSel > gFirstVis then
          Dec(gSel);
      kbRight:
        if gSel < 0 then
          exit
        else
        begin
          // Stepping past the newest reading lands back on the live header.
          Inc(gSel);
          if gSel > High(gReadings) then
            gSel := -1;
        end;
      kbHome:
        gSel := gFirstVis;
      kbEnd:
        gSel := High(gReadings);
      kbEsc:
        if gSel < 0 then
          exit
        else
          gSel := -1;
      else
        exit;
      end;
    end;
    if GraphWin <> nil then
      GraphWin^.Redraw;
    ClearEvent(Event);
  end;
end;

procedure TTrndiTui.Idle;
var
  mode: TVideoMode;
begin
  inherited Idle;
  // A terminal resized under the graph: relayout every view from the
  // application down. The window and the status line follow through their
  // grow modes.
  if ScreenSizeChanged(mode) then
  begin
    SetScreenVideoMode(mode);
    Redraw;
  end;
  if GetTickCount64 - gLastFetch >= POLL_INTERVAL_MS then
  begin
    FetchAll;
    if GraphWin <> nil then
      GraphWin^.Redraw;
  end;
end;

{------------------------------------------------------------------------------
  Statistics (--stats)
 ------------------------------------------------------------------------------}

const
  STATS_DEFAULT_HOURS = 24;
  STATS_MAX_HOURS = 168;   // a week; beyond that backends stop cooperating
  BAR_WIDTH = 20;
  BAR_FULL = '█';
  BAR_EMPTY = '░';

function Bar(pct: double): string;
var
  x, filled: integer;
begin
  filled := round(pct / 100 * BAR_WIDTH);
  if (filled = 0) and (pct > 0) then
    filled := 1;                      // a bucket with readings is never blank
  if filled > BAR_WIDTH then
    filled := BAR_WIDTH;
  Result := '';
  for x := 1 to BAR_WIDTH do
    if x <= filled then
      Result := Result + BAR_FULL
    else
      Result := Result + BAR_EMPTY;
end;

// One distribution row: label, the band it covers, a bar, the share of
// readings and the time that share stands for at the reporting interval.
procedure StatRow(const name, band: string; count, total, interval: integer);
var
  pct: double;
begin
  pct := count / total * 100;
  writeln(Format('  %-9s %9s  %s %3.0f%%  %s',
    [name, band, Bar(pct), pct, FmtDuration(count * interval)]));
end;

// Summarise the last `hours` hours: average, spread, GMI and the standard
// five-band time-in-range breakdown. The bands come from the backend's own
// thresholds via getLevel, so they match the colors used in graph mode.
procedure RunStats(hours: integer);
var
  readings: BGResults;
  core: CGMCore;
  counts: array[BGValLevel] of integer;
  lvl: BGValLevel;
  cutoff, oldest, minAt, maxAt: TDateTime;
  i, n, interval, expected, coverage, span: integer;
  v, sum, sumsq, mean, sd, cv, gmi, minV, maxV, inLo, inHi: double;
  hasTop, hasBottom: boolean;
  timeFmt, sinceFmt, u: string;
begin
  span := hours * 60;
  interval := gApi.getReportingInterval;
  if interval < 1 then
    interval := 5;
  // Ask for a full window even from a one-minute uploader, plus slack for
  // backends that count from their own idea of "now".
  readings := FetchReadingsSafe(span, span div interval + 16);

  cutoff := IncMinute(Now, -span);
  n := 0;
  sum := 0;
  sumsq := 0;
  minV := 0;
  maxV := 0;
  oldest := 0;
  minAt := 0;
  maxAt := 0;
  for lvl := Low(BGValLevel) to High(BGValLevel) do
    counts[lvl] := 0;

  for i := 0 to High(readings) do
  begin
    if readings[i].date < cutoff then
      continue;                       // backends may hand back a wider window
    v := readings[i].convert(mgdl);
    if (n = 0) or (readings[i].date < oldest) then
      oldest := readings[i].date;
    if (n = 0) or (v < minV) then
    begin
      minV := v;
      minAt := readings[i].date;
    end;
    if (n = 0) or (v > maxV) then
    begin
      maxV := v;
      maxAt := readings[i].date;
    end;
    sum := sum + v;
    sumsq := sumsq + v * v;
    Inc(counts[gApi.getLevel(v)]);
    Inc(n);
  end;

  if n = 0 then
  begin
    if gFetchErr <> '' then
      writeln(stderr, 'History fetch failed: ', gFetchErr)
    else
      writeln(stderr, Format('No readings in the last %d h.', [hours]));
    halt(4);
  end;

  mean := sum / n;
  if n >= 2 then
    sd := sqrt((sumsq - sum * sum / n) / (n - 1))
  else
    sd := 0;
  if mean > 0 then
    cv := sd / mean * 100
  else
    cv := 0;
  gmi := 3.31 + 0.02392 * mean;       // Bergenstal et al., mean in mg/dL

  // Readings actually seen against what the interval promises. Uploaders that
  // beat their nominal interval would push this over 100%, which reads as an
  // error rather than as good coverage.
  expected := span div interval;
  if expected < 1 then
    expected := 1;
  coverage := round(n / expected * 100);
  if coverage > 100 then
    coverage := 100;

  core := gApi.cgm;
  // A personal bound that meets or passes the hard limit leaves its band
  // empty — an override.hi at the backend's own target top does that — so
  // fold it away rather than print a "10.0-10.0" row.
  hasTop := (core.top <> TrndiAPI.CGM_RANGE_HI_DISABLED) and
    (core.top < core.hi);
  hasBottom := (core.bottom <> TrndiAPI.CGM_RANGE_LO_DISABLED) and
    (core.bottom > core.lo);
  if hasTop then
    inHi := core.top
  else
    inHi := core.hi;
  if hasBottom then
    inLo := core.bottom
  else
    inLo := core.lo;

  // A bare time is enough within a day; longer windows need the date. The
  // start of the period is dated a bit sooner, since a 24 h window puts it on
  // the day before.
  if hours > 24 then
    timeFmt := 'yyyy-mm-dd hh:nn'
  else
    timeFmt := 'hh:nn';
  if hours > 12 then
    sinceFmt := 'yyyy-mm-dd hh:nn'
  else
    sinceFmt := 'hh:nn';
  u := BG_UNIT_NAMES[gUnit];

  writeln(Format('Stats — last %d h — %s', [hours, gApi.systemName]));
  // Where the data actually starts, so a window the backend could not fill —
  // capped fetch, sensor change, a fresh site — shows up as more than a low
  // coverage figure.
  writeln(Format('%d readings since %s, %d%% coverage at a %d min interval',
    [n, FormatDateTime(sinceFmt, oldest), coverage, interval]));
  writeln;
  writeln(Format('  Average   %7s %s', [FmtBG(mean), u]));
  writeln(Format('  Std dev   %7s %s  (CV %.1f%%)', [FmtBG(sd), u, cv]));
  writeln(Format('  GMI       %7.1f %%  (%.0f mmol/mol)',
    [gmi, (gmi - 2.15) * 10.929]));
  writeln(Format('  Lowest    %7s %s  at %s',
    [FmtBG(minV), u, FormatDateTime(timeFmt, minAt)]));
  writeln(Format('  Highest   %7s %s  at %s',
    [FmtBG(maxV), u, FormatDateTime(timeFmt, maxAt)]));
  writeln;

  // Five bands when a personal target range is configured, three when the
  // backend only reports hard high/low limits (the sublevels stay empty then).
  if hasTop then
  begin
    StatRow('Very high', '>' + FmtBG(core.hi), counts[BGHigh], n, interval);
    StatRow('High', FmtBG(core.top) + '-' + FmtBG(core.hi),
      counts[BGRangeHI], n, interval);
  end
  else
    StatRow('High', '>' + FmtBG(core.hi), counts[BGHigh], n, interval);

  StatRow('In range', FmtBG(inLo) + '-' + FmtBG(inHi), counts[BGRange], n,
    interval);

  if hasBottom then
  begin
    StatRow('Low', FmtBG(core.lo) + '-' + FmtBG(core.bottom),
      counts[BGRangeLO], n, interval);
    StatRow('Very low', '<' + FmtBG(core.lo), counts[BGLOW], n, interval);
  end
  else
    StatRow('Low', '<' + FmtBG(core.lo), counts[BGLOW], n, interval);
end;

{------------------------------------------------------------------------------
  Sparkline (--spark)
 ------------------------------------------------------------------------------}

const
  SPARK_DEFAULT_HOURS = 3;
  SPARK_MAX_HOURS = 24;
  // Longer than this and the line outgrows a status bar; the buckets widen
  // instead, so a day still fits.
  SPARK_MAX_COLS = 60;

// Color only when stdout is a terminal that will interpret the escape codes:
// a pipe — a status bar module, a MOTD script — gets the bare glyphs, and
// NO_COLOR is honoured. On Windows the codes only work once virtual terminal
// processing is switched on, so failing to enable it means no color.
function StdoutSupportsColor: boolean;
{$IFDEF WINDOWS}
const
  ENABLE_VT = $0004;  // ENABLE_VIRTUAL_TERMINAL_PROCESSING, absent from older headers
var
  h: HANDLE;
  mode: DWORD;
{$ENDIF}
begin
  // Qualified: the Windows unit's three-argument WinAPI import would win the
  // overload otherwise, since it is pulled in after SysUtils.
  if SysUtils.GetEnvironmentVariable('NO_COLOR') <> '' then
    exit(false);
{$IFDEF WINDOWS}
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  Result := (GetFileType(h) = FILE_TYPE_CHAR) and GetConsoleMode(h, mode) and
    SetConsoleMode(h, mode or ENABLE_VT);
{$ELSE}
  Result := IsATTY(output) = 1;
{$ENDIF}
end;

// The graph's fixed scheme as SGR codes: red high, blue low, green in range
// (the personal-limit sublevels included, as in LevelAttr).
function LevelSGR(lvl: BGValLevel): string;
begin
  case lvl of
  BGHigh:
    Result := #27'[31m';
  BGLOW:
    Result := #27'[34m';
  else
    Result := #27'[32m';
  end;
end;

// The last `hours` hours as one line of block glyphs, one per reporting
// interval, followed by the current reading — graph mode's shape in a form a
// status bar or MOTD can carry. Scaled to the window's own min/max, like any
// sparkline; color carries the thresholds, so the scale needs no labels.
procedure RunSpark(hours: integer);
const
  GLYPHS: array[0..7] of string =
    ('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█');
var
  readings: BGResults;
  sums: array of double;
  counts: array of integer;
  span, interval, bucketMins, cols, firstCol, i, b, idx, n: integer;
  cutoff: TDateTime;
  mean, minV, maxV: double;
  line, sgr, want: string;
  color, seen: boolean;
begin
  span := hours * 60;
  interval := gApi.getReportingInterval;
  if interval < 1 then
    interval := 5;

  // One bucket per reporting interval until the line would overflow, then
  // wider buckets; readings within a bucket are averaged.
  bucketMins := (span + SPARK_MAX_COLS - 1) div SPARK_MAX_COLS;
  if bucketMins < interval then
    bucketMins := interval;
  cols := (span + bucketMins - 1) div bucketMins;

  readings := FetchReadingsSafe(span, span div interval + 16);
  cutoff := IncMinute(Now, -span);

  SetLength(sums, cols);
  SetLength(counts, cols);
  n := 0;
  for i := 0 to High(readings) do
  begin
    if readings[i].date < cutoff then
      continue;                       // backends may hand back a wider window
    b := MinutesBetween(readings[i].date, cutoff) div bucketMins;
    if b > cols - 1 then
      b := cols - 1;                  // clock skew can date a reading past now
    sums[b] := sums[b] + readings[i].convert(mgdl);
    Inc(counts[b]);
    Inc(n);
  end;

  if n = 0 then
  begin
    if gFetchErr <> '' then
      writeln(stderr, 'History fetch failed: ', gFetchErr)
    else
      writeln(stderr, Format('No readings in the last %d h.', [hours]));
    halt(4);
  end;

  // Scale over the bucket means. mg/dL throughout: the conversion is linear,
  // so the glyph heights come out the same in either unit.
  seen := false;
  minV := 0;
  maxV := 0;
  for b := 0 to cols - 1 do
  begin
    if counts[b] = 0 then
      continue;
    mean := sums[b] / counts[b];
    if (not seen) or (mean < minV) then
      minV := mean;
    if (not seen) or (mean > maxV) then
      maxV := mean;
    seen := true;
  end;

  // A window the backend could not fill starts at the data, not at a run of
  // blanks; a gap in the middle stays a gap rather than borrowing a value.
  firstCol := 0;
  while counts[firstCol] = 0 do
    Inc(firstCol);

  color := StdoutSupportsColor;
  line := '';
  sgr := '';
  for b := firstCol to cols - 1 do
  begin
    if counts[b] = 0 then
    begin
      line := line + ' ';
      continue;
    end;
    mean := sums[b] / counts[b];
    if maxV > minV then
      idx := round((mean - minV) / (maxV - minV) * 7)
    else
      idx := 3;                       // a flat window sits mid-height
    if color then
    begin
      want := LevelSGR(gApi.getLevel(mean));
      if want <> sgr then
      begin
        line := line + want;
        sgr := want;
      end;
    end;
    line := line + GLYPHS[idx];
  end;
  if sgr <> '' then
    line := line + #27'[0m';

  // The line the bare invocation prints, after the history it summarises.
  // A backend with history but no fresh reading still shows the sparkline.
  FetchCurrent;
  if gHaveCurrent then
    line := line + '  ' + CurrentLine;
  writeln(line);
end;

{------------------------------------------------------------------------------
  --agp: the AGP as a one-shot chart
 ------------------------------------------------------------------------------}

const
  AGP_ONESHOT_ROWS = 16;
  AGP_ONESHOT_COLS = 72;   // 1.5 columns per half-hour bucket

// The F7 view printed once: same buckets, same three-way cell test, UTF-8
// shade glyphs instead of CP437 and SGR colors instead of FV attributes.
procedure RunAGP(days: integer);
var
  y, x, b, h: integer;
  minV, maxV, pad, step, band, rowTop, rowBot, tick, midMgdl: double;
  isTick, any, color: boolean;
  line, sgr, want, gutter: string;
  axis: string;

  function Disp(mgdlVal: double): double;
  begin
    if gUnit = mmol then
      Result := mgdlVal * TrndiAPI.toMMOL
    else
      Result := mgdlVal;
  end;

begin
  if not FetchAgp(days) then
  begin
    writeln(stderr, 'No AGP: ', gAgpErr, '.');
    halt(4);
  end;

  writeln(Format('AGP — last %d days — %s', [days, gApi.systemName]));
  // Days with data against days asked for: a backend that could not fill the
  // window — capped history, a fresh site — shows up here, not as a silently
  // thinner profile.
  writeln(Format('%d readings across %d of %d days since %s, %d min buckets',
    [gAgpCount, gAgpDaysGot, days,
    FormatDateTime('yyyy-mm-dd', gAgpOldest), AGP_BUCKET_MINS]));
  writeln;

  // Scale over the widest band, padded — the F7 view's arithmetic.
  any := false;
  minV := 0;
  maxV := 0;
  for b := 0 to AGP_BUCKETS - 1 do
    if gAgp[b].n > 0 then
    begin
      if not any then
      begin
        minV := Disp(gAgp[b].p5);
        maxV := Disp(gAgp[b].p95);
        any := true;
      end;
      if Disp(gAgp[b].p5) < minV then
        minV := Disp(gAgp[b].p5);
      if Disp(gAgp[b].p95) > maxV then
        maxV := Disp(gAgp[b].p95);
    end;
  if gUnit = mmol then
  begin
    pad := 0.3;
    step := 5;
  end
  else
  begin
    pad := 6;
    step := 50;
  end;
  minV := minV - pad;
  maxV := maxV + pad;
  band := (maxV - minV) / AGP_ONESHOT_ROWS;

  color := StdoutSupportsColor;
  for y := 1 to AGP_ONESHOT_ROWS do
  begin
    rowTop := maxV - (y - 1) * band;
    rowBot := rowTop - band;
    tick := Trunc(rowTop / step) * step;
    isTick := (y > 1) and (y < AGP_ONESHOT_ROWS) and (tick > rowBot);

    if (y = 1) or (y = AGP_ONESHOT_ROWS) then
    begin
      if gUnit = mmol then
        gutter := Format('%6.1f |', [maxV])
      else
        gutter := Format('%6.0f |', [maxV]);
      if y = AGP_ONESHOT_ROWS then
        if gUnit = mmol then
          gutter := Format('%6.1f |', [minV])
        else
          gutter := Format('%6.0f |', [minV]);
    end
    else if isTick then
      gutter := Format('%6.0f +', [tick])
    else
      gutter := '       |';

    line := gutter;
    sgr := '';
    midMgdl := rowTop - band / 2;
    if gUnit = mmol then
      midMgdl := midMgdl / TrndiAPI.toMMOL;
    for x := 0 to AGP_ONESHOT_COLS - 1 do
    begin
      b := x * AGP_BUCKETS div AGP_ONESHOT_COLS;
      want := '';
      if gAgp[b].n = 0 then
        want := ' '
      else if (Disp(gAgp[b].p50) <= rowTop) and (Disp(gAgp[b].p50) > rowBot) then
        want := '█'
      else if (Disp(gAgp[b].p25) < rowTop) and (Disp(gAgp[b].p75) > rowBot) then
        want := '▒'
      else if (Disp(gAgp[b].p5) < rowTop) and (Disp(gAgp[b].p95) > rowBot) then
        want := '░'
      else if isTick then
        want := '·'
      else
        want := ' ';
      if color and (want <> ' ') and (want <> '·') then
      begin
        if LevelSGR(gApi.getLevel(midMgdl)) <> sgr then
        begin
          sgr := LevelSGR(gApi.getLevel(midMgdl));
          line := line + sgr;
        end;
      end
      else if (sgr <> '') and ((want = ' ') or (want = '·')) then
      begin
        line := line + #27'[0m';
        sgr := '';
      end;
      line := line + want;
    end;
    if sgr <> '' then
      line := line + #27'[0m';
    writeln(line);
  end;

  // Clock-hour axis, labels at the same columns the buckets map onto.
  axis := StringOfChar(' ', 8 + AGP_ONESHOT_COLS);
  for h := 0 to 3 do
  begin
    x := h * 6 * 60 div AGP_BUCKET_MINS * AGP_ONESHOT_COLS div AGP_BUCKETS;
    if x + 5 <= AGP_ONESHOT_COLS then
      move(Format('%.2d:00', [h * 6])[1], axis[9 + x], 5);
  end;
  writeln(TrimRight(axis));
  writeln;
  writeln('  █ median   ▒ 25-75%   ░ 5-95%');
end;

{------------------------------------------------------------------------------
  Entry point
 ------------------------------------------------------------------------------}

procedure RunGraph;
var
  Tui: TTrndiTui;
begin
  FetchAll;
  Tui.Init;
  Tui.Run;
  Tui.Done;
end;

// --setup: the settings window on its own, with no backend needed to get
// there. Writes to the same store the GUI uses.
procedure RunSetupMode;
begin
  if not ConsoleIsInteractive then
  begin
    writeln(stderr, '--setup needs a terminal; settings live in ',
      SettingsLocation, '.');
    halt(64);
  end;
  if RunSetup then
  begin
    if ActiveProfileName <> '' then
      writeln('Settings saved for "', ActiveProfileName, '" in ',
        SettingsLocation, '.')
    else
      writeln('Settings saved in ', SettingsLocation, '.');
  end
  else
    writeln('Settings unchanged.');
end;

// The one-shot print. With check the exit code carries where the reading
// sits — 0 in range, 5 above the high threshold, 6 below the low one — so a
// script can alarm without parsing the line. The bands match the graph
// colors: the personal-limit sublevels count as in range, as they draw green.
// A stale fallback keeps exit 4; a cron job polling every few minutes should
// not alarm on hours-old data.
procedure RunOnce(check: boolean);
begin
  FetchCurrent;
  if not gHaveCurrent then
  begin
    if gCurrentErr <> '' then
      writeln(stderr, 'No reading available: ', gCurrentErr)
    else
      writeln(stderr, 'No reading available: ', gApi.errormsg);
    halt(4);
  end;
  writeln(CurrentLine);
  if (not check) or gStale then
  begin
    if check then
      halt(4);
    exit;
  end;
  case gApi.getLevel(gCurrent.convert(mgdl)) of
  BGHigh:
    halt(5);
  BGLOW:
    halt(6);
  end;
end;

// Bare --profile: the accounts this machine's settings hold, one per line —
// plain names, so a script can pick one. 'default' always exists; the rest
// are the GUI's multi-user accounts (or ones --setup --profile created).
procedure RunProfileList;
var
  n: string;
begin
  writeln('default');
  for n in ProfileNames do
    writeln(n);
end;

// A new option added here also goes in the three files under completions/.
procedure Usage;
begin
  writeln('Usage: trndi-cli [OPTION]');
  writeln('Prints the current CGM reading from the backend configured in Trndi.');
  writeln;
  writeln('  -c, --check      as above, with the range in the exit code: 5 high, 6 low');
  writeln('  -g, --graph      interactive TUI with a reading graph (F5 refreshes,');
  writeln('                   arrow keys inspect single readings, Q exits)');
  writeln(Format('  -s, --stats [H]  summarise the last H hours (default %d, max %d)',
    [STATS_DEFAULT_HOURS, STATS_MAX_HOURS]));
  writeln(Format('      --spark [H]  the last H hours as a sparkline (default %d, max %d)',
    [SPARK_DEFAULT_HOURS, SPARK_MAX_HOURS]));
  writeln('      --agp [D]    time-of-day profile of the last D days: median and');
  writeln(Format('                   percentile bands (default %d, max %d; F7 in graph mode)',
    [AGP_DEFAULT_DAYS, AGP_MAX_DAYS]));
  writeln('      --predict    graph mode: start with the forecast drawn (F6 toggles)');
  writeln('  -p, --profile N  use account N of the GUI''s multi-user mode; bare');
  writeln('                   --profile lists the accounts, --setup -p N creates one');
  writeln('      --setup      settings window: backend, address, secret, unit, limits');
  writeln('  -h, --help       show this help');
end;

function IsNumeric(const s: string): boolean;
var
  x: integer;
begin
  Result := s <> '';
  for x := 1 to Length(s) do
    if not (s[x] in ['0'..'9']) then
      exit(false);
end;

procedure BadUsage(const msg: string);
begin
  writeln(stderr, msg);
  Usage;
  halt(64);
end;

var
  i: integer;
  arg, val: string;
  eq: SizeInt;
  graphMode: boolean = false;
  statsMode: boolean = false;
  sparkMode: boolean = false;
  setupMode: boolean = false;
  checkMode: boolean = false;
  agpMode: boolean = false;
  profileMode: boolean = false;
  profileName: string = '';
  profileErr: string = '';
  statsHours: integer = STATS_DEFAULT_HOURS;
  sparkHours: integer = SPARK_DEFAULT_HOURS;
  agpDays: integer = AGP_DEFAULT_DAYS;
begin
  OnGetApplicationName := @TrndiAppName;

  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    val := '';
    eq := Pos('=', arg);
    if eq > 0 then
    begin
      val := Copy(arg, eq + 1, MaxInt);
      arg := Copy(arg, 1, eq - 1);
    end;

    case arg of
    '-g', '--graph':
      graphMode := true;
    '-s', '--stats':
    begin
      statsMode := true;
      // Both "--stats 12" and "--stats=12" set the window. A bare --stats
      // keeps the default, so only swallow a following argument that is a
      // number — anything else is the next option.
      if (val = '') and (i < ParamCount) and IsNumeric(ParamStr(i + 1)) then
      begin
        val := ParamStr(i + 1);
        Inc(i);
      end;
      if val <> '' then
        if (not IsNumeric(val)) or (not TryStrToInt(val, statsHours)) or
          (statsHours < 1) or (statsHours > STATS_MAX_HOURS) then
          BadUsage(Format('--stats takes a number of hours between 1 and %d, got "%s".',
            [STATS_MAX_HOURS, val]));
    end;
    '--spark':
    begin
      sparkMode := true;
      // The same shapes as --stats: "--spark 8", "--spark=8" or bare.
      if (val = '') and (i < ParamCount) and IsNumeric(ParamStr(i + 1)) then
      begin
        val := ParamStr(i + 1);
        Inc(i);
      end;
      if val <> '' then
        if (not IsNumeric(val)) or (not TryStrToInt(val, sparkHours)) or
          (sparkHours < 1) or (sparkHours > SPARK_MAX_HOURS) then
          BadUsage(Format('--spark takes a number of hours between 1 and %d, got "%s".',
            [SPARK_MAX_HOURS, val]));
    end;
    '--agp':
    begin
      agpMode := true;
      // The same shapes again, but the window is counted in days.
      if (val = '') and (i < ParamCount) and IsNumeric(ParamStr(i + 1)) then
      begin
        val := ParamStr(i + 1);
        Inc(i);
      end;
      if val <> '' then
        if (not IsNumeric(val)) or (not TryStrToInt(val, agpDays)) or
          (agpDays < AGP_MIN_DAYS) or (agpDays > AGP_MAX_DAYS) then
          BadUsage(Format('--agp takes a number of days between %d and %d, got "%s".',
            [AGP_MIN_DAYS, AGP_MAX_DAYS, val]));
    end;
    '-p', '--profile':
    begin
      profileMode := true;
      // "--profile Anna", "--profile=Anna" or bare, which lists the
      // accounts. A following option is never swallowed as a name —
      // account names cannot start with '-'.
      if (val = '') and (i < ParamCount) and
        (Copy(ParamStr(i + 1), 1, 1) <> '-') then
      begin
        val := ParamStr(i + 1);
        Inc(i);
      end;
      profileName := val;
    end;
    '-c', '--check':
      checkMode := true;
    '--predict':
      gPredictEnabled := true;
    '--no-predict':
      // The old default was forecast-on with this as the opt-out; accepted
      // silently so existing scripts keep working.
      gPredictEnabled := false;
    '--setup':
      setupMode := true;
    '-h', '--help':
    begin
      Usage;
      halt(0);
    end;
    else
      BadUsage('Unknown option: ' + ParamStr(i));
    end;
    Inc(i);
  end;

  if ord(graphMode) + ord(statsMode) + ord(sparkMode) + ord(agpMode) > 1 then
    BadUsage('--graph, --stats, --spark and --agp cannot be combined.');
  if setupMode and (graphMode or statsMode or sparkMode or agpMode) then
    BadUsage('--setup cannot be combined with --graph, --stats, --spark or --agp.');
  if checkMode and (graphMode or statsMode or sparkMode or agpMode or setupMode) then
    BadUsage('--check cannot be combined with --graph, --stats, --spark, --agp or --setup.');
  if profileMode and (profileName = '') and (graphMode or statsMode or
    sparkMode or agpMode or setupMode or checkMode) then
    BadUsage('A bare --profile lists the accounts; give it a name to ' +
      'combine with other options.');

  // Select the account before anything reads settings. Only --setup may name
  // a new one — everything else needs stored settings to exist, so a typo
  // fails with the list of accounts rather than an empty configuration.
  if profileMode and (profileName <> '') then
    if not ApplyProfile(profileName, setupMode, profileErr) then
    begin
      writeln(stderr, profileErr);
      halt(64);
    end;

{$IFDEF WINDOWS}
  // The reading line and the stats bars are UTF-8; the console needs telling.
  // Graph mode and the settings window are left alone — Free Vision drives the
  // console itself there.
  if not (graphMode or setupMode) then
    SetConsoleOutputCP(CP_UTF8);
{$ENDIF}

  // Listing accounts and editing settings need no backend at all.
  if profileMode and (profileName = '') then
  begin
    RunProfileList;
    halt(0);
  end;

  // Settings are all --setup needs; connecting is somebody else's problem.
  if setupMode then
  begin
    RunSetupMode;
    halt(0);
  end;

  ConnectBackend;
  try
    if graphMode then
      RunGraph
    else if statsMode then
      RunStats(statsHours)
    else if sparkMode then
      RunSpark(sparkHours)
    else if agpMode then
      RunAGP(agpDays)
    else
      RunOnce(checkMode);
  finally
    gApi.Free;
  end;
end.
