{******************************************************************************

  xEdit external HTTP/JSON API server (secondary development).

  Starts a localhost-only HTTP server inside xEdit after plugins are loaded,
  so external programs can query the loaded plugin/record data and
  (in later milestones) modify records / create patches.

  Architecture:
    - A background thread accepts HTTP connections (blocking sockets).
    - Every request becomes a TwbApiJob executed on the VCL main thread
      through a TTimer pump, because all wb* element/file objects are bound
      to the main thread.
    - Responses are JSON.

  Command line switches (parsed by wbApiServerConfigureFromCmdLine):
    -api[:<port>]     enable the API server (default port 7000)
    -apitoken:<tok>   require "Authorization: Bearer <tok>" for every call
                      except GET /api/status

  M1 endpoints (read only):
    GET /api/status
    GET /api/plugins
    GET /api/plugins/(fileName)

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit wbApiServer;

{$I wbDefines.inc}

interface

uses
  System.Classes,
  System.SyncObjs,
  System.SysUtils,
  Vcl.ExtCtrls,
  wbInterface;

const
  wbApiDefaultPort   = 7000;
  wbApiVersion       = 1;
  wbApiMaxHeaderSize = 1024 * 1024;   // 1 MB upper bound for request headers
  wbApiMaxBodySize   = 32 * 1024 * 1024; // 32 MB upper bound for request body

type
  // Supplies the currently loaded plugin files (set by xeMainForm).
  TwbApiFilesProvider = reference to function: TwbFiles;
  // Creates a new plugin through the GUI (adds it to Files and the nav tree).
  TwbApiAddFileProc = reference to function(const aFileName: string;
                                            aIsLight, aIsMedium: Boolean): IwbFile;
  // Silent-save of all dirty plugins (same path as the GUI Save button).
  TwbApiSaveAllProc = reference to procedure;

  TwbApiRequest = record
    Method  : string;             // GET / POST / ...
    Path    : string;             // percent-decoded path, query removed
    RawPath : string;
    Query   : string;
    Headers : TStringList;        // "name=value", names lower-cased
    Body    : string;
  end;

  TwbApiResponse = record
    StatusCode : Integer;
    Body       : string;
  end;

  TwbApiJob = class
  public
    Request  : TwbApiRequest;
    Response : TwbApiResponse;
    Done     : TEvent;
    constructor Create;
    destructor  Destroy; override;
  end;

  TwbApiServer = class;

  TwbApiServerThread = class(TThread)
  private
    FServer : TwbApiServer;
  protected
    procedure Execute; override;
  public
    constructor Create(aServer: TwbApiServer);
  end;

  TwbApiServer = class
  private
    FFilesProvider : TwbApiFilesProvider;
    FToken         : string;
    FPort          : Word;
    FThread        : TwbApiServerThread;
    FTimer         : TTimer;
    FQueue         : TThreadList;          // of TwbApiJob
    FListenSocket  : NativeUInt;           // SOCKET of the listening socket
    FCurrentSocket : NativeUInt;           // SOCKET currently being served
    FProcessing    : Boolean;
    FStarted       : Boolean;

    procedure   TimerTick(Sender: TObject);
    procedure   ProcessJob(aJob: TwbApiJob);
    procedure   HandleRequest(aJob: TwbApiJob);

    procedure   HandleConnection(aSocket: NativeUInt);
    procedure   SendResponse(aSocket: NativeUInt; aJob: TwbApiJob);

    function    PluginToJson(const aFile: IwbFile; aIndex: Integer): string;
    function    RecordMetaJson(const aRecord: IwbMainRecord; aWithNames: Boolean): string;
    function    RecordChainJson(const aRecord: IwbMainRecord): string;
    function    FindRecordAnyFile(const aFormID: TwbFormID): IwbMainRecord;
    function    ElementToJson(const aElement: IwbElement; aDepth: Integer): string;
    function    MainRecordToJson(const aRecord: IwbMainRecord; aDepth: Integer): string;
    procedure   HandleRecordTree(aJob: TwbApiJob; const aFile: IwbFile;
                                 const aFormID: TwbFormID);
    procedure   HandleRecordValues(aJob: TwbApiJob; const aFile: IwbFile;
                                   const aFormID: TwbFormID);
    procedure   HandleFileSave(aJob: TwbApiJob; const aFile: IwbFile);
    procedure   HandleAddMasters(aJob: TwbApiJob; const aFile: IwbFile);
    function    FindTopLevelElement(const aRecord: IwbMainRecord;
                                    const aName: string): IwbElement;
    procedure   HandleCopyElements(aJob: TwbApiJob; const aFile: IwbFile;
                                   const aFormID: TwbFormID);
    procedure   HandleApiIndex(aJob: TwbApiJob);
    function    FindPlugin(const aFileName: string): IwbFile;
    procedure   HandleBatch(aJob: TwbApiJob);
    function    ResolveElement(const aElement: IwbElement; const aPath: string;
                               out aContainer: IwbContainerElementRef;
                               out aIndex: Integer): IwbElement;
    procedure   HandleMergeEffects(aJob: TwbApiJob; const aFile: IwbFile;
                                   const aFormID: TwbFormID);
    procedure   HandlePatch(aJob: TwbApiJob);
    function    RecordsPageJson(aFile: IwbFile; const aSignature, aEditorID: string;
                               aOffset, aLimit: Integer; aWithNames: Boolean;
                               out aReturned, aMore: Integer): string;
    procedure   HandlePluginRecords(aJob: TwbApiJob; const aFile: IwbFile);
    procedure   HandlePluginRecord(aJob: TwbApiJob; const aFile: IwbFile;
                                   const aFormID: TwbFormID);
    procedure   HandleGlobalRecord(aJob: TwbApiJob; const aFormID: TwbFormID);
    procedure   RespondJson(aJob: TwbApiJob; aCode: Integer; const aBody: string);
    procedure   RespondError(aJob: TwbApiJob; aCode: Integer;
                             const aCodeStr, aMessage: string);
  public
    constructor Create(aPort: Word; const aToken: string);
    destructor  Destroy; override;
    procedure   Start(aFilesProvider: TwbApiFilesProvider);   // main thread only
    procedure   Stop;                                          // main thread only
    property    Port: Word read FPort;
    property    Started: Boolean read FStarted;
  end;

// --- global entry points (called from xeInit / xeMainForm / xEdit.dpr) -----

procedure wbApiServerConfigureFromCmdLine;                    // parse -api switches
function  wbApiServerEnabled: Boolean;
procedure wbApiServerStart(const aFilesProvider: TwbApiFilesProvider); // main thread, after load
procedure wbApiServerStop;                                     // main thread, on exit
// UI-backed helpers, registered by xeMainForm after load (main thread).
procedure wbApiServerSetAddFileHandler(const aHandler: TwbApiAddFileProc);
procedure wbApiServerSetSaveAllHandler(const aHandler: TwbApiSaveAllProc);

implementation

uses
  System.StrUtils,
  System.Variants,
  Winapi.Windows,
  Winapi.WinSock2,
  JsonDataObjects,
  wbCommandLine;

var
  wbApiServerInstance      : TwbApiServer;
  wbApiServerAddFileHandler : TwbApiAddFileProc;
  wbApiServerSaveAllHandler : TwbApiSaveAllProc;

{ =========================================================================== }
{  helpers                                                                    }
{ =========================================================================== }

function wbApiJsonEscape(const aValue: string): string;
var
  i : Integer;
  c : Char;
begin
  Result := '';
  for i := 1 to Length(aValue) do begin
    c := aValue[i];
    case c of
      '"' : Result := Result + '\"';
      '\' : Result := Result + '\\';
      #8  : Result := Result + '\b';
      #9  : Result := Result + '\t';
      #10 : Result := Result + '\n';
      #12 : Result := Result + '\f';
      #13 : Result := Result + '\r';
    else
      if Ord(c) < $20 then
        Result := Result + Format('\u%.4x', [Ord(c)])
      else
        Result := Result + c;
    end;
  end;
end;

function wbApiJsonString(const aValue: string): string;
begin
  Result := '"' + wbApiJsonEscape(aValue) + '"';
end;

function wbApiJsonBool(aValue: Boolean): string;
begin
  if aValue then
    Result := 'true'
  else
    Result := 'false';
end;

function wbApiHexVal(c: Char): Integer;
begin
  case c of
    '0'..'9' : Result := Ord(c) - Ord('0');
    'a'..'f' : Result := Ord(c) - Ord('a') + 10;
    'A'..'F' : Result := Ord(c) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function wbApiUrlDecode(const aValue: string): string;

  procedure AddByte(var aBytes: TBytes; aValue: Byte);
  var
    l : Integer;
  begin
    l := Length(aBytes);
    SetLength(aBytes, l + 1);
    aBytes[l] := aValue;
  end;

var
  bytes : TBytes;
  i, l, h : Integer;
  utf8  : TBytes;
  c     : Char;
begin
  bytes := nil;
  l := Length(aValue);
  i := 1;
  while i <= l do begin
    if (aValue[i] = '%') and (i + 2 <= l) then begin
      h := (wbApiHexVal(aValue[i+1]) shl 4) or wbApiHexVal(aValue[i+2]);
      if h >= 0 then begin
        AddByte(bytes, Byte(h));
        Inc(i, 3);
        Continue;
      end;
    end;
    c := aValue[i];
    if Ord(c) <= $7F then
      AddByte(bytes, Byte(Ord(c)))
    else begin
      utf8 := TEncoding.UTF8.GetBytes(c);
      for h := Low(utf8) to High(utf8) do
        AddByte(bytes, utf8[h]);
    end;
    Inc(i);
  end;
  Result := TEncoding.UTF8.GetString(bytes);
end;

function wbApiHeaderValue(aHeaders: TStringList; const aName: string): string;
var
  i : Integer;
begin
  Result := '';
  for i := 0 to Pred(aHeaders.Count) do
    if SameText(aHeaders.Names[i], aName) then begin
      Result := aHeaders.ValueFromIndex[i];
      Exit;
    end;
end;

// index of the first #13#10#13#10 in aBuf, or -1
function wbApiFindHeaderEnd(const aBuf: TBytes): Integer;
var
  i, n : Integer;
begin
  Result := -1;
  n := Length(aBuf);
  for i := 0 to n - 4 do
    if (aBuf[i]     = 13) and (aBuf[i+1] = 10) and
       (aBuf[i+2]   = 13) and (aBuf[i+3] = 10) then begin
      Result := i;
      Exit;
    end;
end;

// parse 1..8 hex characters into a FormID value; $, 0x, # prefixes allowed
function wbApiParseFormID(const aValue: string; out aFormID: Cardinal): Boolean;
var
  i, l, digits : Integer;
  acc          : Int64;
  c            : Char;
begin
  Result := False;
  aFormID := 0;
  l := Length(aValue);
  i := 1;
  if (l >= 2) and ((aValue[1] = '$') or (aValue[1] = '#')) then
    i := 2
  else if (l >= 3) and (aValue[1] = '0') and
          ((aValue[2] = 'x') or (aValue[2] = 'X')) then
    i := 3;
  acc    := 0;
  digits := 0;
  while i <= l do begin
    c := aValue[i];
    case c of
      '0'..'9' : acc := acc * 16 + (Ord(c) - Ord('0'));
      'a'..'f' : acc := acc * 16 + (Ord(c) - Ord('a') + 10);
      'A'..'F' : acc := acc * 16 + (Ord(c) - Ord('A') + 10);
    else
      Exit(False);
    end;
    if acc > $FFFFFFFF then
      Exit(False);
    Inc(digits);
    Inc(i);
  end;
  if digits = 0 then
    Exit(False);
  aFormID := Cardinal(acc);
  Result  := True;
end;

// canonical signature string, e.g. 'ARMO' (trailing padding trimmed)
function wbApiSignatureToString(const aSignature: TwbSignature): string;
var
  tmp : AnsiString;
  i   : Integer;
begin
  SetLength(tmp, 4);
  for i := 0 to 3 do
    tmp[i + 1] := aSignature[i];
  Result := TrimRight(string(tmp));
end;

// value of one query parameter ("name=value&..."), '' when absent
function wbApiQueryParam(const aQuery, aName: string): string;
var
  pairs : TArray<string>;
  pair  : string;
  eq    : Integer;
begin
  Result := '';
  pairs := aQuery.Split(['&'], TStringSplitOptions.ExcludeEmpty);
  for pair in pairs do begin
    eq := Pos('=', pair);
    if eq > 0 then begin
      if SameText(Copy(pair, 1, eq - 1), aName) then begin
        Result := wbApiUrlDecode(Copy(pair, eq + 1, MaxInt));
        Exit;
      end;
    end;
  end;
end;

{ =========================================================================== }
{  TwbApiJob                                                                  }
{ =========================================================================== }

constructor TwbApiJob.Create;
begin
  inherited Create;
  Done := TEvent.Create(nil, True, False, '');
  Request.Headers := TStringList.Create;
  Request.Headers.NameValueSeparator := '=';
  Response.StatusCode := 500;
end;

destructor TwbApiJob.Destroy;
begin
  Request.Headers.Free;
  Done.Free;
  inherited Destroy;
end;

{ =========================================================================== }
{  TwbApiServerThread                                                         }
{ =========================================================================== }

constructor TwbApiServerThread.Create(aServer: TwbApiServer);
begin
  inherited Create(True);
  FServer := aServer;
  FreeOnTerminate := False;
end;

procedure TwbApiServerThread.Execute;
var
  wsadata : TWSADATA;
  s       : TSocket;
  Client  : TSocket;
  sin     : TSockAddrIn;
  la      : TSockAddrIn;
  lalen   : Integer;
begin
  if WSAStartup($0202, wsadata) <> 0 then
    Exit;
  try
    s := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if s = INVALID_SOCKET then
      Exit;
    FServer.FListenSocket := NativeUInt(s);
    try
      FillChar(sin, SizeOf(sin), 0);
      sin.sin_family      := AF_INET;
      sin.sin_addr.S_addr := inet_addr('127.0.0.1');
      sin.sin_port        := htons(FServer.FPort);
      if bind(s, PSockAddr(@sin)^, SizeOf(sin)) = SOCKET_ERROR then
        Exit;
      if listen(s, 16) = SOCKET_ERROR then
        Exit;

      while not Terminated do begin
        FillChar(la, SizeOf(la), 0);
        lalen := SizeOf(la);
        Client := accept(s, PSockAddr(@la), @lalen);
        if Client = INVALID_SOCKET then
          Continue;              // socket was closed by Stop() to wake us up
        FServer.FCurrentSocket := NativeUInt(Client);
        try
          FServer.HandleConnection(NativeUInt(Client));
        finally
          FServer.FCurrentSocket := 0;
        end;
        closesocket(Client);
      end;
    finally
      closesocket(s);
      FServer.FListenSocket := 0;
    end;
  finally
    WSACleanup;
  end;
end;

{ =========================================================================== }
{  TwbApiServer                                                               }
{ =========================================================================== }

constructor TwbApiServer.Create(aPort: Word; const aToken: string);
begin
  inherited Create;
  FPort  := aPort;
  FToken := aToken;
  FQueue := TThreadList.Create;
end;

destructor TwbApiServer.Destroy;
begin
  Stop;
  FQueue.Free;
  inherited Destroy;
end;

procedure TwbApiServer.Start(aFilesProvider: TwbApiFilesProvider);
begin
  if FStarted then
    Exit;
  FStarted       := True;
  FFilesProvider := aFilesProvider;

  FTimer := TTimer.Create(nil);
  FTimer.Interval := 20;
  FTimer.OnTimer  := TimerTick;

  FThread := TwbApiServerThread.Create(Self);
  FThread.Start;
end;

procedure TwbApiServer.Stop;
var
  list : TList;
  i    : Integer;
  job  : TwbApiJob;
begin
  if Assigned(FTimer) then begin
    FTimer.Enabled := False;
    FreeAndNil(FTimer);
  end;

  if Assigned(FThread) then begin
    FThread.Terminate;

    if FListenSocket <> 0 then begin
      closesocket(TSocket(FListenSocket));
      FListenSocket := 0;
    end;
    if FCurrentSocket <> 0 then begin
      closesocket(TSocket(FCurrentSocket));
      FCurrentSocket := 0;
    end;

    // wake up any job the server threads may be waiting on
    list := FQueue.LockList;
    try
      for i := 0 to Pred(list.Count) do begin
        job := TwbApiJob(list[i]);
        job.Response.StatusCode := 503;
        job.Response.Body := '{"ok":false,"error":{"code":"shutting_down","message":"xEdit is shutting down"}}';
        job.Done.SetEvent;
      end;
      list.Clear;
    finally
      FQueue.UnlockList;
    end;

    // the sockets above were closed and queued jobs signalled, so the worker
    // thread exits promptly; wait for it (no timeout overload on all versions)
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;

  FFilesProvider := nil;
  FStarted       := False;
end;

procedure TwbApiServer.TimerTick(Sender: TObject);
var
  list : TList;
  jobs : array of TwbApiJob;
  i, n : Integer;
begin
  if FProcessing then
    Exit;

  list := FQueue.LockList;
  try
    n := list.Count;
    if n = 0 then
      Exit;
    SetLength(jobs, n);
    for i := 0 to Pred(n) do
      jobs[i] := TwbApiJob(list[i]);
    list.Clear;
  finally
    FQueue.UnlockList;
  end;

  for i := 0 to Pred(n) do
    ProcessJob(jobs[i]);
end;

procedure TwbApiServer.ProcessJob(aJob: TwbApiJob);
begin
  FProcessing := True;
  try
    try
      HandleRequest(aJob);
    except
      on E: Exception do
        RespondError(aJob, 500, 'internal_error', E.Message);
    end;
  finally
    FProcessing := False;
    aJob.Done.SetEvent;
  end;
end;

procedure TwbApiServer.RespondJson(aJob: TwbApiJob; aCode: Integer; const aBody: string);
begin
  aJob.Response.StatusCode := aCode;
  aJob.Response.Body       := aBody;
end;

procedure TwbApiServer.RespondError(aJob: TwbApiJob; aCode: Integer;
                                    const aCodeStr, aMessage: string);
begin
  RespondJson(aJob, aCode,
    '{"ok":false,"error":{"code":' + wbApiJsonString(aCodeStr) +
    ',"message":' + wbApiJsonString(aMessage) + '}}');
end;

{ ---------------- request handling on the main thread ---------------------- }

procedure TwbApiServer.HandleRequest(aJob: TwbApiJob);
var
  sb     : TStringBuilder;
  files  : TwbFiles;
  f      : IwbFile;
  i, j   : Integer;
  n      : Integer;
  fc     : Integer;
  parts  : TArray<string>;
  p      : string;
begin
  if not wbLoaderDone then begin
    RespondError(aJob, 503, 'not_loaded', 'Plugins are still loading');
    Exit;
  end;

  if not ((aJob.Request.Method = 'GET') or (aJob.Request.Method = 'POST')) then begin
    RespondError(aJob, 405, 'method_not_allowed', 'Only GET and POST are supported');
    Exit;
  end;

  p := aJob.Request.Path;
  if p = '/api' then begin
    HandleApiIndex(aJob);
    Exit;
  end;
  if not p.StartsWith('/api/') then begin
    RespondError(aJob, 404, 'not_found', 'Unknown endpoint: ' + aJob.Request.Path);
    Exit;
  end;

  parts := Copy(p, 6, MaxInt).Split(['/'], TStringSplitOptions.ExcludeEmpty);
  n := Length(parts);
  if n < 1 then begin
    RespondError(aJob, 404, 'not_found', 'Unknown endpoint: ' + aJob.Request.Path);
    Exit;
  end;

  sb := TStringBuilder.Create;
  try
    if parts[0] = 'status' then begin
      sb.Append('{"ok":true,"apiVersion":').Append(wbApiVersion);
      sb.Append(',"pid":').Append(GetCurrentProcessId);
      sb.Append(',"title":').Append(wbApiJsonString(wbApplicationTitle));
      sb.Append(',"gameMode":').Append(Ord(wbGameMode));
      sb.Append(',"toolMode":').Append(Ord(wbToolMode));
      sb.Append(',"pluginsLoaded":').Append(wbApiJsonBool(wbLoaderDone));
      sb.Append(',"busy":').Append(wbApiJsonBool(FProcessing));
      sb.Append(',"port":').Append(FPort);
      sb.Append('}');
      RespondJson(aJob, 200, sb.ToString);
      Exit;
    end;

    if parts[0] = 'plugins' then begin
      if not Assigned(FFilesProvider) then begin
        RespondError(aJob, 500, 'no_provider', 'Plugin list provider is not registered');
        Exit;
      end;
      files := Copy(FFilesProvider(), 0, MaxInt); // copy: never mutate frmMain.Files storage
      fc    := Length(files);

      // find the plugin named parts[1], if the path has one
      f := nil;
      if n >= 2 then
        for i := 0 to Pred(fc) do
          if SameText(files[i].FileName, parts[1]) then begin
            f := files[i];
            Break;
          end;

      if n >= 3 then begin
        // sub-resources under a plugin: /api/plugins/{file}/...
        if f = nil then begin
          RespondError(aJob, 404, 'not_found', 'Plugin not loaded: ' + parts[1]);
          Exit;
        end;
        if (n = 3) and (parts[2] = 'records') then begin
          HandlePluginRecords(aJob, f);
          Exit;
        end;
        if (n = 3) and (parts[2] = 'save') then begin
          HandleFileSave(aJob, f);
          Exit;
        end;
        if (n = 3) and (parts[2] = 'addmasters') then begin
          HandleAddMasters(aJob, f);
          Exit;
        end;
    if (n = 4) and (parts[2] = 'records') then begin
          var fid: Cardinal;
          if not wbApiParseFormID(parts[3], fid) then begin
            RespondError(aJob, 400, 'bad_formid', 'Invalid FormID: ' + parts[3]);
            Exit;
          end;
          HandlePluginRecord(aJob, f, TwbFormID.FromCardinal(fid));
          Exit;
        end;
        if (n = 5) and (parts[2] = 'records') then begin
          // /api/plugins/{file}/records/{formid}/tree  or  /values
          var fid: Cardinal;
          if not wbApiParseFormID(parts[3], fid) then begin
            RespondError(aJob, 400, 'bad_formid', 'Invalid FormID: ' + parts[3]);
            Exit;
          end;
          if parts[4] = 'tree' then begin
            HandleRecordTree(aJob, f, TwbFormID.FromCardinal(fid));
            Exit;
          end;
          if parts[4] = 'values' then begin
            HandleRecordValues(aJob, f, TwbFormID.FromCardinal(fid));
            Exit;
          end;
          if parts[4] = 'copy-elements' then begin
            HandleCopyElements(aJob, f, TwbFormID.FromCardinal(fid));
            Exit;
          end;
          if parts[4] = 'merge-effects' then begin
            HandleMergeEffects(aJob, f, TwbFormID.FromCardinal(fid));
            Exit;
          end;
          RespondError(aJob, 404, 'not_found', 'Unknown endpoint: ' + aJob.Request.Path);
          Exit;
        end;
        RespondError(aJob, 404, 'not_found', 'Unknown endpoint: ' + aJob.Request.Path);
        Exit;
      end;

      if n = 2 then begin
        // /api/plugins/{fileName}
        if f <> nil then
          RespondJson(aJob, 200, PluginToJson(f, 0))
        else
          RespondError(aJob, 404, 'not_found', 'Plugin not loaded: ' + parts[1]);
        Exit;
      end;

      // /api/plugins -> full list, sorted by load order
      for i := 1 to Pred(fc) do begin
        f := files[i];
        j := i;
        while (j > 0) and (files[j-1].LoadOrder > f.LoadOrder) do begin
          files[j] := files[j-1];
          Dec(j);
        end;
        files[j] := f;
      end;

      sb.Append('{"ok":true,"count":').Append(fc);
      sb.Append(',"plugins":[');
      for i := 0 to Pred(fc) do begin
        if i > 0 then
          sb.Append(',');
        sb.Append(PluginToJson(files[i], i));
      end;
      sb.Append(']}');
      RespondJson(aJob, 200, sb.ToString);
      Exit;
    end;

    if parts[0] = 'records' then begin
      // /api/records/{loadOrderFormID} - resolve a record across all files
      if n <> 2 then begin
        RespondError(aJob, 404, 'not_found', 'Unknown endpoint: ' + aJob.Request.Path);
        Exit;
      end;
      var fid: Cardinal;
      if not wbApiParseFormID(parts[1], fid) then begin
        RespondError(aJob, 400, 'bad_formid', 'Invalid FormID: ' + parts[1]);
        Exit;
      end;
      HandleGlobalRecord(aJob, TwbFormID.FromCardinal(fid));
      Exit;
    end;

    if (parts[0] = 'patch') and (n = 1) then begin
      HandlePatch(aJob);
      Exit;
    end;

    if (parts[0] = 'batch') and (n = 1) then begin
      HandleBatch(aJob);
      Exit;
    end;

    RespondError(aJob, 404, 'not_found', 'Unknown endpoint: ' + aJob.Request.Path);
  finally
    sb.Free;
  end;
end;

function TwbApiServer.PluginToJson(const aFile: IwbFile; aIndex: Integer): string;

  procedure AppendMasters(aSB: TStringBuilder; const aProp: string;
                          aCount: Integer;
                          aGet: TFunc<Integer, IwbFile>);
  var
    j : Integer;
  begin
    aSB.Append(',').Append(wbApiJsonString(aProp)).Append(':[');
    for j := 0 to Pred(aCount) do begin
      if j > 0 then
        aSB.Append(',');
      aSB.Append(wbApiJsonString(aGet(j).FileName));
    end;
    aSB.Append(']');
  end;

var
  sb : TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append('{');
    sb.Append('"index":').Append(aIndex);
    sb.Append(',"fileName":').Append(wbApiJsonString(aFile.FileName));
    sb.Append(',"fileID":').Append(wbApiJsonString(aFile.LoadOrderFileID.ToString));
    sb.Append(',"loadOrder":').Append(aFile.LoadOrder);
    sb.Append(',"isESM":').Append(wbApiJsonBool(aFile.IsESM));
    sb.Append(',"isLight":').Append(wbApiJsonBool(aFile.IsLight));
    sb.Append(',"isMedium":').Append(wbApiJsonBool(aFile.IsMedium));
    sb.Append(',"isUpdate":').Append(wbApiJsonBool(aFile.IsUpdate));
    sb.Append(',"isBlueprint":').Append(wbApiJsonBool(aFile.IsBlueprint));
    sb.Append(',"isLocalized":').Append(wbApiJsonBool(aFile.IsLocalized));
    sb.Append(',"isNotPlugin":').Append(wbApiJsonBool(aFile.IsNotPlugin));
    sb.Append(',"masterCount":').Append(aFile.MasterCount[False]);
    AppendMasters(sb, 'masters', aFile.MasterCount[False],
      function(j: Integer): IwbFile
      begin
        Result := aFile.Masters[j, False];
      end);
    sb.Append(',"fullMasterCount":').Append(aFile.FullMasterCount[False]);
    AppendMasters(sb, 'fullMasters', aFile.FullMasterCount[False],
      function(j: Integer): IwbFile
      begin
        Result := aFile.FullMasters[j, False];
      end);
    sb.Append(',"mediumMasterCount":').Append(aFile.MediumMasterCount[False]);
    AppendMasters(sb, 'mediumMasters', aFile.MediumMasterCount[False],
      function(j: Integer): IwbFile
      begin
        Result := aFile.MediumMasters[j, False];
      end);
    sb.Append(',"lightMasterCount":').Append(aFile.LightMasterCount[False]);
    AppendMasters(sb, 'lightMasters', aFile.LightMasterCount[False],
      function(j: Integer): IwbFile
      begin
        Result := aFile.LightMasters[j, False];
      end);
    sb.Append('}');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ------------------- record level JSON (M2) ------------------------------- }

