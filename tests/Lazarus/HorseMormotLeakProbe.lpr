program HorseMormotLeakProbe;

(*
  horse-provider-mormot  -  single-process memory-leak probe  (Lazarus / FPC)
  ===========================================================================
  Purpose
  -------
  Confirm or refute the "the mORMot provider also leaks memory" claim on
  HashLoad/horse issue #576 (Lazarus 4.8 / FPC 3.2.2) AGAINST THIS FORK.

  The suspect is the per-request path: every request creates a fresh
  TMormotWebResponse adapter (Horse.Provider.Mormot.pas, Ctx.Response
  .SetCSRawWebResponse(TMormotWebResponse.Create(Ctxt))), plus a per-request
  cookie list and custom-header list. If any of those is not freed when the
  pooled context is recycled, the heap grows linearly with the request count.

  Measurement: RSS in-run trend + heaptrc exit dump (NOT GetFPCHeapStatus)
  ------------------------------------------------------------------------
  HARD-LEARNED: GetFPCHeapStatus.CurrHeapUsed is PER-THREAD. Requests are served
  on mORMot worker threads, so a main-thread sample of it is blind to the entire
  request path - a deliberate 50 000-object positive-control leak moved it by
  ZERO bytes. Any per-thread heap counter is therefore useless here. The two
  instruments that ARE process-global:

  - RSS (VmRSS, OS-level) - LIVE trend, every thread, every allocator. Coarse
    (the allocator keeps freed blocks, small leaks hide until megabytes), but it
    moves for a real leak and is sampled during the run. Linux only here
    (/proc/self/status); on Windows RSS is not sampled - rely on the -gh dump.
  - heaptrc (-gh) exit dump - EXACT, all threads, counts every unfreed block at
    process exit. This is the AUTHORITATIVE instrument.

  So a per-request leak shows RSS climbing monotonically chunk-over-chunk (far
  above the jitter noise floor - see perf-measurement), AND the -gh dump's
  unfreed-block count scaling with the request count. A clean path shows RSS
  flat after warm-up and a -gh block count that does NOT change with the request
  count (only the fixed warm-pool/singleton retention, if any).

  THE AUTHORITATIVE PROTOCOL is the heaptrc two-count comparison, because it
  separates per-request growth from fixed retention without trusting RSS:
    run -gh at a SMALL and a LARGE request count; if "unfreed blocks" scales with
    the count there is a per-request leak; if it stays constant there is not.
  The positive control (-dPROBE_LEAK) MUST make both signals fire - that is how
  you know the instrument has teeth before trusting a clean result.

  Everything is 127.0.0.1 and in-process; the server runs on a worker thread
  (THorse.Listen blocks the calling thread in a console app, so it cannot run
  on the main thread that fires the requests). Assertions check a unique body
  only this handler emits, so a foreign listener squatting the port cannot be
  mistaken for the server (see the nahimic/wslrelay port-squat note).

  Build - Lazarus IDE (Windows or Linux)
  --------------------------------------
    Project Options -> Compiler Options -> Custom Options:
      -dHORSE_PROVIDER_MORMOT
    Run (a): "Use Heaptrc unit (-gh)" OFF -> live RSS table (Linux only; on
             Windows RSS is not sampled, so use run (b) there).
    Run (b): Debugging -> tick "Use Heaptrc unit (-gh)" -> AUTHORITATIVE exit
             dump. Build at TWO request counts and compare the unfreed-block
             count; also build once with -dPROBE_LEAK to prove the dump catches
             a planted leak.
    Add Horse/src, this provider's src, and mORMot2/src/* to "Other unit files".

  Build - devcontainer / Linux (bare fpc, mirrors build-fpc.sh)
  -------------------------------------------------------------
    tests/Lazarus/run-leak-probe.sh            (run (a), no heaptrc)
    tests/Lazarus/run-leak-probe.sh --heaptrc  (run (b), with -gh exit dump)

  Arguments (optional; defaults in the consts below)
  --------------------------------------------------
    HorseMormotLeakProbe [warmup] [measure] [chunk]
      warmup  requests fired before the baseline is taken (reach steady state)
      measure requests fired while sampling the heap
      chunk   sample the heap every <chunk> requests
    e.g.  ./HorseMormotLeakProbe 5000 50000 5000

  NOTE on comments: this file uses star-paren block comments and // line
  comments only, and keeps every star-paren and brace comment-delimiter out of
  the prose - a stray close-delimiter ends the comment early and the rest of the
  line is then parsed as code (that class of bug once stopped this very file, and
  the sibling server, compiling).
*)

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}   // cthreads FIRST: no thread manager without it
  SysUtils,
  Classes,
  fphttpclient,
  Horse,
  Horse.Commons,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.Pool;

