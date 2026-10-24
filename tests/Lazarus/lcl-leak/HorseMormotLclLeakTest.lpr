program HorseMormotLclLeakTest;

(*
  LCL memory-leak test for horse-provider-mormot (Lazarus 4.8 / FPC 3.2.2).
  A real LCL application (Interfaces + Forms + Application.Run => IsConsole =
  False), driven headlessly by a one-shot timer. See LeakDriver.pas for the full
  description and README.md for the build + two-run heaptrc protocol.

  Arguments:
    (none)           Listen -> fire -> StopListen -> Terminate      (THE FIX)
    --nostop         Listen -> fire ->              Terminate        (THE BUG)
    --cycles N       N start/stop cycles then Terminate              (FIX, repeated)
    --measure N      requests fired per cycle (default 2000)
*)

{$MODE DELPHI}{$H+}
{$APPTYPE GUI}   // GUI subsystem => IsConsole = False, the whole premise of this
                 // test; a plain console Program would make THorse.Listen BLOCK
                 // and would NOT reproduce the LCL lifecycle. Output goes to
                 // lcl-leak-run.log and heaptrc's HEAPTRC=log= file, not stdout.

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Interfaces,   // LCL widgetset => a genuine LCL app, IsConsole = False
  Forms,
  SysUtils,
  LeakDriver;

  function ArgFlag(const AName: string): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := 1 to ParamCount do
      if SameText(ParamStr(I), AName) then
        Exit(True);
  end;

  function ArgValue(const AName: string; const ADefault: Integer): Integer;
  var
    I: Integer;
  begin
    Result := ADefault;
    for I := 1 to ParamCount - 1 do
      if SameText(ParamStr(I), AName) then
        Exit(StrToIntDef(ParamStr(I + 1), ADefault));
  end;

var
  LDriver: TLeakDriver;
begin
  RequireDerivedFormResource := False;   // this project has no .lfm at all
  Application.Initialize;
  LDriver := TLeakDriver.Create(Application);   // owned by Application; freed on shutdown
  LDriver.Configure(ArgFlag('--nostop'),
                    ArgValue('--cycles', 1),
                    ArgValue('--measure', 2000));
  LDriver.Start;
  Application.Run;
end.
