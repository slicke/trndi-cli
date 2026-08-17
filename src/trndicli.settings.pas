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
  Settings storage and the Free Vision settings window.

  trndi-cli shares its configuration with the Trndi GUI — the same four values
  in the same place (~/.config/Trndi.cfg on Linux, HKCU\SOFTWARE\Trndi on
  Windows), so a machine with a configured GUI needs no setup at all. This unit
  reads and writes that store, and puts a TUI window on top of it for machines
  where the GUI was never run.

  The window is used from two places: --setup, which opens it on its own
  (@link(RunSetup) brings up an FV application for the purpose), and F9 in
  graph mode, which opens it inside the already running one
  (@link(ExecSetupDialog)).
}
unit trndicli.settings;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils,
Objects, Drivers, Views, Dialogs, App, Menus, MsgBox, FVConsts, Video,
trndi.native.console, trndi.api.registry;

type
  {** The values trndi-cli shares with the GUI. }
  TCliSettings = record
    backend: string;                    // stable code, '' when unconfigured
    target: string;                     // site URL, account name or e-mail
    creds: string;                      // secret, token or password
    mmol: boolean;                      // display unit
    // User thresholds in mg/dL, 0 when not set. wizHi/wizLo back-fill
    // backends that report no limits of their own; the ovr* values apply on
    // top of whatever the backend reports, in the same way the GUI applies
    // them (umain_init.inc). The range pair is honoured but has no field in
    // the settings window.
    wizHi, wizLo: integer;
    ovrHi, ovrLo: integer;
    ovrRangeHi, ovrRangeLo: integer;
  end;