const
  TEST_HOST = '127.0.0.1';
  TEST_PORT = 9218;                       // avoids 9000-9100 / 9091 / 9200 / 9222 squatters

  PING_SENTINEL = 'horse-mormot-leak-probe-pong-7f3a';  // unique to this handler

  DEFAULT_WARMUP  = 5000;                 // requests to reach steady state
  DEFAULT_MEASURE = 50000;                // requests sampled for growth
  DEFAULT_CHUNK   = 5000;                 // sample the heap every N requests

  // Per-request POST body - non-trivial so the body + adapter path is exercised.
  PROBE_BODY = '{"probe":"leak","n":1234567890,"s":"the quick brown fox 0123456789"}';

var
  GWarmup:  Integer;
  GMeasure: Integer;
  GChunk:   Integer;

// ─────────────────────────────────────────────────────────────────────────────
// Process RSS in KB - PROCESS-WIDE, every thread (unlike GetFPCHeapStatus, which
// is per-thread and blind to the worker-thread request path). Linux reads
// VmRSS from /proc/self/status; other platforms return -1 (not sampled - use
// the -gh heaptrc dump there). Coarse but live: the authoritative check is -gh.
// ─────────────────────────────────────────────────────────────────────────────
function ProcessRssKB: Int64;
{$IFDEF UNIX}
var
  F: Text;
  S, V: string;
  P: Integer;
begin
  Result := -1;
  AssignFile(F, '/proc/self/status');
  {$I-} Reset(F); {$I+}
  if IOResult <> 0 then
    Exit;
  try
    while not EOF(F) do
    begin
      ReadLn(F, S);
      if Pos('VmRSS:', S) = 1 then
      begin
        V := Trim(Copy(S, Pos(':', S) + 1, MaxInt));
        P := Pos(' ', V);
        if P > 0 then
          V := Copy(V, 1, P - 1);
        Result := StrToInt64Def(V, -1);
        Break;
      end;
    end;
  finally
    CloseFile(F);
  end;
end;
{$ELSE}
begin
  Result := -1;   // Windows: not sampled in-run; rely on the -gh heaptrc dump
end;
{$ENDIF}

// ─────────────────────────────────────────────────────────────────────────────
// Routes (plain unit-scope procedures - no anonymous methods, so stock FPC
// compiles this without HORSE_FPC_FUNCTIONREFERENCES; register with no '@').
// ─────────────────────────────────────────────────────────────────────────────
procedure RoutePing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain').Send(PING_SENTINEL);
end;

{$IFDEF PROBE_LEAK}
// POSITIVE CONTROL (mutation control for the instrument). Built only with
// -dPROBE_LEAK, this leaks one TStringList on EVERY request on purpose. The
// RSS table MUST then climb and the -gh unfreed-block count MUST scale with the
// request count. If neither moves, the probe is blind and a flat run proves
// nothing - fix the probe before trusting any clean result. NEVER build with
// this define for a real verdict.
procedure LeakOne;
var
  L: TStringList;
begin
  L := TStringList.Create;          // intentionally never freed
  L.Add('intentional-leak');
end;
{$ENDIF}

// POST /echo - the richest per-request surface on this provider:
//   * reads the request body (SetBodyString path)
//   * reads a request header (header map populated per request)
//   * sets a response custom header (FCustomHeaders - PATCH-RES-1)
//   * sets a cookie         (FCookies      - PATCH-COOKIE-1)
//   * sends a body          (drives Flush + the TMormotWebResponse adapter,
//                            FCSRawWebResponse - PATCH-RES-6)
// If any of these per-request allocations is not released on pool recycle,
// this is where the growth shows up.
procedure RouteEcho(Req: THorseRequest; Res: THorseResponse);
begin
  {$IFDEF PROBE_LEAK}
  LeakOne;   // positive control - see note above; only with -dPROBE_LEAK
  {$ENDIF}
  Res.AddHeader('X-Probe-Echo', Req.Headers['X-Probe']);
  Res.Cookie('probe', 'v1').Path('/').HttpOnly(True);
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"ok":true,"blen":' + IntToStr(Length(Req.Body)) + '}');
end;

