unit LeakDriver;

(*
  horse-provider-mormot - LCL memory-leak test driver  (Lazarus / FPC)
  ====================================================================
  Reproduces AND resolves the HashLoad/horse #576 "the mORMot provider also
  leaks memory" report for a Lazarus LCL application (Lazarus 4.8, FPC 3.2.2
  stable).

  This is a REAL LCL app: the program uses Interfaces + Forms + Application.Run,
  so IsConsole = False exactly as in the reporter's GUI app. That is the whole
  point - when IsConsole = False the mORMot provider's THorse.Listen does NOT
  block; it returns as soon as the server is bound and the LCL message loop
  keeps the app alive, so the server is torn down ONLY when the app calls
  THorse.StopListen (which is what TfrmHorseMormotLCLHost does on FormClose).

  There is no visible window; a one-shot TTimer drives the whole run and then
  calls Application.Terminate, so the app runs unattended under heaptrc.

  TWO modes, one -gh binary:
    (default)   Listen -> fire requests -> StopListen -> Terminate   = THE FIX
    --nostop    Listen -> fire requests ->              Terminate     = THE BUG
                (the app closed WITHOUT stopping the server, so the mORMot
                 server + its thread pool + handler + drain event are never
                 freed; heaptrc lists them as unfreed blocks at exit)
    --cycles N  N x (Listen -> fire -> StopListen) then Terminate      = THE FIX
                under repetition, proving start/stop does not accumulate.

  The per-request pipeline is identical to the console probe (which measured 0
  leak per request over 40k requests), so this test is about the LCL LIFECYCLE,
  not per-request work.

  Read the result with heaptrc's exit dump, TWO runs compared (see README):
    set HEAPTRC=log=issue.log  then run with --nostop
    set HEAPTRC=log=fixed.log  then run with no arguments
  issue.log carries the retained mORMot server blocks; fixed.log should report
  0 unfreed (or only a small fixed set). The DIFFERENCE is the leak.

  NB on comments: this file keeps every brace/star comment delimiter and every
  dollar-directive OUT of the prose, so a stray one cannot close a comment early.
*)

{$MODE DELPHI}{$H+}

interface

uses
  Classes,
  SysUtils,
  ExtCtrls;

type
  TLeakDriver = class(TComponent)
  private
    FTimer:   TTimer;
    FNoStop:  Boolean;
    FCycles:  Integer;
    FMeasure: Integer;
    procedure OnTick(Sender: TObject);
    procedure FireRequests(ACount: Integer);
    procedure LogLn(const AMsg: string);
  public
    procedure Configure(ANoStop: Boolean; ACycles, AMeasure: Integer);
    procedure Start;
  end;

implementation

uses
  Forms,
  fphttpclient,
  Horse,
  Horse.Provider.Mormot,
  Horse.Provider.Mormot.Pool,
  Horse.Provider.Mormot.FPC.LCL;   // compile + link the LCL shape unit under test

const
  LEAK_PORT     = 9219;
  PING_SENTINEL = 'horse-mormot-lcl-leak-pong-9219';
  PROBE_BODY    = '{"probe":"lcl-leak","s":"the quick brown fox 0123456789"}';
  RUN_LOG       = 'lcl-leak-run.log';

// Routes - plain unit-scope procedures (register with no @ so FPC Delphi mode
// promotes them to THorseCallbackRequestResponse).
procedure RoutePing(Req: THorseRequest; Res: THorseResponse);
begin
  Res.ContentType('text/plain').Send(PING_SENTINEL);
end;

procedure RouteEcho(Req: THorseRequest; Res: THorseResponse);
begin
  Res.AddHeader('X-Probe-Echo', Req.Headers['X-Probe']);
  Res.Cookie('probe', 'v1').Path('/').HttpOnly(True);
  Res.ContentType('application/json; charset=utf-8')
     .Send('{"ok":true,"blen":' + IntToStr(Length(Req.Body)) + '}');