function TwbApiServer.RecordMetaJson(const aRecord: IwbMainRecord; aWithNames: Boolean): string;
var
  sb : TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append('{');
    sb.Append('"containingFile":').Append(wbApiJsonString(aRecord._File.FileName));
    sb.Append(',"signature":').Append(wbApiJsonString(wbApiSignatureToString(aRecord.Signature)));
    sb.Append(',"formID":').Append(wbApiJsonString(IntToHex(aRecord.FormID.ToCardinal, 8)));
    sb.Append(',"loadOrderFormID":').Append(wbApiJsonString(IntToHex(aRecord.LoadOrderFormID.ToCardinal, 8)));
    if aWithNames then begin
      sb.Append(',"editorID":').Append(wbApiJsonString(aRecord.EditorID));
      sb.Append(',"fullName":').Append(wbApiJsonString(aRecord.FullName));
    end;
    sb.Append(',"isMaster":').Append(wbApiJsonBool(aRecord.IsMaster));
    sb.Append(',"isWinningOverride":').Append(wbApiJsonBool(aRecord.IsWinningOverride));
    sb.Append(',"isDeleted":').Append(wbApiJsonBool(aRecord.IsDeleted));
    sb.Append(',"isPersistent":').Append(wbApiJsonBool(aRecord.IsPersistent));
    sb.Append('}');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TwbApiServer.RecordChainJson(const aRecord: IwbMainRecord): string;