procedure RegisterRoutes;
begin
  THorse.Get('/ping',  RoutePing);
  THorse.Post('/echo', RouteEcho);
end;

// ─────────────────────────────────────────────────────────────────────────────
// Server thread - THorse.Listen blocks (IsConsole = True) until StopListen.
// ─────────────────────────────────────────────────────────────────────────────
type
  TServerThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TServerThread.Execute;
begin
  THorse.Listen(TEST_PORT, TEST_HOST);
end;

// ─────────────────────────────────────────────────────────────────────────────
// Wait until the server answers /ping with our sentinel, bounded by wall clock
// (wall-clock-bounded-polling: never an unbounded Sleep loop).
// ─────────────────────────────────────────────────────────────────────────────
function WaitServerReady(const ATimeoutMs: Integer): Boolean;
var
  LClient:   TFPHTTPClient;
  LDeadline: TDateTime;
  LBody:     string;
begin
  Result := False;
  LDeadline := Now + (ATimeoutMs / 86400000.0);   // ms -> days
  LClient := TFPHTTPClient.Create(nil);
  try
    while Now < LDeadline do
    begin
      try
        LBody := LClient.Get(Format('http://%s:%d/ping', [TEST_HOST, TEST_PORT]));
        if Pos(PING_SENTINEL, LBody) > 0 then
          Exit(True);
      except
        // connection refused while the listener is still binding - retry
      end;
      Sleep(50);
    end;
  finally
    LClient.Free;
  end;
end;

// ─────────────────────────────────────────────────────────────────────────────
// Fire ACount POST /echo requests on ONE keep-alive connection, reusing a
// single request-body stream (so the CLIENT side allocates nothing per
// request - the RSS delta then reflects the SERVER path, not client churn).
// ─────────────────────────────────────────────────────────────────────────────
procedure FireRequests(AClient: TFPHTTPClient; ABody: TStream; ACount: Integer);
var
  I:   Integer;
  LRs: string;
begin
  for I := 1 to ACount do
  begin
    ABody.Position := 0;
    LRs := AClient.Post(Format('http://%s:%d/echo', [TEST_HOST, TEST_PORT]));
    if Pos('"ok":true', LRs) = 0 then
      raise Exception.CreateFmt('unexpected /echo reply at request %d: %s', [I, LRs]);
  end;
end;

// ─────────────────────────────────────────────────────────────────────────────
procedure RunProbe;
var
  LClient:   TFPHTTPClient;
  LBody:     TStringStream;
  LBaseline: Int64;
  LNow:      Int64;
  LDone:     Integer;
  LStep:     Integer;
  LPerReq:   Double;
  LMaxDelta: Int64;