end;

procedure TLeakDriver.LogLn(const AMsg: string);
var
  F: TextFile;
begin
  try
    AssignFile(F, RUN_LOG);
    if FileExists(RUN_LOG) then
      Append(F)
    else
      Rewrite(F);
    try
      WriteLn(F, Format('[%s] %s', [FormatDateTime('hh:nn:ss', Now), AMsg]));
    finally
      CloseFile(F);
    end;
  except
    // logging must never break the test
  end;
end;

procedure TLeakDriver.Configure(ANoStop: Boolean; ACycles, AMeasure: Integer);
begin
  FNoStop  := ANoStop;
  FCycles  := ACycles;
  FMeasure := AMeasure;
  if FNoStop then
    FCycles := 1;                // one unstopped server is the clean demonstration
  if FCycles  < 1 then FCycles  := 1;
  if FMeasure < 0 then FMeasure := 0;
end;

procedure TLeakDriver.Start;
begin
  // Register routes ONCE - routes live in THorseCore, independent of Listen.
  THorse.Get('/ping',  RoutePing);
  THorse.Post('/echo', RouteEcho);

  LogLn(Format('start: nostop=%s cycles=%d measure=%d port=%d IsConsole=%s',
    [BoolToStr(FNoStop, True), FCycles, FMeasure, LEAK_PORT,
     BoolToStr(IsConsole, True)]));

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 300;
  FTimer.OnTimer  := OnTick;
  FTimer.Enabled  := True;
end;

procedure TLeakDriver.FireRequests(ACount: Integer);
var
  LClient: TFPHTTPClient;
  LBody:   TStringStream;
  I:       Integer;
  LReady:  Boolean;
begin
  LClient := TFPHTTPClient.Create(nil);
  LBody   := TStringStream.Create(PROBE_BODY);
  try
    // Readiness (bounded): the server is bound when Listen returns, but guard
    // the first request against a race anyway.
    LReady := False;
    for I := 1 to 40 do
    begin
      try
        if Pos(PING_SENTINEL,
               LClient.Get(Format('http://127.0.0.1:%d/ping', [LEAK_PORT]))) > 0 then
        begin
          LReady := True;
          Break;
        end;
      except
        // not up yet - retry
      end;
      Sleep(50);
    end;
    if not LReady then
    begin
      LogLn('server did not become ready');
      Exit;
    end;

    LClient.KeepConnection := True;
    LClient.AddHeader('Content-Type', 'application/json; charset=utf-8');
    LClient.AddHeader('X-Probe', 'lcl');
    LClient.RequestBody := LBody;
    for I := 1 to ACount do
    begin
      LBody.Position := 0;
      LClient.Post(Format('http://127.0.0.1:%d/echo', [LEAK_PORT]));
    end;
  finally
    LClient.RequestBody := nil;   // client does NOT own it
    LBody.Free;
    LClient.Free;
  end;
end;

procedure TLeakDriver.OnTick(Sender: TObject);
var
  I: Integer;
begin
  FTimer.Enabled := False;        // one-shot
  try
    for I := 1 to FCycles do
    begin
      THorse.Listen(LEAK_PORT);   // non-blocking in an LCL app (IsConsole = False)
      LogLn(Format('cycle %d: listening, firing %d requests', [I, FMeasure]));
      FireRequests(FMeasure);
      if FNoStop then
        LogLn('cycle ' + IntToStr(I) + ': NOT stopping (reproducing the leak)')
      else
      begin
        THorse.StopListen;        // the FIX - what TfrmHorseMormotLCLHost does on close
        LogLn('cycle ' + IntToStr(I) + ': stopped');
      end;
    end;
    LogLn('done; terminating (heaptrc dump follows at exit)');
  except
    on E: Exception do
      LogLn('ERROR: ' + E.ClassName + ': ' + E.Message);
  end;
  Application.Terminate;
end;

end.