var
  sb     : TStringBuilder;
  master : IwbMainRecord;
  ovr    : IwbMainRecord;
  m      : IwbMainRecord;
  k, cnt : Integer;
begin
  master := aRecord;
  if not master.IsMaster then begin
    m := master.Master;
    if m <> nil then
      master := m;
  end;

  sb := TStringBuilder.Create;
  try
    cnt := master.OverrideCount;
    sb.Append('{"ok":true,"requested":').Append(RecordMetaJson(aRecord, True));
    sb.Append(',"master":').Append(RecordMetaJson(master, True));
    sb.Append(',"overrideCount":').Append(cnt);
    sb.Append(',"overrides":[');
    for k := 0 to Pred(cnt) do begin
      if k > 0 then
        sb.Append(',');
      ovr := master.Overrides[k];
      sb.Append(RecordMetaJson(ovr, False));
    end;
    sb.Append('],"winningOverride":');
    ovr := master.WinningOverride;
    if ovr <> nil then
      sb.Append(RecordMetaJson(ovr, False))
    else
      sb.Append('null');
    sb.Append('}');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function TwbApiServer.RecordsPageJson(aFile: IwbFile; const aSignature, aEditorID: string;
                                      aOffset, aLimit: Integer; aWithNames: Boolean;
                                      out aReturned, aMore: Integer): string;
var
  sb        : TStringBuilder;
  el, el2   : IwbElement;
  grp       : IwbGroupRecord;
  rec       : IwbMainRecord;
  i, j      : Integer;
  seen      : Integer;
  wantName  : Boolean;