begin
  LClient := TFPHTTPClient.Create(nil);
  LBody   := TStringStream.Create(PROBE_BODY);
  try
    LClient.KeepConnection := True;                 // one socket - no per-request churn
    LClient.AddHeader('Content-Type', 'application/json; charset=utf-8');
    LClient.AddHeader('X-Probe', 'leak-probe');
    LClient.RequestBody := LBody;

    // ── Warm-up: fill the pool, warm keep-alive buffers and caches ──────────
    WriteLn(Format('[probe] warm-up: %d requests ...', [GWarmup]));
    FireRequests(LClient, LBody, GWarmup);

    // Let any just-finished server work settle, then take the baseline.
    Sleep(200);
    LBaseline := ProcessRssKB;
    LMaxDelta := 0;

    if LBaseline < 0 then
    begin
      // RSS not sampled on this platform (e.g. Windows). Still fire the load so
      // a -gh build produces its authoritative exit dump; skip the live table.
      WriteLn('[probe] RSS not sampled on this platform - firing the load for the');
      WriteLn('        -gh heaptrc exit dump only (build with --heaptrc / -gh).');
      WriteLn(Format('[probe] firing %d requests ...', [GMeasure]));
      FireRequests(LClient, LBody, GMeasure);
      WriteLn('[probe] load done - read the heaptrc dump below, and compare it');
      WriteLn('        against a run at a different request count (two-count protocol).');
      Exit;   // finally below frees client/body
    end;

    WriteLn(Format('[probe] baseline RSS = %d KB, pool idle = %d',
      [LBaseline, THorseContextPool.IdleCount]));
    WriteLn('[probe] measuring - a monotonic rise = LEAK; flat = CLEAN (RSS is coarse)');
    WriteLn('   requests            rssKB        deltaKB      KB/1k-req(cum)');

    // ── Measured phase, sampled every GChunk requests ───────────────────────
    LDone := 0;
    while LDone < GMeasure do
    begin
      LStep := GChunk;
      if LDone + LStep > GMeasure then
        LStep := GMeasure - LDone;
      FireRequests(LClient, LBody, LStep);
      Inc(LDone, LStep);

      Sleep(100);                                   // quiescent sample point
      LNow := ProcessRssKB;
      if (LNow - LBaseline) > LMaxDelta then
        LMaxDelta := LNow - LBaseline;
      LPerReq := (LNow - LBaseline) / LDone * 1000.0;   // KB per 1000 requests
      WriteLn(Format('  %9d   %13d   %10d   %14.2f',
        [LDone, LNow, LNow - LBaseline, LPerReq]));
    end;

    LNow    := ProcessRssKB;
    LPerReq := (LNow - LBaseline) / GMeasure * 1000.0;

    WriteLn;
    WriteLn('--- Summary ----------------------------------------------');
    WriteLn(Format('  requests measured : %d', [GMeasure]));
    WriteLn(Format('  baseline RSS      : %d KB', [LBaseline]));
    WriteLn(Format('  final RSS         : %d KB', [LNow]));
    WriteLn(Format('  total delta       : %d KB (peak %d KB)',
      [LNow - LBaseline, LMaxDelta]));
    WriteLn(Format('  growth / 1000 req : %.2f KB', [LPerReq]));
    WriteLn('----------------------------------------------------------');
    // RSS is coarse, so the threshold is MB-scale TOTAL growth, not bytes. A real
    // per-request object leak over GMeasure requests shows MBs of RSS climb (the
    // -dPROBE_LEAK positive control proves the signal fires); normal allocator
    // variation after warm-up stays within a few hundred KB and does NOT climb
    // row over row. Read the table: a leak RISES; noise wanders. The
    // AUTHORITATIVE check is the -gh two-count comparison, not this number.
    if (LNow - LBaseline) > 1024 then
      WriteLn('  VERDICT: RSS GROWTH - possible leak; CONFIRM with the -gh two-count run.')
    else
      WriteLn('  VERDICT: no sustained RSS growth - consistent with NO per-request leak.');
    WriteLn('  AUTHORITATIVE: run -gh at two request counts; unfreed blocks that');
    WriteLn('  scale with the count = per-request leak; constant = fixed retention.');
  finally
    LClient.RequestBody := nil;   // client does NOT own it - detach before free
    LBody.Free;
    LClient.Free;
  end;
end;

// ─────────────────────────────────────────────────────────────────────────────
var
  LServer: TServerThread;
begin
  GWarmup  := StrToIntDef(ParamStr(1), DEFAULT_WARMUP);
  GMeasure := StrToIntDef(ParamStr(2), DEFAULT_MEASURE);
  GChunk   := StrToIntDef(ParamStr(3), DEFAULT_CHUNK);
  if GChunk <= 0 then GChunk := DEFAULT_CHUNK;

  WriteLn('=== horse-provider-mormot leak probe ===');
  WriteLn(Format('host=%s port=%d  warmup=%d measure=%d chunk=%d',
    [TEST_HOST, TEST_PORT, GWarmup, GMeasure, GChunk]));

  RegisterRoutes;

  LServer := TServerThread.Create(True);   // created suspended
  LServer.FreeOnTerminate := False;
  try
    LServer.Start;

    if not WaitServerReady(5000) then
    begin
      WriteLn('[probe] FATAL: server did not become ready on ',
        TEST_HOST, ':', TEST_PORT, ' within 5 s');
      THorse.StopListen;
      LServer.WaitFor;
      Halt(2);
    end;
    WriteLn('[probe] server ready.');

    try
      RunProbe;
    except
      on E: Exception do
        WriteLn('[probe] ERROR during probe: ', E.ClassName, ': ', E.Message);
    end;

    // Clean teardown so the -gh exit dump reflects only genuine retention:
    // StopListen drains + frees the server; the pool is freed by its class
    // destructor at finalization.
    THorse.StopListen;
    LServer.WaitFor;
    WriteLn('[probe] server stopped.');
  finally
    LServer.Free;
  end;

  WriteLn('[probe] done. (If built with -gh, the heaptrc dump follows below.)');
end.