{** Where the settings live, for messages and the window's footer. }
function SettingsLocation: string;

{** Read the shared settings; backend is '' on an unconfigured machine. }
function LoadSettings: TCliSettings;

{** Write the shared settings. @param(writeCreds) false leaves the stored
    credential untouched, which is how an empty secret field is honoured. }
procedure StoreSettings(const s: TCliSettings; writeCreds: boolean);

{** Open the settings window inside a running FV application (graph mode's
    F9). True when the user saved. }
function ExecSetupDialog: boolean;

{** Open the settings window as an application of its own (--setup, and the
    offer made when no backend is configured). True when the user saved. }
function RunSetup: boolean;

{** True when stdin and stdout are both a terminal, i.e. when a TUI can be put
    on the screen and a question can be answered. A piped or redirected run
    must never end up waiting at a full-screen window nobody can see. }
function ConsoleIsInteractive: boolean;

{** True when the terminal's size no longer matches what Free Vision believes
    it is, with the video mode FV should be switched to. FV asks the terminal
    once, at startup, and never again, so a window resized under a running TUI
    leaves the layout — status line and frame included — off the screen.
    Unix only; always false elsewhere. }
function ScreenSizeChanged(out mode: TVideoMode): boolean;

{** Message boxes for callers outside this unit (graph mode reports a failed
    reconnect this way — stderr is not available with FV on the screen). }
procedure ShowInfo(const msg: string);
procedure ShowError(const msg: string);

implementation

uses
{$IFDEF WINDOWS}
registry, Windows,
{$ELSE}
BaseUnix, termio,
{$ENDIF}
trndi.api, trndi.types;

{$IFDEF WINDOWS}
type
  // The Windows unit is used here for the registry and the console handles,
  // but it also brings a TRect of its own. An implementation-section uses
  // clause wins over the interface's, so every rectangle in this unit would
  // silently become the Win32 one and fail to match Free Vision's. Point the
  // name back where it belongs.
  TRect = Objects.TRect;
{$ENDIF}

const
  cmTest = 1100;                        // "Test" button inside the dialog
  DLG_W = 68;                           // the window needs this much terminal
  DLG_H = 21;                           // ... and this many rows
  FIELD_MAX = 255;                      // TInputLine data is a shortstring

type
  {** The console native resolves settings to GetAppConfigDir + trndi.ini,
      but the GUI stores them elsewhere: on Linux via GetAppConfigFile
      (~/.config/Trndi.cfg), on Windows in HKCU\SOFTWARE\Trndi. Read and write
      the GUI's store on both so a configured GUI is all the setup needed;
      OnGetApplicationName makes ApplicationName = 'Trndi' regardless of this
      binary's file name. }
  TCliNative = class(TTrndiNativeConsole)
  protected
    function ResolveIniPath: string; override;
  public
{$IFDEF WINDOWS}
    function GetSetting(const keyname: string; def: string = '';
      global: boolean = false): string; override;
    procedure SetSetting(const keyname: string; const val: string;
      global: boolean = false); override; overload;
{$ENDIF}
  end;

var
  // The stored credential for the duration of one dialog. An empty secret
  // field means "keep this", so validation and the Test button need it, but
  // it is never put on the screen — a terminal is a poor place for a secret,
  // and a CareLink token blob would not fit an input line anyway.
  gStoredCreds: string = '';

function TCliNative.ResolveIniPath: string;
begin
  Result := GetAppConfigFile(false);
end;

{$IFDEF WINDOWS}
// The Windows GUI keeps settings in the registry, not an INI — read and write
// the same values (HKCU\SOFTWARE\Trndi, value names like 'remote.type').
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

procedure TCliNative.SetSetting(const keyname: string; const val: string;
global: boolean);
var
  reg: TRegistry;
begin
  reg := TRegistry.Create;
  try
    reg.RootKey := HKEY_CURRENT_USER;
    if reg.OpenKey('\SOFTWARE\Trndi\', true) then
      reg.WriteString(keyname, val);
  finally
    reg.Free;
  end;
end;
{$ENDIF}

{------------------------------------------------------------------------------
  Settings storage
 ------------------------------------------------------------------------------}

function SettingsLocation: string;
begin
{$IFDEF WINDOWS}
  Result := 'HKCU\SOFTWARE\Trndi';
{$ELSE}
  Result := GetAppConfigFile(false);
{$ENDIF}
end;

function LoadSettings: TCliSettings;
var
  native: TCliNative;
begin
  native := TCliNative.Create;
  try
    Result.backend := Trim(native.GetSetting('remote.type'));
    Result.target := native.GetSetting('remote.target');
    Result.creds := native.GetSetting('remote.creds');
    // Anything but 'mmol' means mg/dL, as the GUI reads it.
    Result.mmol := native.GetSetting('unit', 'mmol') = 'mmol';
    // A missing or blank key parses to 0, the "not set" value.
    Result.wizHi := StrToIntDef(native.GetSetting('wizard.hi'), 0);
    Result.wizLo := StrToIntDef(native.GetSetting('wizard.lo'), 0);
    Result.ovrHi := StrToIntDef(native.GetSetting('override.hi'), 0);
    Result.ovrLo := StrToIntDef(native.GetSetting('override.lo'), 0);
    Result.ovrRangeHi := StrToIntDef(native.GetSetting('override.rangehi'), 0);
    Result.ovrRangeLo := StrToIntDef(native.GetSetting('override.rangelo'), 0);
  finally
    native.Free;
  end;
end;

procedure StoreSettings(const s: TCliSettings; writeCreds: boolean);
var
  native: TCliNative;
begin
  native := TCliNative.Create;
  try
    native.SetSetting('remote.type', s.backend);
    native.SetSetting('remote.target', s.target);
    if writeCreds then
      native.SetSetting('remote.creds', s.creds);
    if s.mmol then
      native.SetSetting('unit', 'mmol')
    else
      native.SetSetting('unit', 'mgdl');
    // A cleared limit is written as an empty value: that reads back as "not
    // set" here, and the GUI's GetIntSetting falls back to its default on it
    // too. Only the pair the settings window edits is written; the wizard and
    // range keys stay whatever the GUI made them.
    if s.ovrHi > 0 then
      native.SetSetting('override.hi', IntToStr(s.ovrHi))
    else
      native.SetSetting('override.hi', '');
    if s.ovrLo > 0 then
      native.SetSetting('override.lo', IntToStr(s.ovrLo))
    else
      native.SetSetting('override.lo', '');
  finally
    native.Free;
  end;
end;

function ScreenSizeChanged(out mode: TVideoMode): boolean;
{$IF DEFINED(UNIX) OR DEFINED(HAIKU)}
var
  ws: TWinSize;
{$ENDIF}
begin
  Result := false;
  FillChar(mode, SizeOf(mode), 0);
{$IF DEFINED(UNIX) OR DEFINED(HAIKU)}
  if fpIOCtl(StdInputHandle, TIOCGWINSZ, @ws) <> 0 then
    exit;
  // FV addresses at most FVMaxWidth columns and keeps the width in a byte, so
  // a wider terminal already runs clipped; handing the video unit a mode it
  // would refuse is worse than leaving well alone.
  if (ws.ws_col < 20) or (ws.ws_row < 5) or (ws.ws_col > FVMaxWidth) then
    exit;
  if (ws.ws_col = ScreenWidth) and (ws.ws_row = ScreenHeight) then
    exit;
  mode := ScreenMode;
  mode.col := ws.ws_col;
  mode.row := ws.ws_row;
  Result := true;
{$ENDIF}
end;

function ConsoleIsInteractive: boolean;
begin
{$IFDEF WINDOWS}
  Result := (GetFileType(GetStdHandle(STD_INPUT_HANDLE)) = FILE_TYPE_CHAR) and
    (GetFileType(GetStdHandle(STD_OUTPUT_HANDLE)) = FILE_TYPE_CHAR);
{$ELSE}
  Result := (IsATTY(input) = 1) and (IsATTY(output) = 1);
{$ENDIF}
end;

{------------------------------------------------------------------------------
  Message boxes
 ------------------------------------------------------------------------------}

// FV formats the message through FormatStr, where '%' introduces a parameter
// that was never passed — a backend error carrying one would read as garbage
// or worse. Double them up, and keep the whole thing inside a shortstring.
function MsgSafe(const msg: string): string;
begin
  Result := StringReplace(msg, '%', '%%', [rfReplaceAll]);
  if Length(Result) > 230 then
    Result := Copy(Result, 1, 227) + '...';
end;

// A message box wide enough for a backend's own error text; the stock 40x9
// MessageBox clips those.
function ShowBox(const msg: string; options: word): word;
var
  R: TRect;
begin
  R.Assign(0, 0, 60, 11);
  R.Move((Desktop^.Size.X - R.B.X) div 2, (Desktop^.Size.Y - R.B.Y) div 2);
  Result := MessageBoxRect(R, MsgSafe(msg), nil, options);
end;

procedure ShowInfo(const msg: string);
begin
  ShowBox(msg, mfInformation + mfOKButton);
end;

procedure ShowError(const msg: string);
begin
  ShowBox(msg, mfError + mfOKButton);
end;

{------------------------------------------------------------------------------
  The settings window
 ------------------------------------------------------------------------------}

// What the address and secret fields mean for the selected backend. The
// values are named the same in settings for every backend but stand for quite
// different things, and getting that wrong is the most common way to end up
// with a connection error rather than a reading.
function BackendHint(const code: string): string;
begin
  case code of
  'API_NS', 'API_NS3':
    Result := 'Address: the Nightscout site URL. Secret: API secret or access token.';
  'API_XDRIP':
    Result := 'Address: the xDrip web service URL (port 17580). Secret: API secret.';
  'API_LLU':
    Result := 'Address: your LibreLinkUp e-mail. Secret: the account password.';
  'API_TANDEM_USA', 'API_TANDEM_EU':
    Result := 'Address: your Tandem Source e-mail. Secret: the account password.';
  'API_CARELINK_US', 'API_CARELINK_EU':
    Result := 'Address: your CareLink username. Secret: the JSON token blob - ' +
      'only the Trndi GUI can capture that one.';
  else
    Result := 'Address: your Dexcom account name. Secret: the account password.';
  end;
end;

// The limit fields are typed and shown in the display unit but stored the way
// the GUI stores them: mg/dL integers under override.hi / override.lo. 0 is
// "not set" throughout; the conversion is linear, so round-tripping through
// one decimal of mmol/L stays on the same mg/dL value.
function FormatLimit(mgdlVal: integer; asMmol: boolean): string;
var
  fs: TFormatSettings;
begin
  if mgdlVal <= 0 then
    exit('');
  if asMmol then
  begin
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    Result := FormatFloat('0.0', mgdlVal * TrndiAPI.toMMOL, fs);
  end
  else
    Result := IntToStr(mgdlVal);
end;

// '' parses to 0, "not set". False only for text that is not a number; both
// decimal separators are accepted, whatever the locale thinks.
function ParseLimit(const text: string; asMmol: boolean;
out mgdlVal: integer): boolean;
var
  s: string;
  f: double;
  fs: TFormatSettings;
begin
  mgdlVal := 0;
  Result := true;
  s := Trim(text);
  if s = '' then
    exit;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  s := StringReplace(s, ',', '.', [rfReplaceAll]);
  if (not TryStrToFloat(s, f, fs)) or (f <= 0) then
    exit(false);
  if asMmol then
    mgdlVal := round(f / TrndiAPI.toMMOL)
  else
    mgdlVal := round(f);
end;

function CredMessage(err: TBackendCredError): string;
begin
  case err of
  bceAddress:
    Result := 'The address must be a full URL, e.g. https://my.nightscout.site';
  bceEmail:
    Result := 'This backend signs in with an e-mail address, so the address ' +
      'field needs one.';
  bcePassword:
    Result := 'The password looks too short for this backend.';
  bceToken:
    Result := 'CareLink needs the JSON token blob the Trndi GUI captures, not ' +
      'a password.';
  else
    Result := '';
  end;
end;

type
  {** A button that says so when it has the focus. Free Vision marks the
      focused button by colour alone — white text instead of black on the same
      green — which is easy to miss when tabbing along a row of them. Arrows
      make it plain. The buttons are also a single row high, which drops the
      block-character shadow TButton draws under a two-row one: on a row of
      three buttons that shadow was the loudest thing in the dialog. }
  PDlgButton = ^TDlgButton;
  TDlgButton = object(TButton)
    procedure Draw; virtual;
  end;

  {** An input line that draws asterisks. The secret is never loaded into the
      field, but what the user types would otherwise stand on the screen. }
  PSecretLine = ^TSecretLine;
  TSecretLine = object(TInputLine)
    procedure Draw; virtual;
  end;

  {** PString items in registry order — TStringCollection would sort them
      alphabetically, and the registry order is the one the GUI shows. }
  PBackendColl = ^TBackendColl;
  TBackendColl = object(TUnSortedStrCollection)
  end;

  {** The backend picker, which also drives the hint line under the fields. }
  PBackendList = ^TBackendList;
  TBackendList = object(TListBox)
    HintView: PStaticText;
    destructor Done; virtual;
    procedure FocusItem(Item: Sw_Integer); virtual;
    function SelectedCode: string;
  end;

  PSetupDialog = ^TSetupDialog;
  TSetupDialog = object(TDialog)
    list: PBackendList;
    lineTarget: PInputLine;
    lineCreds: PSecretLine;
    unitBox: PRadioButtons;
    lineHi, lineLo: PInputLine;
    constructor Init(const cur: TCliSettings);
    function Valid(Command: word): boolean; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    function CredsValue: string;
    procedure TestConnection;
  end;

procedure TDlgButton.Draw;
const
  chLeft = #16;                         // CP437 ► / ◄, as Turbo Vision marks
  chRight = #17;                        // its default button
var
  B: TDrawBuffer;
  attr: byte;
begin
  inherited Draw;
  // sfSelected alone is the group's remembered choice; it only means "has the
  // focus" while the dialog itself is active.
  if (State and (sfSelected + sfActive)) <> (sfSelected + sfActive) then
    exit;
  attr := lo(GetColor($0703));          // the focused-button colour
  MoveChar(B, chLeft, attr, 1);
  WriteLine(0, 0, 1, 1, B);
  MoveChar(B, chRight, attr, 1);
  WriteLine(Size.X - 2, 0, 1, 1, B);
end;

procedure TSecretLine.Draw;
var
  saved: shortstring;
  i: integer;
begin
  // Masking in place: the buffer is only MaxLen+1 bytes, so the stars have to
  // be the same length as the text they hide.
  saved := Data^;
  for i := 1 to Length(Data^) do
    Data^[i] := '*';
  inherited Draw;
  Data^ := saved;
end;

destructor TBackendList.Done;
begin
  // TListBox does not own its collection; this one has no other owner.
  if List <> nil then
    Dispose(List, Done);
  List := nil;
  inherited Done;
end;

procedure TBackendList.FocusItem(Item: Sw_Integer);
begin
  inherited FocusItem(Item);
  // Called from SetRange during construction, before the hint exists.
  if HintView <> nil then
  begin
    DisposeStr(HintView^.Text);
    HintView^.Text := NewStr(BackendHint(SelectedCode));
    HintView^.DrawView;
  end;
end;

function TBackendList.SelectedCode: string;
begin
  if (List = nil) or (Range < 1) then
    exit('');
  Result := BackendCode(GetText(Focused, FIELD_MAX));
end;

// Put text in an input line without overrunning its MaxLen+1 byte buffer.
procedure SetLineText(line: PInputLine; const value: string);
var
  s: shortstring;
begin
  s := Copy(value, 1, line^.MaxLen);
  line^.Data^ := s;
  line^.SelectAll(true);
end;

constructor TSetupDialog.Init(const cur: TCliSettings);
var
  R: TRect;
  names: Classes.TStringList;         // Objects has a TStringList of its own
  items: PBackendColl;
  sb: PScrollBar;
  hint: PStaticText;
  i, sel: integer;
  note, loc: string;
begin
  R.Assign(0, 0, DLG_W, DLG_H);
  R.Move((Desktop^.Size.X - DLG_W) div 2, (Desktop^.Size.Y - DLG_H) div 2);
  inherited Init(R, 'Trndi settings');

  // Backend picker
  R.Assign(30, 2, 31, 10);
  sb := New(PScrollBar, Init(R));
  Insert(sb);
  R.Assign(3, 2, 30, 10);
  list := New(PBackendList, Init(R, 1, sb));
  Insert(list);
  R.Assign(3, 1, 20, 2);
  Insert(New(PLabel, Init(R, '~B~ackend', list)));

  // Address and secret
  R.Assign(34, 2, 65, 3);
  lineTarget := New(PInputLine, Init(R, FIELD_MAX));
  Insert(lineTarget);
  R.Assign(34, 1, 65, 2);
  Insert(New(PLabel, Init(R, '~A~ddress / account', lineTarget)));

  R.Assign(34, 5, 65, 6);
  lineCreds := New(PSecretLine, Init(R, FIELD_MAX));
  Insert(lineCreds);
  R.Assign(34, 4, 65, 5);
  Insert(New(PLabel, Init(R, '~S~ecret / password', lineCreds)));
  // Directly under the field, because an empty field that nevertheless
  // connects is otherwise a puzzle: the stored secret is never loaded into
  // it, and leaving it alone is how you keep that secret.
  if cur.creds <> '' then
    note := 'Stored - type to replace'
  else
    note := 'No secret stored';
  R.Assign(35, 6, 65, 7);
  Insert(New(PStaticText, Init(R, note)));

  // Unit
  R.Assign(34, 8, 65, 10);
  unitBox := New(PRadioButtons, Init(R,
    NewSItem('~m~mol/L', NewSItem('m~g~/dL', nil))));
  Insert(unitBox);
  R.Assign(34, 7, 65, 8);
  Insert(New(PLabel, Init(R, '~U~nit', unitBox)));

  // Threshold overrides, in the display unit. These write the override.hi/lo
  // keys the GUI applies too, so the two apps color by the same limits; blank
  // leaves the backend's own thresholds in charge.
  R.Assign(34, 11, 49, 12);
  lineHi := New(PInputLine, Init(R, 8));
  Insert(lineHi);
  R.Assign(34, 10, 49, 11);
  Insert(New(PLabel, Init(R, '~H~igh limit', lineHi)));

  R.Assign(50, 11, 65, 12);
  lineLo := New(PInputLine, Init(R, 8));
  Insert(lineLo);
  R.Assign(50, 10, 65, 11);
  Insert(New(PLabel, Init(R, 'Lo~w~ limit', lineLo)));

  R.Assign(35, 12, 65, 13);
  Insert(New(PStaticText, Init(R, 'Blank = the backend''s limits')));

  // Hint line: what the two fields mean for the selected backend
  R.Assign(3, 14, 65, 16);
  hint := New(PStaticText, Init(R, ''));
  Insert(hint);

  // A long path is one unbreakable word to TStaticText, which would drop it
  // rather than wrap it — keep the tail, which is the telling part.
  loc := SettingsLocation;
  if Length(loc) > 52 then
    loc := '...' + Copy(loc, Length(loc) - 48, MaxInt);
  R.Assign(3, 16, 65, 17);
  Insert(New(PStaticText, Init(R, 'Saved in ' + loc)));

  // Buttons: Test connects with the values on screen without saving them.
  // Equal widths, right edge lined up with the fields above.
  R.Assign(30, 18, 41, 19);
  Insert(New(PDlgButton, Init(R, '~O~K', cmOK, bfDefault)));
  R.Assign(42, 18, 53, 19);
  Insert(New(PDlgButton, Init(R, '~T~est', cmTest, bfNormal)));
  R.Assign(54, 18, 65, 19);
  Insert(New(PDlgButton, Init(R, '~C~ancel', cmCancel, bfNormal)));

  // Fill in the current configuration. Debug backends are left out: they
  // serve synthetic data, and picking one here would look like a real choice.
  names := Classes.TStringList.Create;
  try
    ListBackendNames(names, false);
    items := New(PBackendColl, Init(names.Count, 1));
    sel := 0;
    for i := 0 to names.Count - 1 do
    begin
      items^.Insert(NewStr(names[i]));
      if BackendCode(names[i]) = cur.backend then
        sel := i;
    end;
  finally
    names.Free;
  end;
  list^.NewList(items);
  list^.HintView := hint;
  list^.FocusItem(sel);

  SetLineText(lineTarget, cur.target);
  SetLineText(lineHi, FormatLimit(cur.ovrHi, cur.mmol));
  SetLineText(lineLo, FormatLimit(cur.ovrLo, cur.mmol));
  if cur.mmol then
    unitBox^.Value := 0
  else
    unitBox^.Value := 1;
  unitBox^.Sel := unitBox^.Value;

  SelectNext(false);
end;

function TSetupDialog.CredsValue: string;
begin
  // An empty field keeps whatever is stored, so that is what a test or a
  // credential check has to work from.
  Result := Trim(lineCreds^.Data^);
  if Result = '' then
    Result := gStoredCreds;
end;

function TSetupDialog.Valid(Command: word): boolean;
var
  addr, msg, u: string;
  asMmol: boolean;
  hiV, loV: integer;
begin
  Result := inherited Valid(Command);
  if (not Result) or (Command <> cmOK) then
    exit;

  addr := Trim(lineTarget^.Data^);
  if addr = '' then
  begin
    ShowError('The address field is empty. ' + BackendHint(list^.SelectedCode));
    exit(false);
  end;

  msg := CredMessage(CheckBackendCredentials(list^.SelectedCode, addr,
    CredsValue));
  if msg <> '' then
  begin
    ShowError(msg);
    exit(false);
  end;

  // The limits are read in whatever unit is selected right now, so a value
  // typed before switching the radio button means what the radio says on OK.
  asMmol := unitBox^.Value = 0;
  if asMmol then
    u := BG_UNIT_NAMES[mmol]
  else
    u := BG_UNIT_NAMES[mgdl];
  if (not ParseLimit(lineHi^.Data^, asMmol, hiV)) or
    (not ParseLimit(lineLo^.Data^, asMmol, loV)) then
  begin
    ShowError('The limits must be numbers in ' + u + ', or blank for the ' +
      'backend''s own.');
    exit(false);
  end;
  // 36-450 mg/dL is 2.0-25.0 mmol/L: past anything a CGM reports, the value
  // is far more likely a unit mix-up than a choice.
  if ((hiV > 0) and ((hiV < 36) or (hiV > 450))) or
    ((loV > 0) and ((loV < 36) or (loV > 450))) then
  begin
    ShowError(Format('Limits must be between %s and %s %s.',
      [FormatLimit(36, asMmol), FormatLimit(450, asMmol), u]));
    exit(false);
  end;
  if (hiV > 0) and (loV > 0) and (loV >= hiV) then
  begin
    ShowError('The low limit must be below the high limit.');
    exit(false);
  end;
end;

// Connect with what is on screen, without saving it. The backend call is
// synchronous, so the window sits still for as long as the backend takes.
procedure TSetupDialog.TestConnection;
var
  api: TrndiAPI;
  reading: BGReading;
  u: BGUnit;
begin
  api := CreateBackend(list^.SelectedCode, Trim(lineTarget^.Data^), CredsValue);
  if api = nil then
  begin
    ShowError('That backend is not known to this build.');
    exit;
  end;
  if unitBox^.Value = 0 then
    u := mmol
  else
    u := mgdl;
  try
    if not api.connect then
      ShowError('Could not connect: ' + api.errormsg)
    else if api.getCurrent(reading) then
      ShowInfo('Connected to ' + api.systemName + ' - current reading ' +
        reading.format(u, BG_MSG_DEF))
    else
      ShowInfo('Connected to ' + api.systemName +
        ', but it has no recent reading.');
  finally
    api.Free;
  end;
end;

procedure TSetupDialog.HandleEvent(var Event: TEvent);
begin
  if (Event.What = evCommand) and (Event.Command = cmTest) then
  begin
    TestConnection;
    ClearEvent(Event);
    exit;
  end;
  inherited HandleEvent(Event);
end;

{------------------------------------------------------------------------------
  Entry points
 ------------------------------------------------------------------------------}

function ExecSetupDialog: boolean;
var
  dlg: PSetupDialog;
  cur, next: TCliSettings;
begin
  Result := false;
  if (Desktop = nil) or (Desktop^.Size.X < DLG_W) or (Desktop^.Size.Y < DLG_H) then
  begin
    ShowError(Format('The settings window needs a terminal of at least %dx%d.',
      [DLG_W, DLG_H + 1]));
    exit;
  end;

  cur := LoadSettings;
  gStoredCreds := cur.creds;
  dlg := New(PSetupDialog, Init(cur));
  try
    if Desktop^.ExecView(dlg) = cmOK then
    begin
      next := cur;                      // keep what the dialog does not edit
      next.backend := dlg^.list^.SelectedCode;
      next.target := Trim(dlg^.lineTarget^.Data^);
      next.creds := Trim(dlg^.lineCreds^.Data^);
      next.mmol := dlg^.unitBox^.Value = 0;
      // Already validated by Valid; blank parses to 0, which clears the key.
      ParseLimit(dlg^.lineHi^.Data^, next.mmol, next.ovrHi);
      ParseLimit(dlg^.lineLo^.Data^, next.mmol, next.ovrLo);
      StoreSettings(next, next.creds <> '');
      Result := true;
    end;
  finally
    Dispose(dlg, Done);
    gStoredCreds := '';
  end;
end;

type
  {** A bare application to host the settings window when there is no other
      one running (--setup, and the offer made on an unconfigured machine). }
  TSetupApp = object(TApplication)
    procedure InitMenuBar; virtual;
    procedure InitStatusLine; virtual;
    procedure Idle; virtual;
  end;

procedure TSetupApp.InitMenuBar;
begin
  MenuBar := nil;
end;

procedure TSetupApp.InitStatusLine;
var
  R: TRect;
begin
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
  // Keys the dialog handles itself; the line is here to name them.
  StatusLine := New(PStatusLine, Init(R,
    NewStatusDef(0, $FFFF,
      NewStatusKey('~Tab~ Next field', kbNoKey, 0,
      NewStatusKey('~Enter~ Save', kbNoKey, 0,
      NewStatusKey('~Esc~ Cancel', kbNoKey, 0,
      nil))),
    nil)));
end;

// Follow the terminal when it is resized under the window, as graph mode does.
procedure TSetupApp.Idle;
var
  mode: TVideoMode;
begin
  inherited Idle;
  if ScreenSizeChanged(mode) then
  begin
    SetScreenVideoMode(mode);
    Redraw;
  end;
end;

function RunSetup: boolean;
var
  setupApp: TSetupApp;
begin
  setupApp.Init;
  try
    Result := ExecSetupDialog;
  finally
    setupApp.Done;
  end;
end;

end.