begin
  aReturned := 0;
  aMore     := 0;
  seen      := 0;
  wantName  := aWithNames or (aEditorID <> '');
  sb := TStringBuilder.Create;
  try
    for i := 0 to Pred(aFile.ElementCount) do begin
      el := aFile.Elements[i];
      if not Supports(el, IwbGroupRecord, grp) then
        Continue;

      for j := 0 to Pred(grp.ElementCount) do begin
        el2 := grp.Elements[j];
        if not Supports(el2, IwbMainRecord, rec) then
          Continue;

        if (aSignature <> '') and
           not SameText(aSignature, wbApiSignatureToString(rec.Signature)) then
          Continue;
        if (aEditorID <> '') and not ContainsText(rec.EditorID, aEditorID) then
          Continue;

        if seen >= aOffset then begin
          if aReturned < aLimit then begin
            if aReturned > 0 then
              sb.Append(',');
            sb.Append(RecordMetaJson(rec, wantName));
            Inc(aReturned);
          end else begin
            aMore := 1;          // more matches exist past this page
            Break;
          end;
        end;
        Inc(seen);
      end;
      if aMore <> 0 then
        Break;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure TwbApiServer.HandlePluginRecords(aJob: TwbApiJob; const aFile: IwbFile);
var
  q        : string;
  sig, edid: string;
  offset   : Integer;
  limit    : Integer;
  withName : Boolean;
  returned : Integer;
  more     : Integer;
  arr      : string;
begin
  q := aJob.Request.Query;
  sig := UpperCase(Trim(wbApiQueryParam(q, 'signature')));
  edid := wbApiQueryParam(q, 'editorID');
  offset := StrToIntDef(wbApiQueryParam(q, 'offset'), 0);
  if offset < 0 then
    offset := 0;
  limit := StrToIntDef(wbApiQueryParam(q, 'limit'), 100);
  if limit < 1 then
    limit := 1;
  if limit > 500 then
    limit := 500;
  withName := (wbApiQueryParam(q, 'names') = '1') or SameText(wbApiQueryParam(q, 'names'), 'true');

  arr := RecordsPageJson(aFile, sig, edid, offset, limit, withName, returned, more);

  RespondJson(aJob, 200,
    '{"ok":true,"plugin":' + wbApiJsonString(aFile.FileName) +
    ',"signatureFilter":' + wbApiJsonString(sig) +
    ',"returned":' + IntToStr(returned) +
    ',"hasMore":' + wbApiJsonBool(more > 0) +
    ',"records":[' + arr + ']}');
end;

procedure TwbApiServer.HandlePluginRecord(aJob: TwbApiJob; const aFile: IwbFile;
                                          const aFormID: TwbFormID);
var
  rec : IwbMainRecord;
begin
  rec := aFile.ContainedRecordByLoadOrderFormID[aFormID, True];
  if rec = nil then begin
    RespondError(aJob, 404, 'not_found',
      'Record not found in ' + aFile.FileName + ': ' + IntToHex(aFormID.ToCardinal, 8));
    Exit;
  end;
  RespondJson(aJob, 200, RecordChainJson(rec));
end;

function TwbApiServer.ElementToJson(const aElement: IwbElement; aDepth: Integer): string;
var
  sb     : TStringBuilder;
  cef    : IwbContainerElementRef;
  c      : IwbContainerBase;
  i, cnt : Integer;
  v      : string;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append('{"name":').Append(wbApiJsonString(aElement.Name));
    sb.Append(',"path":').Append(wbApiJsonString(aElement.Path));

    cnt := -1;
    if Supports(aElement, IwbContainerElementRef, cef) then
      cnt := cef.ElementCount
    else if Supports(aElement, IwbContainerBase, c) then
      cnt := c.ElementCount;

    if (aDepth > 0) and (cnt > 0) then begin
      sb.Append(',"children":[');
      for i := 0 to Pred(cnt) do begin
        if i > 0 then
          sb.Append(',');
        if Supports(aElement, IwbContainerElementRef, cef) then
          sb.Append(ElementToJson(cef.Elements[i], aDepth - 1))
        else
          sb.Append(ElementToJson(c.Elements[i], aDepth - 1));
      end;
      sb.Append(']');
    end else begin
      // leaf (or container that could not enumerate children): expose its value
      try
        v := aElement.Value;
      except
        v := '';
      end;
      sb.Append(',"value":').Append(wbApiJsonString(v));
    end;
    sb.Append('}');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure TwbApiServer.HandleRecordTree(aJob: TwbApiJob; const aFile: IwbFile;
                                        const aFormID: TwbFormID);
var
  rec   : IwbMainRecord;
  depth : Integer;
  q     : string;
begin
  rec := aFile.ContainedRecordByLoadOrderFormID[aFormID, True];
  if rec = nil then begin
    RespondError(aJob, 404, 'not_found',
      'Record not found in ' + aFile.FileName + ': ' + IntToHex(aFormID.ToCardinal, 8));
    Exit;
  end;

  q := wbApiQueryParam(aJob.Request.Query, 'depth');
  depth := StrToIntDef(q, 8);
  if depth < 1 then
    depth := 1;
  if depth > 20 then
    depth := 20;

  RespondJson(aJob, 200,
    '{"ok":true,"plugin":' + wbApiJsonString(aFile.FileName) +
    ',"loadOrderFormID":' + wbApiJsonString(IntToHex(aFormID.ToCardinal, 8)) +
    ',"depth":' + IntToStr(depth) +
    ',"tree":' + MainRecordToJson(rec, depth) + '}');
end;

// Root node of a record tree. The main record's container methods are used
// through its declared interface chain (static upcast), which avoids runtime
// Supports/QueryInterface quirks on the record root object.
function TwbApiServer.MainRecordToJson(const aRecord: IwbMainRecord; aDepth: Integer): string;
var
  sb : TStringBuilder;
  cb : IwbContainerBase;
  i  : Integer;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append('{"name":').Append(wbApiJsonString(aRecord.Name));
    sb.Append(',"path":').Append(wbApiJsonString(aRecord.Path));
    if aDepth > 0 then begin
      cb := aRecord; // static upcast: IwbMainRecord inherits IwbContainerBase
      sb.Append(',"children":[');
      for i := 0 to Pred(cb.ElementCount) do begin
        if i > 0 then
          sb.Append(',');
        sb.Append(ElementToJson(cb.Elements[i], aDepth - 1));
      end;
      sb.Append(']');
    end else
      sb.Append(',"value":').Append(wbApiJsonString(''));
    sb.Append('}');
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure TwbApiServer.HandleRecordValues(aJob: TwbApiJob; const aFile: IwbFile;
                                          const aFormID: TwbFormID);
var
  rec    : IwbMainRecord;
  jo     : TJsonObject;
  vals   : TJsonObject;
  target : IwbElement;
  sb     : TStringBuilder;
  i, changed, failed : Integer;
  name, val, err : string;
  okBody : Boolean;
begin
  if aJob.Request.Method <> 'POST' then begin
    RespondError(aJob, 405, 'method_not_allowed', 'This endpoint requires POST');
    Exit;
  end;
  if aJob.Request.Body = '' then begin
    RespondError(aJob, 400, 'bad_request', 'Request body must contain {"values": { "path": "value", ... }}');
    Exit;
  end;

  rec := aFile.ContainedRecordByLoadOrderFormID[aFormID, True];
  if rec = nil then begin
    RespondError(aJob, 404, 'not_found',
      'Record not found in ' + aFile.FileName + ': ' + IntToHex(aFormID.ToCardinal, 8));
    Exit;
  end;
  if not rec.IsEditable then begin
    RespondError(aJob, 403, 'read_only',
      'Record is not editable (masters / protected records cannot be changed)');
    Exit;
  end;

  jo := nil;
  try
    try
      jo := TJsonObject(TJsonObject.Parse(aJob.Request.Body));
    except
      jo := nil;
    end;
    if jo = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Body is not valid JSON');
      Exit;
    end;
    vals := jo.O['values'];
    if vals = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Missing "values" object in body');
      Exit;
    end;

    changed := 0;
    failed  := 0;
    sb := TStringBuilder.Create;
    try
      for i := 0 to Pred(vals.Count) do begin
        name := vals.Names[i];
        try
          val := VarToStr(vals[name]);
        except
          val := '';
        end;
        err := '';
        try
          target := rec.ElementByPath[name];
          if target = nil then
            err := 'path not found'
          else if not target.IsEditable then
            err := 'element is not editable'
          else begin
            target.EditValue := val;
            Inc(changed);
          end;
        except
          on E: Exception do
            err := E.Message;
        end;

        if i > 0 then
          sb.Append(',');
        if err = '' then
          sb.Append('{"path":').Append(wbApiJsonString(name)).Append(',"ok":true}')
        else begin
          Inc(failed);
          sb.Append('{"path":').Append(wbApiJsonString(name))
            .Append(',"ok":false,"error":').Append(wbApiJsonString(err)).Append('}');
        end;
      end;
      okBody := (failed = 0);
      RespondJson(aJob, 200,
        '{"ok":' + wbApiJsonBool(okBody) +
        ',"changed":' + IntToStr(changed) +
        ',"failed":' + IntToStr(failed) +
        ',"results":[' + sb.ToString + ']}');
    finally
      sb.Free;
    end;
  finally
    jo.Free;
  end;
end;

procedure TwbApiServer.HandleGlobalRecord(aJob: TwbApiJob; const aFormID: TwbFormID);
var
  files : TwbFiles;
  f     : IwbFile;
  rec   : IwbMainRecord;
  i, j, fc : Integer;
begin
  if not Assigned(FFilesProvider) then begin
    RespondError(aJob, 500, 'no_provider', 'Plugin list provider is not registered');
    Exit;
  end;
  files := Copy(FFilesProvider(), 0, MaxInt);

  // sort by load order (ascending) so the first hit is the master instance
  fc := Length(files);
  for i := 1 to Pred(fc) do begin
    f := files[i];
    j := i;
    while (j > 0) and (files[j-1].LoadOrder > f.LoadOrder) do begin
      files[j] := files[j-1];
      Dec(j);
    end;
    files[j] := f;
  end;

  for f in files do begin
    rec := f.ContainedRecordByLoadOrderFormID[aFormID, True];
    if rec <> nil then begin
      RespondJson(aJob, 200, RecordChainJson(rec));
      Exit;
    end;
  end;

  RespondError(aJob, 404, 'not_found',
    'Record not found in the load order: ' + IntToHex(aFormID.ToCardinal, 8));
end;

{ ---------------- socket level code (server thread) ------------------------ }

