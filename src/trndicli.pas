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
  (F5 forces a refresh).

  Settings are read from the GUI's config (~/.config/Trndi.cfg on Linux), so
  a machine with a configured Trndi needs no setup.
}
program trndicli;

{$mode objfpc}{$H+}

uses
{$IFDEF UNIX}
cthreads, // MUST be first: trndi.native.async starts a worker thread; without
          // a thread driver the RTL aborts with RE 232 (uncatchable).
{$ENDIF}
SysUtils, DateUtils,
{$IFDEF WINDOWS}
registry,
{$ENDIF}
App, Objects, Drivers, Views, Menus, FVConsts,
trndi.native, trndi.native.console,
trndi.api, trndi.api.registry, trndi.types, trndi.funcs.core;

const
  cmRefresh = 1000;                   // FV user command for F5/refresh
  POLL_INTERVAL_MS = 5 * 60 * 1000;   // graph mode refetch cadence
  // Fetch more than any reasonable terminal is wide (one column per
  // reading); Draw shows the newest readings that fit the window.
  GRAPH_SPAN_MIN = 480;               // minutes of history in the graph
  GRAPH_MAX_READINGS = 480;           // covers 8 h even for 1-min uploaders

type
  {** The console native resolves settings to GetAppConfigDir + trndi.ini,
      but the GUI stores them elsewhere: on Linux via GetAppConfigFile
      (~/.config/Trndi.cfg), on Windows in HKCU\SOFTWARE\Trndi. Read the GUI's
      store on both so a configured GUI is all the setup needed;
      OnGetApplicationName makes ApplicationName = 'Trndi' regardless of this
      binary's file name. }
  TCliNative = class(TTrndiNativeConsole)
  protected
    function ResolveIniPath: string; override;
  public
{$IFDEF WINDOWS}
    function GetSetting(const keyname: string; def: string = '';
      global: boolean = false): string; override;
{$ENDIF}
  end;

var
  gApi: TrndiAPI = nil;
  gUnit: BGUnit = mmol;
  gCurrent: BGReading;
  gHaveCurrent: boolean = false;
  gStale: boolean = false;
  gReadings: BGResults = nil;
  gLastFetch: QWord = 0;
  gStatus: string = '';

function TrndiAppName: string;
begin
  Result := 'Trndi';
end;

function TCliNative.ResolveIniPath: string;
begin
  Result := GetAppConfigFile(false);
end;

{$IFDEF WINDOWS}
// The Windows GUI keeps settings in the registry, not an INI — read the same
// values (HKCU\SOFTWARE\Trndi, value names like 'remote.type').
function TCliNative.GetSetting(const keyname: string; def: string;
global: boolean): string;
var
  reg: TRegistry;
begin
  Result := def;
  reg := TRegistry.Create;
  try
    reg.RootKey := HKEY_CURRENT_USER;
    if reg.OpenKeyReadOnly('\SOFTWARE\Trndi\') then
      if reg.ValueExists(keyname) then
        Result := reg.ReadString(keyname);
  finally
    reg.Free;
  end;
end;
{$ENDIF}

{------------------------------------------------------------------------------
  Data access
 ------------------------------------------------------------------------------}

// Connect the backend stored in the GUI settings; halts with a message and
// a distinct exit code when configuration or connection fails.
procedure ConnectBackend;
var
  native: TCliNative;
  remoteType, target, creds: string;
begin
  native := TCliNative.Create;
  try
    remoteType := native.GetSetting('remote.type');
    target := native.GetSetting('remote.target');
    creds := native.GetSetting('remote.creds');
    if native.GetSetting('unit', 'mmol') = 'mmol' then
      gUnit := mmol
    else
      gUnit := mgdl;
  finally
    native.Free;
  end;

  if remoteType = '' then
  begin
{$IFDEF WINDOWS}
    writeln(stderr, 'No backend configured. Run the Trndi GUI setup first ' +
      '(no remote.type in HKCU\SOFTWARE\Trndi).');
{$ELSE}
    writeln(stderr, 'No backend configured. Run the Trndi GUI setup first ' +
      '(no remote.type in ', GetAppConfigFile(false), ').');
{$ENDIF}
    halt(1);
  end;

  gApi := CreateBackend(remoteType, target, creds);
  if gApi = nil then
  begin
    writeln(stderr, 'Unknown backend "', remoteType, '" in settings.');
    halt(2);
  end;

  if not gApi.connect then
  begin
    writeln(stderr, 'Could not connect: ', gApi.errormsg);
    halt(3);
  end;
end;

// Fetch the current reading; falls back to the last reading in a wider
// window, flagging it stale.
procedure FetchCurrent;
begin
  gHaveCurrent := gApi.getCurrent(gCurrent);
  gStale := false;
  if not gHaveCurrent then
  begin
    gHaveCurrent := gApi.getLast(gCurrent);
    gStale := gHaveCurrent;
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

// Graph mode data: history plus the current reading.
procedure FetchAll;
begin
  FetchCurrent;
  gReadings := gApi.getReadings(GRAPH_SPAN_MIN, GRAPH_MAX_READINGS);
  SortReadingsAscending(gReadings);
  gLastFetch := GetTickCount64;
  gStatus := 'updated ' + FormatDateTime('hh:nn:ss', Now);
end;

{------------------------------------------------------------------------------
  Free Vision TUI (graph mode)
 ------------------------------------------------------------------------------}

type
  PBGGraphView = ^TBGGraphView;
  TBGGraphView = object(TView)
    procedure Draw; virtual;
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

procedure TBGGraphView.Draw;
const
  attrText = $0F;   // white on black
  attrLabel = $07;  // gray on black
  chFull = #219;    // CP437 full block (video unit maps to Unicode)
  chHalf = #220;    // CP437 lower half block
  MARGIN = 8;       // room for scale labels: "  12.3 |"
var
  B: TDrawBuffer;
  y, x, i, gh, gw, halves, first: integer;
  minV, maxV, pad, v, step, band, rowTop, tick: double;
  isTick: boolean;
  lbl: string;
  attrBar: byte;
begin
  gh := Size.Y - 1; // row 0 is the header line
  gw := Size.X - MARGIN;

  // Header
  MoveChar(B, ' ', attrText, Size.X);
  lbl := ' ' + CurrentLine(false);
  if gStatus <> '' then
    lbl := lbl + '  -  ' + gStatus;
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

  // Newest readings on the right; one column per reading.
  first := Length(gReadings) - gw;
  if first < 0 then
    first := 0;

  // Scale across what is shown, padded so bars never touch the edges.
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

  for y := 1 to Size.Y - 1 do
  begin
    MoveChar(B, ' ', attrText, Size.X);

    // Does a multiple of the legend step fall inside this row's value band?
    rowTop := maxV - (y - 1) * band;
    tick := Trunc(rowTop / step) * step;
    isTick := (y > 1) and (y < Size.Y - 1) and (tick > rowTop - band);

    // Scale labels: exact bounds on the edge rows, legend steps between
    if (y = 1) or (y = Size.Y - 1) then
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

    // Bars: value mapped to half-block steps from the bottom
    for x := 0 to gw - 1 do
    begin
      i := first + x;
      if i > High(gReadings) then
        break;
      v := gReadings[i].convert(gUnit);
      attrBar := LevelAttr(gApi.getLevel(gReadings[i].convert(mgdl)));
      halves := round((v - minV) / (maxV - minV) * gh * 2);
      if halves < 1 then
        halves := 1;
      // Row y covers half-steps (gh-y)*2+1 .. (gh-y)*2+2 counted from the bottom
      if halves >= (gh - y + 1) * 2 then
        MoveChar(B[MARGIN + x], chFull, attrBar, 1)
      else if halves = (gh - y) * 2 + 1 then
        MoveChar(B[MARGIN + x], chHalf, attrBar, 1);
    end;
    WriteLine(0, y, Size.X, 1, B);
  end;
end;

constructor TBGWindow.Init(var R: TRect);
var
  IR: TRect;
  gv: PBGGraphView;
begin
  inherited Init(R, 'Trndi', wnNoNumber);
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
  StatusLine := New(PStatusLine, Init(R,
    NewStatusDef(0, $FFFF,
      NewStatusKey('~Alt-X~ Exit', kbAltX, cmQuit,
      NewStatusKey('~F5~ Refresh', kbF5, cmRefresh,
      nil)),
    nil)));
end;

procedure TTrndiTui.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evCommand) and (Event.Command = cmRefresh) then
  begin
    FetchAll;
    if GraphWin <> nil then
      GraphWin^.Redraw;
    ClearEvent(Event);
  end;
end;

procedure TTrndiTui.Idle;
begin
  inherited Idle;
  if GetTickCount64 - gLastFetch >= POLL_INTERVAL_MS then
  begin
    FetchAll;
    if GraphWin <> nil then
      GraphWin^.Redraw;
  end;
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

procedure RunOnce;
begin
  FetchCurrent;
  if not gHaveCurrent then
  begin
    writeln(stderr, 'No reading available: ', gApi.errormsg);
    halt(4);
  end;
  writeln(CurrentLine);
end;

procedure Usage;
begin
  writeln('Usage: trndi-cli [OPTION]');
  writeln('Prints the current CGM reading from the backend configured in Trndi.');
  writeln;
  writeln('  -g, --graph   interactive TUI with a reading graph (F5 refreshes)');
  writeln('  -h, --help    show this help');
end;

var
  i: integer;
  graphMode: boolean = false;
begin
  OnGetApplicationName := @TrndiAppName;

  for i := 1 to ParamCount do
    case ParamStr(i) of
    '-g', '--graph':
      graphMode := true;
    '-h', '--help':
    begin
      Usage;
      halt(0);
    end;
    else
    begin
      writeln(stderr, 'Unknown option: ', ParamStr(i));
      Usage;
      halt(64);
    end;
    end;

  ConnectBackend;
  try
    if graphMode then
      RunGraph
    else
      RunOnce;
  finally
    gApi.Free;
  end;
end.