procedure TwbApiServer.HandleConnection(aSocket: NativeUInt);
var
  sock     : TSocket;
  buf      : TBytes;
  chunk    : array [0..4095] of Byte;
  n, i     : Integer;
  he       : Integer;
  s, line  : string;
  sl       : TStringList;
  job      : TwbApiJob;
  target   : string;
  sp       : Integer;
  cl       : Integer;
  hdr      : string;
begin
  sock := TSocket(aSocket);
  buf  := nil;
  he   := -1;

  // read until the header terminator or the size limit
  while Length(buf) < wbApiMaxHeaderSize do begin
    n := recv(sock, chunk, SizeOf(chunk), 0);
    if n <= 0 then
      Exit;
    i := Length(buf);
    SetLength(buf, i + n);
    Move(chunk, buf[i], n);
    he := wbApiFindHeaderEnd(buf);
    if he >= 0 then
      Break;
  end;
  if he < 0 then begin
    // no header terminator within the size limit: reply and close
    if Length(buf) >= wbApiMaxHeaderSize then begin
      job := TwbApiJob.Create;
      try
        job.Response.StatusCode := 400;
        job.Response.Body := '{"ok":false,"error":{"code":"bad_request","message":"Request headers too large"}}';
        SendResponse(sock, job);
      finally
        job.Free;
      end;
    end;
    Exit;                       // no proper request received
  end;

  job := TwbApiJob.Create;
  try
    try
      s := TEncoding.ASCII.GetString(buf, 0, he + 4);
      sl := TStringList.Create;
      try
        sl.Text := s;
        if sl.Count = 0 then begin
          job.Response.StatusCode := 400;
          job.Response.Body := '{"ok":false,"error":{"code":"bad_request","message":"Empty request"}}';
          SendResponse(sock, job);
          Exit;
        end;

        // request line: METHOD SP TARGET SP HTTP/x.y
        line := sl[0];
        sp := Pos(' ', line);
        if sp > 0 then begin
          job.Request.Method := Copy(line, 1, sp - 1);
          target := Trim(Copy(line, sp + 1, MaxInt));
        end else
          target := '';
        sp := Pos(' ', target);
        if sp > 0 then
          target := Copy(target, 1, sp - 1);
        job.Request.RawPath := target;
        sp := Pos('?', target);
        if sp > 0 then begin
          job.Request.Query := Copy(target, sp + 1, MaxInt);
          target := Copy(target, 1, sp - 1);
        end;
        job.Request.Path := wbApiUrlDecode(target);

        for i := 1 to Pred(sl.Count) do begin
          line := sl[i];
          sp := Pos(':', line);
          if sp > 0 then
            job.Request.Headers.Add(
              LowerCase(Trim(Copy(line, 1, sp - 1))) + '=' +
              Trim(Copy(line, sp + 1, MaxInt)));
        end;
      finally
        sl.Free;
      end;

      // body (later milestones use JSON request bodies)
      hdr := wbApiHeaderValue(job.Request.Headers, 'content-length');
      cl := StrToIntDef(hdr, 0);
      if cl < 0 then
        cl := 0;
      if cl > wbApiMaxBodySize then begin
        job.Response.StatusCode := 413;
        job.Response.Body := '{"ok":false,"error":{"code":"payload_too_large","message":"Request body too large"}}';
        SendResponse(sock, job);
        Exit;
      end;
      if cl > 0 then begin
        var bodyStart := he + 4;
        var have := Length(buf) - bodyStart;
        if have < 0 then
          have := 0;
        if have > cl then
          have := cl;
        var bodyBuf: TBytes;
        SetLength(bodyBuf, have);
        if have > 0 then
          Move(buf[bodyStart], bodyBuf[0], have);
        while Length(bodyBuf) < cl do begin
          var oldLen := Length(bodyBuf);
          SetLength(bodyBuf, oldLen + 4096);
          var got := recv(sock, bodyBuf[oldLen], Length(bodyBuf) - oldLen, 0);
          if got <= 0 then begin
            SetLength(bodyBuf, oldLen);
            Break;
          end;
          SetLength(bodyBuf, oldLen + got);
        end;
        job.Request.Body := TEncoding.UTF8.GetString(bodyBuf);
      end;

      // authentication
      if FToken <> '' then begin
        if (job.Request.Method = 'GET') and (job.Request.Path = '/api/status') then
          // status is always allowed
        else begin
          hdr := wbApiHeaderValue(job.Request.Headers, 'authorization');
          if not (SameText(hdr, 'Bearer ' + FToken) or SameText(hdr, FToken)) then begin
            job.Response.StatusCode := 401;
            job.Response.Body := '{"ok":false,"error":{"code":"unauthorized","message":"Invalid or missing API token"}}';
            SendResponse(sock, job);
            Exit;
          end;
        end;
      end;

      // dispatch to the main thread and wait for the result
      FQueue.Add(job);
      job.Done.WaitFor(INFINITE);
      SendResponse(sock, job);
    except
      on E: Exception do begin
        job.Response.StatusCode := 500;
        job.Response.Body := '{"ok":false,"error":{"code":"internal_error","message":' +
                             wbApiJsonString(E.Message) + '}}';
        SendResponse(sock, job);
      end;
    end;
  finally
    job.Free;
  end;
end;

procedure TwbApiServer.SendResponse(aSocket: NativeUInt; aJob: TwbApiJob);
var
  sock     : TSocket;
  code     : Integer;
  text     : string;
  head     : string;
  headB    : TBytes;
  bodyB    : TBytes;
  off, n   : Integer;
begin
  sock := TSocket(aSocket);
  code := aJob.Response.StatusCode;
  case code of
    200 : text := 'OK';
    400 : text := 'Bad Request';
    401 : text := 'Unauthorized';
    403 : text := 'Forbidden';
    404 : text := 'Not Found';
    405 : text := 'Method Not Allowed';
    413 : text := 'Payload Too Large';
    500 : text := 'Internal Server Error';
    503 : text := 'Service Unavailable';
  else
    text := 'Status';
  end;
  if code = 0 then
    code := 500;

  bodyB := TEncoding.UTF8.GetBytes(aJob.Response.Body);
  head  := Format('HTTP/1.1 %d %s'#13#10 +
                  'Content-Type: application/json; charset=utf-8'#13#10 +
                  'Content-Length: %d'#13#10 +
                  'Connection: close'#13#10#13#10, [code, text, Length(bodyB)]);
  headB := TEncoding.ASCII.GetBytes(head);

  off := 0;
  while off < Length(headB) do begin
    n := send(sock, headB[off], Length(headB) - off, 0);
    if n <= 0 then
      Exit;
    Inc(off, n);
  end;
  off := 0;
  while off < Length(bodyB) do begin
    n := send(sock, bodyB[off], Length(bodyB) - off, 0);
    if n <= 0 then
      Exit;
    Inc(off, n);
  end;
end;

{ ---------------- M3b: save & patch handlers -------------------------------- }

function TwbApiServer.FindRecordAnyFile(const aFormID: TwbFormID): IwbMainRecord;
var
  files : TwbFiles;
  f     : IwbFile;
  rec   : IwbMainRecord;
  t     : IwbFile;
  i, j, fc : Integer;
begin
  Result := nil;
  if not Assigned(FFilesProvider) then
    Exit;
  files := Copy(FFilesProvider(), 0, MaxInt);
  fc := Length(files);
  for i := 1 to Pred(fc) do begin
    t := files[i];
    j := i;
    while (j > 0) and (files[j-1].LoadOrder > t.LoadOrder) do begin
      files[j] := files[j-1];
      Dec(j);
    end;
    files[j] := t;
  end;
  for f in files do begin
    rec := f.ContainedRecordByLoadOrderFormID[aFormID, True];
    if rec <> nil then begin
      Result := rec;
      Exit;
    end;
  end;
end;

procedure TwbApiServer.HandleFileSave(aJob: TwbApiJob; const aFile: IwbFile);
begin
  if aJob.Request.Method <> 'POST' then begin
    RespondError(aJob, 405, 'method_not_allowed', 'This endpoint requires POST');
    Exit;
  end;
  if not Assigned(wbApiServerSaveAllHandler) then begin
    RespondError(aJob, 501, 'not_available',
      'Save handler is not registered (the API must run with the GUI)');
    Exit;
  end;
  try
    wbApiServerSaveAllHandler();
  except
    on E: Exception do begin
      RespondError(aJob, 500, 'save_failed', E.Message);
      Exit;
    end;
  end;
  RespondJson(aJob, 200,
    '{"ok":true,"message":"Dirty plugins were saved (same code path as the GUI Save button)"}');
end;

procedure TwbApiServer.HandleAddMasters(aJob: TwbApiJob; const aFile: IwbFile);
var
  jo      : TJsonObject;
  arr     : TJsonArray;
  name    : string;
  i, added, failed : Integer;
  err     : string;
begin
  if aJob.Request.Method <> 'POST' then begin
    RespondError(aJob, 405, 'method_not_allowed', 'This endpoint requires POST');
    Exit;
  end;
  jo := nil;
  try
    try
      jo := TJsonObject(TJsonObject.Parse(aJob.Request.Body));
    except
      jo := nil;
    end;
    if jo = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Body is not valid JSON');
      Exit;
    end;
    arr := jo.A['masters'];
    if arr = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Missing "masters" array');
      Exit;
    end;

    added := 0;
    failed := 0;
    for i := 0 to Pred(arr.Count) do begin
      try
        name := arr.S[i];
      except
        name := '';
      end;
      if name = '' then
        Continue;
      if SameText(name, aFile.FileName) then
        Continue;              // never add the file itself as its own master
      err := '';
      try
        aFile.AddMasterIfMissing(name);
        Inc(added);
      except
        on E: Exception do begin
          err := E.Message;
          Inc(failed);
        end;
      end;
    end;

    if jo.Contains('sort') and jo.B['sort'] then
      try
        aFile.SortMasters;
      except
      end;

    RespondJson(aJob, 200,
      '{"ok":' + wbApiJsonBool(failed = 0) +
      ',"added":' + IntToStr(added) +
      ',"failed":' + IntToStr(failed) + '}');
  finally
    jo.Free;
  end;
end;

// Resolves a relative element path (backslash separated, segments may be
// display names or numeric indexes) from a record/element. The last numeric
// segment resolves to a child index. Returns nil when a path cannot resolve.
function TwbApiServer.ResolveElement(const aElement: IwbElement; const aPath: string;
                                     out aContainer: IwbContainerElementRef;
                                     out aIndex: Integer): IwbElement;
var
  cur    : IwbElement;
  tokens : TArray<string>;
  t      : string;
  k, n   : Integer;
  cef    : IwbContainerElementRef;
  el     : IwbElement;
begin
  Result := nil;
  aContainer := nil;
  aIndex := -1;
  cur := aElement;
  tokens := aPath.Split(['\'], TStringSplitOptions.ExcludeEmpty);
  for k := 0 to High(tokens) do begin
    t := Trim(tokens[k]);
    if (k = 0) and SameText(t, 'RACE') then
      Continue;                     // tolerate an optional leading "RACE" token
    if t = '' then
      Continue;
    if not Supports(cur, IwbContainerElementRef, cef) then
      Exit;                                   // cannot descend further
    n := -1;
    if (Length(t) <= 9) and (t[1] in ['0'..'9']) then
      n := StrToIntDef(t, -1);
    if n >= 0 then begin
      if n < cef.ElementCount then begin
        aContainer := cef;
        aIndex := n;
        cur := cef.Elements[n];
      end else
        Exit;
    end else begin
      aIndex := -1;
      var found := False;
      for var i := 0 to Pred(cef.ElementCount) do begin
        el := cef.Elements[i];
        if SameText(el.Name, t) then begin
          aContainer := cef;
          cur := el;
          found := True;
          Break;
        end;
      end;
      if not found then
        Exit;
    end;
  end;
  Result := cur;
end;

// JSON convenience readers
function WbApiJsonStr(const aObj: TJsonObject; const aName, aDef: string): string;
begin
  Result := aDef;
  try
    if aObj <> nil then
      if aObj.Contains(aName) then
        Result := aObj.S[aName];
  except
  end;
end;

function WbApiJsonObj(const aObj: TJsonObject; const aName: string): TJsonObject;
begin
  Result := nil;
  try
    if aObj <> nil then
      if aObj.Contains(aName) then
        Result := aObj.O[aName];
  except
  end;
end;

procedure TwbApiServer.HandleApiIndex(aJob: TwbApiJob);
begin
  RespondJson(aJob, 200,
    '{"ok":true,' +
    '"apiVersion":' + IntToStr(wbApiVersion) + ',' +
    '"note":"FormIDs are 8-hex load-order FormIDs. Paths use display names joined by \\ ; numeric segments select list indexes.",' +
    '"endpoints":[' +
    '"GET  /api/status",' +
    '"GET  /api/plugins",' +
    '"GET  /api/plugins/{fileName}",' +
    '"GET  /api/plugins/{fileName}/records?signature&editorID&offset&limit&names",' +
    '"GET  /api/plugins/{fileName}/records/{formID}",' +
    '"GET  /api/records/{formID}",' +
    '"GET  /api/plugins/{fileName}/records/{formID}/tree?depth",' +
    '"POST /api/plugins/{fileName}/records/{formID}/values",' +
    '"POST /api/plugins/{fileName}/records/{formID}/copy-elements",' +
    '"POST /api/plugins/{fileName}/records/{formID}/merge-effects",' +
    '"POST /api/plugins/{fileName}/addmasters",' +
    '"POST /api/plugins/{fileName}/save",' +
    '"POST /api/patch",' +
    '"POST /api/batch  (atomic op orchestrator: set/copy/add-item/remove-item/masters/save)",' +
    '"GET  /api (this index)"' +
    ']}');
end;

function TwbApiServer.FindPlugin(const aFileName: string): IwbFile;
var
  files : TwbFiles;
  f     : IwbFile;
begin
  Result := nil;
  if not Assigned(FFilesProvider) then
    Exit;
  files := FFilesProvider();
  for f in files do
    if SameText(f.FileName, aFileName) then begin
      Result := f;
      Exit;
    end;
end;

procedure TwbApiServer.HandleBatch(aJob: TwbApiJob);
var
  jo, obj, src, values : TJsonObject;
  ops      : TJsonArray;
  sb       : TStringBuilder;
  i, k, failedCount, changed : Integer;
  strict   : Boolean;
  opName   : string;
  fn, fidS, path, vname, vval, msg, err : string;
  fid      : Cardinal;
  f, srcFile, tgtFile : IwbFile;
  rec, srcRec, tgtRec : IwbMainRecord;
  el, srcEl, tgtEl, newEl : IwbElement;
  container, parentCef, listCef : IwbContainerElementRef;
  idx      : Integer;
  template : string;
begin
  if aJob.Request.Method <> 'POST' then begin
    RespondError(aJob, 405, 'method_not_allowed', 'This endpoint requires POST');
    Exit;
  end;
  jo := nil;
  try
    try
      jo := TJsonObject(TJsonObject.Parse(aJob.Request.Body));
    except
      jo := nil;
    end;
    if jo = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Body is not valid JSON');
      Exit;
    end;
    ops := jo.A['ops'];
    if ops = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Missing "ops" array');
      Exit;
    end;
    strict := False;
    if jo.Contains('strict') then
      strict := jo.B['strict'];

    failedCount := 0;
    sb := TStringBuilder.Create;
    try
      for i := 0 to Pred(ops.Count) do begin
        obj := ops.O[i];
        opName := WbApiJsonStr(obj, 'op', '');
        err := '';
        msg := '';

        if opName = 'set' then begin
          fn := WbApiJsonStr(obj, 'file', '');
          fidS := WbApiJsonStr(obj, 'formID', '');
          f := FindPlugin(fn);
          if (f = nil) or not wbApiParseFormID(fidS, fid) then
            err := 'bad file/formID'
          else begin
            rec := f.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
            if rec = nil then
              err := 'record not found: ' + fidS
            else if not rec.IsEditable then
              err := 'record is read-only'
            else begin
              values := WbApiJsonObj(obj, 'values');
              if values = nil then
                err := 'missing values'
              else begin
                changed := 0;
                for k := 0 to Pred(values.Count) do begin
                  vname := values.Names[k];
                  try
                    vval := VarToStr(values[vname]);
                  except
                    vval := '';
                  end;
                  el := ResolveElement(rec, vname, container, idx);
                  if el = nil then
                    err := 'path not found: ' + vname
                  else if not el.IsEditable then
                    err := 'element not editable: ' + vname
                  else begin
                    try
                      el.EditValue := vval;
                      Inc(changed);
                    except
                      on E: Exception do
                        err := E.Message;
                    end;
                  end;
                  if err <> '' then
                    Break;
                end;
                if err = '' then
                  msg := 'changed ' + IntToStr(changed);
              end;
            end;
          end;
        end else if opName = 'copy' then begin
          src := WbApiJsonObj(obj, 'source');
          tgtFile := nil; srcFile := nil;
          if src <> nil then begin
            srcFile := FindPlugin(WbApiJsonStr(src, 'file', ''));
            if srcFile <> nil then begin
              fidS := WbApiJsonStr(src, 'formID', '');
              if wbApiParseFormID(fidS, fid) then
                srcRec := srcFile.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
            end;
          end;
          fn := WbApiJsonStr(obj, 'file', '');
          fidS := WbApiJsonStr(obj, 'formID', '');
          f := FindPlugin(fn);
          if (f = nil) or not wbApiParseFormID(fidS, fid) then
            err := 'bad file/formID'
          else begin
            tgtRec := f.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
            if (srcRec = nil) or (tgtRec = nil) then
              err := 'could not resolve target/source record'
            else begin
              path := WbApiJsonStr(obj, 'path', '');
              if path = '' then
                err := 'missing path'
              else begin
                srcEl := ResolveElement(srcRec, path, container, idx);
                tgtEl := ResolveElement(tgtRec, path, container, idx);
                if srcEl = nil then
                  err := 'source path not found: ' + path
                else if tgtEl <> nil then begin
                  try
                    tgtEl.Assign(wbAssignThis, srcEl, False);
                    msg := 'copied ' + path;
                  except
                    on E: Exception do
                      err := E.Message;
                  end;
                end else begin
                  // target missing: create the optional sub-record under its parent
                  var tokens := path.Split(['\'], TStringSplitOptions.ExcludeEmpty);
                  var parentPath := '';
                  for k := 0 to High(tokens) - 1 do begin
                    if k > 0 then
                      parentPath := parentPath + '\';
                    parentPath := parentPath + tokens[k];
                  end;
                  var lastToken := tokens[High(tokens)];
                  var pe := ResolveElement(tgtRec, parentPath, parentCef, idx);
                  if (pe = nil) or not Supports(pe, IwbContainerElementRef, listCef) then
                    err := 'cannot create: parent not found for ' + path
                  else begin
                    try
                      newEl := listCef.Add(lastToken);
                      if newEl = nil then
                        err := 'could not add ' + lastToken
                      else begin
                        newEl.Assign(wbAssignThis, srcEl, False);
                        msg := 'created+copied ' + path;
                      end;
                    except
                      on E: Exception do
                        err := E.Message;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end else if opName = 'add-item' then begin
          fn := WbApiJsonStr(obj, 'file', '');
          fidS := WbApiJsonStr(obj, 'formID', '');
          f := FindPlugin(fn);
          if (f = nil) or not wbApiParseFormID(fidS, fid) then
            err := 'bad file/formID'
          else begin
            rec := f.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
            path := WbApiJsonStr(obj, 'path', '');
            if (rec = nil) then
              err := 'record not found'
            else if path = '' then
              err := 'missing path (container)'
            else begin
              el := ResolveElement(rec, path, container, idx);
              if (el = nil) or not Supports(el, IwbContainerElementRef, listCef) then
                err := 'path is not a container: ' + path
              else begin
                template := WbApiJsonStr(obj, 'template', '');
                if template = '' then
                  if listCef.ElementCount > 0 then
                    template := listCef.Elements[0].Name;
                if template = '' then
                  err := 'cannot infer item template for ' + path
                else begin
                  try
                    newEl := listCef.Add(template);
                    if newEl = nil then
                      err := 'could not add item ' + template
                    else begin
                      msg := 'added ' + template + ' at index ' + IntToStr(Pred(listCef.ElementCount));
                      src := WbApiJsonObj(obj, 'source');
                      if src <> nil then begin
                        srcFile := FindPlugin(WbApiJsonStr(src, 'file', ''));
                        fidS := WbApiJsonStr(src, 'formID', '');
                        if (srcFile <> nil) and wbApiParseFormID(fidS, fid) then begin
                          srcRec := srcFile.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
                          if srcRec <> nil then begin
                            srcEl := ResolveElement(srcRec, WbApiJsonStr(src, 'path', path), container, idx);
                            if srcEl <> nil then
                              newEl.Assign(wbAssignThis, srcEl, False);
                          end;
                        end;
                      end;
                    end;
                  except
                    on E: Exception do
                      err := E.Message;
                  end;
                end;
              end;
            end;
          end;
        end else if opName = 'remove-item' then begin
          fn := WbApiJsonStr(obj, 'file', '');
          fidS := WbApiJsonStr(obj, 'formID', '');
          path := WbApiJsonStr(obj, 'path', '');
          f := FindPlugin(fn);
          if (f = nil) or not wbApiParseFormID(fidS, fid) then
            err := 'bad file/formID'
          else begin
            rec := f.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
            if rec = nil then
              err := 'record not found'
            else begin
              el := ResolveElement(rec, path, container, idx);
              if (el = nil) or (container = nil) or (idx < 0) then
                err := 'path must end in a numeric list index: ' + path
              else begin
                try
                  container.RemoveElement(idx);
                  msg := 'removed ' + path;
                except
                  on E: Exception do
                    err := E.Message;
                end;
              end;
            end;
          end;
        end else if opName = 'masters' then begin
          fn := WbApiJsonStr(obj, 'file', '');
          f := FindPlugin(fn);
          if f = nil then
            err := 'plugin not loaded: ' + fn
          else begin
            var arr := jo.A['add'];
            if arr <> nil then
              for k := 0 to Pred(arr.Count) do begin
                try
                  var mname := arr.S[k];
                  if not SameText(mname, f.FileName) then
                    f.AddMasterIfMissing(mname);
                except
                end;
              end;
            if obj.Contains('sort') and obj.B['sort'] then
              f.SortMasters;
            if obj.Contains('clean') and obj.B['clean'] then
              f.CleanMasters;
            msg := 'masters updated';
          end;
        end else if opName = 'save' then begin
          if not Assigned(wbApiServerSaveAllHandler) then
            err := 'save handler not registered'
          else begin
            try
              wbApiServerSaveAllHandler();
              msg := 'saved (all dirty)';
            except
              on E: Exception do
                err := E.Message;
            end;
          end;
        end else
          err := 'unknown op: ' + opName;

        if i > 0 then
          sb.Append(',');
        if err = '' then
          sb.Append('{"index":').Append(i).Append(',"op":').Append(wbApiJsonString(opName))
            .Append(',"ok":true,"message":').Append(wbApiJsonString(msg)).Append('}')
        else begin
          Inc(failedCount);
          sb.Append('{"index":').Append(i).Append(',"op":').Append(wbApiJsonString(opName))
            .Append(',"ok":false,"error":').Append(wbApiJsonString(err)).Append('}');
          if strict then
            Break;
        end;
      end;

      RespondJson(aJob, 200,
        '{"ok":' + wbApiJsonBool(failedCount = 0) +
        ',"failed":' + IntToStr(failedCount) +
        ',"results":[' + sb.ToString + ']}');
    finally
      sb.Free;
    end;
  finally
    jo.Free;
  end;
end;

function TwbApiServer.FindTopLevelElement(const aRecord: IwbMainRecord;
                                          const aName: string): IwbElement;
var
  cb : IwbContainerBase;
  i  : Integer;
begin
  Result := nil;
  cb := aRecord;
  for i := 0 to Pred(cb.ElementCount) do
    if SameText(cb.Elements[i].Name, aName) then begin
      Result := cb.Elements[i];
      Exit;
    end;
end;

procedure TwbApiServer.HandleCopyElements(aJob: TwbApiJob; const aFile: IwbFile;
                                          const aFormID: TwbFormID);
var
  jo, src      : TJsonObject;
  arr          : TJsonArray;
  tgtRec       : IwbMainRecord;
  srcRec       : IwbMainRecord;
  srcFile      : IwbFile;
  files        : TwbFiles;
  tgtEl, srcEl : IwbElement;
  newEl        : IwbElement;
  sb           : TStringBuilder;
  i, changed, failed : Integer;
  name, srcFileName, srcFormIDStr, err : string;
  srcFID       : Cardinal;
begin
  if aJob.Request.Method <> 'POST' then begin
    RespondError(aJob, 405, 'method_not_allowed', 'This endpoint requires POST');
    Exit;
  end;
  if aJob.Request.Body = '' then begin
    RespondError(aJob, 400, 'bad_request',
      'Body must be {"source":{"file":"X.esp","formID":"hex"},"elements":["DATA - DATA",...]}');
    Exit;
  end;

  tgtRec := aFile.ContainedRecordByLoadOrderFormID[aFormID, True];
  if tgtRec = nil then begin
    RespondError(aJob, 404, 'not_found',
      'Target record not found in ' + aFile.FileName + ': ' + IntToHex(aFormID.ToCardinal, 8));
    Exit;
  end;

  jo := nil;
  try
    try
      jo := TJsonObject(TJsonObject.Parse(aJob.Request.Body));
    except
      jo := nil;
    end;
    if jo = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Body is not valid JSON');
      Exit;
    end;
    src := jo.O['source'];
    if src = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Missing "source" object');
      Exit;
    end;
    arr := jo.A['elements'];
    if arr = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Missing "elements" array');
      Exit;
    end;

    srcFileName := src.S['file'];
    srcFormIDStr := src.S['formID'];
    if (srcFileName = '') or not wbApiParseFormID(srcFormIDStr, srcFID) then begin
      RespondError(aJob, 400, 'bad_request', 'source.file / source.formID invalid');
      Exit;
    end;

    srcFile := nil;
    if Assigned(FFilesProvider) then begin
      files := FFilesProvider();
      for var f2 in files do
        if SameText(f2.FileName, srcFileName) then begin
          srcFile := f2;
          Break;
        end;
    end;
    if srcFile = nil then begin
      RespondError(aJob, 404, 'not_found', 'Source plugin not loaded: ' + srcFileName);
      Exit;
    end;
    srcRec := srcFile.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(srcFID), True];
    if srcRec = nil then begin
      RespondError(aJob, 404, 'not_found',
        'Source record not found in ' + srcFileName + ': ' + srcFormIDStr);
      Exit;
    end;

    changed := 0;
    failed  := 0;
    sb := TStringBuilder.Create;
    try
      for i := 0 to Pred(arr.Count) do begin
        try
          name := arr.S[i];
        except
          name := '';
        end;
        err := '';
        if name = '' then
          err := 'empty element name'
        else begin
          tgtEl := FindTopLevelElement(tgtRec, name);
          if tgtEl = nil then
            err := 'element not found on target: ' + name
          else begin
            srcEl := FindTopLevelElement(srcRec, name);
            if srcEl = nil then
              err := 'element not found on source: ' + name
            else begin
              try
                newEl := tgtEl.Assign(wbAssignThis, srcEl, False);
                Inc(changed);
              except
                on E: Exception do
                  err := E.Message;
              end;
            end;
          end;
        end;

        if i > 0 then
          sb.Append(',');
        if err = '' then
          sb.Append('{"element":').Append(wbApiJsonString(name)).Append(',"ok":true}')
        else begin
          Inc(failed);
          sb.Append('{"element":').Append(wbApiJsonString(name))
            .Append(',"ok":false,"error":').Append(wbApiJsonString(err)).Append('}');
        end;
      end;

      RespondJson(aJob, 200,
        '{"ok":' + wbApiJsonBool(failed = 0) +
        ',"changed":' + IntToStr(changed) +
        ',"failed":' + IntToStr(failed) +
        ',"results":[' + sb.ToString + ']}');
    finally
      sb.Free;
    end;
  finally
    jo.Free;
  end;
end;

// Helper: normalized identity of an actor-effect (SPLO) element, e.g. "SPEL:000AA022".
function WbApiSpellKey(const aElement: IwbElement): string;
var
  v, s : string;
  p, q : Integer;
begin
  Result := '';
  try
    v := aElement.Value;
  except
    v := '';
  end;
  p := Pos('[SPEL:', v);
  if p > 0 then begin
    s := Copy(v, p + 6, MaxInt);
    q := Pos(']', s);
    if q > 0 then begin
      Result := Trim(Copy(s, 1, q - 1));
      Exit;
    end;
  end;
  if Result = '' then
    Result := aElement.Name;   // fall back to display name
end;

procedure TwbApiServer.HandleMergeEffects(aJob: TwbApiJob; const aFile: IwbFile;
                                          const aFormID: TwbFormID);
var
  jo, jo2    : TJsonObject;
  tgtRec, baseRec, scsiRec, ubeRec : IwbMainRecord;
  baseFile, scsiFile, ubeFile : IwbFile;
  files      : TwbFiles;
  tgtAct, baseAct, scsiAct, ubeAct : IwbContainerElementRef;
  baseKeys, ubeKeys : TStringList;
  i, j, appended, failed, tgtCount : Integer;
  srcEl, newEl : IwbElement;
  key        : string;
  err        : string;
  spctEl     : IwbElement;
begin
  if aJob.Request.Method <> 'POST' then begin
    RespondError(aJob, 405, 'method_not_allowed', 'This endpoint requires POST');
    Exit;
  end;
  jo := nil;
  try
    try
      jo := TJsonObject(TJsonObject.Parse(aJob.Request.Body));
    except
      jo := nil;
    end;
    if jo = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Body is not valid JSON');
      Exit;
    end;

    tgtRec := aFile.ContainedRecordByLoadOrderFormID[aFormID, True];
    if tgtRec = nil then begin
      RespondError(aJob, 404, 'not_found',
        'Target record not found: ' + IntToHex(aFormID.ToCardinal, 8));
      Exit;
    end;

    files := Copy(FFilesProvider(), 0, MaxInt);

    // resolve the three reference records
    baseRec := nil; scsiRec := nil; ubeRec := nil;
    jo2 := jo.O['base']; if jo2 <> nil then begin
      for var f2 in files do
        if SameText(f2.FileName, jo2.S['file']) then begin
          baseFile := f2;
          Break;
        end;
      if baseFile <> nil then begin
        var fid: Cardinal;
        if wbApiParseFormID(jo2.S['formID'], fid) then
          baseRec := baseFile.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
      end;
    end;
    jo2 := jo.O['scsi']; if jo2 <> nil then begin
      baseFile := nil;
      for var f2 in files do
        if SameText(f2.FileName, jo2.S['file']) then begin
          scsiFile := f2;
          Break;
        end;
      if scsiFile <> nil then begin
        var fid: Cardinal;
        if wbApiParseFormID(jo2.S['formID'], fid) then
          scsiRec := scsiFile.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
      end;
    end;
    jo2 := jo.O['ube']; if jo2 <> nil then begin
      baseFile := nil;
      for var f2 in files do
        if SameText(f2.FileName, jo2.S['file']) then begin
          ubeFile := f2;
          Break;
        end;
      if ubeFile <> nil then begin
        var fid: Cardinal;
        if wbApiParseFormID(jo2.S['formID'], fid) then
          ubeRec := ubeFile.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
      end;
    end;

    if (baseRec = nil) or (scsiRec = nil) or (ubeRec = nil) then begin
      RespondError(aJob, 400, 'bad_request', 'Could not resolve base/scsi/ube records');
      Exit;
    end;

    if not (Supports(FindTopLevelElement(tgtRec, 'Actor Effects'), IwbContainerElementRef, tgtAct)) then begin
      RespondError(aJob, 400, 'bad_request', 'Target record has no Actor Effects list');
      Exit;
    end;
    Supports(FindTopLevelElement(baseRec, 'Actor Effects'), IwbContainerElementRef, baseAct);
    Supports(FindTopLevelElement(scsiRec, 'Actor Effects'), IwbContainerElementRef, scsiAct);
    Supports(FindTopLevelElement(ubeRec, 'Actor Effects'), IwbContainerElementRef, ubeAct);

    baseKeys := TStringList.Create;
    ubeKeys  := TStringList.Create;
    try
      baseKeys.Sorted := True;
      baseKeys.Duplicates := dupIgnore;
      ubeKeys.Sorted := True;
      ubeKeys.Duplicates := dupIgnore;

      if baseAct <> nil then
        for i := 0 to Pred(baseAct.ElementCount) do
          baseKeys.Add(WbApiSpellKey(baseAct.Elements[i]));
      if ubeAct <> nil then
        for i := 0 to Pred(ubeAct.ElementCount) do
          ubeKeys.Add(WbApiSpellKey(ubeAct.Elements[i]));

      appended := 0;
      failed   := 0;
      if ubeAct <> nil then
        for i := 0 to Pred(ubeAct.ElementCount) do begin
          srcEl := ubeAct.Elements[i];
          key := WbApiSpellKey(srcEl);
          // append only UBE-specific effects: not part of the base spell set and
          // not already present on the target (which holds the SCSI list)
          if baseKeys.IndexOf(key) >= 0 then
            Continue;
          if key = srcEl.Name then begin
            // unparsed identity; only skip if identical name already exists
          end;
          // check target membership
          var already := False;
          for j := 0 to Pred(tgtAct.ElementCount) do
            if SameText(WbApiSpellKey(tgtAct.Elements[j]), key) then begin
              already := True;
              Break;
            end;
          if already then
            Continue;
          err := '';
          try
            newEl := tgtAct.Add('SPLO - Actor Effect');
            if newEl = nil then
              err := 'could not add SPLO element'
            else begin
              newEl.Assign(wbAssignThis, srcEl, False);
              Inc(appended);
            end;
          except
            on E: Exception do
              err := E.Message;
          end;
          if err <> '' then
            Inc(failed);
        end;

      // refresh the SPCT count if a separate count element exists
      if appended > 0 then begin
        spctEl := FindTopLevelElement(tgtRec, 'SPCT - Count');
        if spctEl <> nil then begin
          tgtCount := 0;
          if tgtAct <> nil then
            tgtCount := tgtAct.ElementCount;
          try
            spctEl.EditValue := IntToStr(tgtCount);
          except
          end;
        end;
      end;

      RespondJson(aJob, 200,
        '{"ok":' + wbApiJsonBool(failed = 0) +
        ',"appended":' + IntToStr(appended) +
        ',"failed":' + IntToStr(failed) + '}');
    finally
      baseKeys.Free;
      ubeKeys.Free;
    end;
  finally
    jo.Free;
  end;
end;

procedure TwbApiServer.HandlePatch(aJob: TwbApiJob);
var
  jo       : TJsonObject;
  recs     : TJsonArray;
  sb       : TStringBuilder;
  newFile  : IwbFile;
  rec      : IwbMainRecord;
  res      : IwbElement;
  fname    : string;
  fidStr   : string;
  fid      : Cardinal;
  fileName : string;
  err      : string;
  isLight  : Boolean;
  autoSave : Boolean;
  doWinning: Boolean;
  created, failed : Integer;
  i        : Integer;
begin
  if aJob.Request.Method <> 'POST' then begin
    RespondError(aJob, 405, 'method_not_allowed', 'This endpoint requires POST');
    Exit;
  end;
  if not Assigned(wbApiServerAddFileHandler) then begin
    RespondError(aJob, 501, 'not_available',
      'New-file handler is not registered (the API must run with the GUI)');
    Exit;
  end;

  jo := nil;
  try
    try
      jo := TJsonObject(TJsonObject.Parse(aJob.Request.Body));
    except
      jo := nil;
    end;
    if jo = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Body is not valid JSON');
      Exit;
    end;

    fileName := Trim(jo.S['fileName']);
    if fileName = '' then begin
      RespondError(aJob, 400, 'bad_request', 'Missing "fileName"');
      Exit;
    end;
    if ExtractFileExt(fileName) = '' then
      fileName := fileName + '.esp';

    isLight  := False;
    if jo.Contains('isLight') then
      isLight := jo.B['isLight'];
    autoSave := False;
    if jo.Contains('autoSave') then
      autoSave := jo.B['autoSave'];

    recs := jo.A['records'];
    if recs = nil then begin
      RespondError(aJob, 400, 'bad_request', 'Missing "records" array');
      Exit;
    end;

    newFile := wbApiServerAddFileHandler(fileName, isLight, False);
    if newFile = nil then begin
      RespondError(aJob, 400, 'create_failed', 'Could not create plugin file: ' + fileName);
      Exit;
    end;
    if isLight then
      newFile.IsLight := True;   // make sure the ESL flag is set on the header

    created := 0;
    failed  := 0;
    sb := TStringBuilder.Create;
    try
      for i := 0 to Pred(recs.Count) do begin
        err := '';
        try
          var o := recs.O[i];
          fname := '';
          if o.Contains('file') then
            fname := o.S['file'];
          fidStr := '';
          if o.Contains('formID') then
            fidStr := o.S['formID'];
          if not wbApiParseFormID(fidStr, fid) then
            err := 'invalid formID: ' + fidStr
          else begin
            if fname <> '' then begin
              var files := Copy(FFilesProvider(), 0, MaxInt);
              var srcFile: IwbFile := nil;
              for var f2 in files do
                if SameText(f2.FileName, fname) then begin
                  srcFile := f2;
                  Break;
                end;
              if srcFile = nil then
                err := 'plugin not loaded: ' + fname
              else
                rec := srcFile.ContainedRecordByLoadOrderFormID[TwbFormID.FromCardinal(fid), True];
            end else
              rec := FindRecordAnyFile(TwbFormID.FromCardinal(fid));

            if err = '' then begin
              if rec = nil then
                err := 'record not found: ' + fidStr
              else begin
                doWinning := False;
                if o.Contains('winning') then
                  doWinning := o.B['winning'];
                if doWinning then begin
                  var master := rec.MasterOrSelf;
                  var win := master.WinningOverride;
                  if win <> nil then
                    rec := win;
                end;
                res := rec.CopyInto(newFile, False, True, '', '', '', '');
                if res = nil then
                  err := 'copy failed for ' + fidStr;
              end;
            end;
          end;
        except
          on E: Exception do
            err := E.Message;
        end;

        if err <> '' then begin
          Inc(failed);
          sb.Append('{"formID":').Append(wbApiJsonString(fidStr))
            .Append(',"ok":false,"error":').Append(wbApiJsonString(err)).Append('}');
        end else begin
          Inc(created);
          if created > 1 then
            sb.Append(',');
          sb.Append('{"formID":').Append(wbApiJsonString(fidStr)).Append(',"ok":true}');
        end;
      end;

      try
        newFile.SortMasters;
        newFile.CleanMasters;
      except
        on E: Exception do
          sb.Append('{"formID":"","ok":false,"error":').Append(wbApiJsonString('masters: ' + E.Message)).Append('}');
      end;

      if autoSave and Assigned(wbApiServerSaveAllHandler) then
        try
          wbApiServerSaveAllHandler();
        except
          on E: Exception do
            sb.Append('{"formID":"","ok":false,"error":').Append(wbApiJsonString('autosave: ' + E.Message)).Append('}');
        end;

      RespondJson(aJob, 200,
        '{"ok":' + wbApiJsonBool(failed = 0) +
        ',"fileName":' + wbApiJsonString(newFile.FileName) +
        ',"created":' + IntToStr(created) +
        ',"failed":' + IntToStr(failed) +
        ',"results":[' + sb.ToString + ']}');
    finally
      sb.Free;
    end;
  finally
    jo.Free;
  end;
end;

{ =========================================================================== }
{  global entry points                                                        }
{ =========================================================================== }

procedure wbApiServerConfigureFromCmdLine;
var
  s    : string;
  port : Integer;
begin
  if Assigned(wbApiServerInstance) then
    Exit;
  if wbFindCmdLineParam('api', s) then begin
    port := wbApiDefaultPort;
    if s <> '' then
      port := StrToIntDef(s, wbApiDefaultPort);
    if (port < 1) or (port > 65535) then
      port := wbApiDefaultPort;

    s := '';
    wbFindCmdLineParam('apitoken', s);

    wbApiServerInstance := TwbApiServer.Create(Word(port), s);
  end;
end;

function wbApiServerEnabled: Boolean;
begin
  Result := Assigned(wbApiServerInstance);
end;

procedure wbApiServerStart(const aFilesProvider: TwbApiFilesProvider);
begin
  if Assigned(wbApiServerInstance) then
    wbApiServerInstance.Start(aFilesProvider);
end;

procedure wbApiServerStop;
begin
  if Assigned(wbApiServerInstance) then
    wbApiServerInstance.Stop;
end;

procedure wbApiServerSetAddFileHandler(const aHandler: TwbApiAddFileProc);
begin
  wbApiServerAddFileHandler := aHandler;
end;

procedure wbApiServerSetSaveAllHandler(const aHandler: TwbApiSaveAllProc);
begin
  wbApiServerSaveAllHandler := aHandler;
end;

initialization
finalization
  wbApiServerStop;
  FreeAndNil(wbApiServerInstance);
end.
