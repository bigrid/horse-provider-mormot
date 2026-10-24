# mORMot provider — LCL memory-leak test (Lazarus 4.8 / FPC 3.2.2)

Reproduces and resolves the HashLoad/horse **#576** report *"the mORMot provider
also leaks memory"* for a **Lazarus LCL** application — the reporter's exact
environment (Lazarus 4.8 LCL, FPC 3.2.2 stable).

## What it is testing

The per-request pipeline is identical in console and LCL apps, and the console
probe (`../HorseMormotLeakProbe.lpr`) already proved **0 leaked blocks per
request** over 40,000 requests. So this test is **not** about per-request work —
it is about the **LCL lifecycle**:

- An LCL app uses `Interfaces + Forms + Application.Run`, so `IsConsole = False`.
- With `IsConsole = False`, the provider's `THorse.Listen` **does not block** — it
  returns once the server is bound and the LCL message loop keeps the app alive.
- The mORMot server is therefore torn down **only when the app calls
  `THorse.StopListen`**. If the app closes without it, the server + its thread
  pool + handler + drain event are never freed → heaptrc reports them at exit.

This program is a real (window-less) LCL app driven by a one-shot timer, so it
runs unattended under heaptrc. It pulls in `Horse.Provider.Mormot.FPC.LCL`, so
the LCL **shape unit** — which no other gate compiles — is compiled and linked.

## Fastest: scripted build + run (Windows, lazbuild)

The whole thing — build, three passes, verdict — is scripted. Defaults target
**Lazarus 4.8** (`C:\Lazarus\Lazarus_4_8\lazbuild.exe` driven with
`--pcp=C:\lazarus\cfg_4_8`, so it uses that config's FPC 3.2.2). The `.lpi`
already enables heaptrc (`-gh`) and the GUI subsystem, so there is nothing to
toggle.

PowerShell (recommended — it parses the logs and prints a verdict):

```powershell
cd <repo>\horse-provider-mormot\tests\Lazarus\lcl-leak
powershell -ExecutionPolicy Bypass -File .\run-lcl-leak.ps1
# Lazarus 3.2 instead:
powershell -ExecutionPolicy Bypass -File .\run-lcl-leak.ps1 -Lazbuild "C:\Lazarus\Lazarus_3_2\lazbuild.exe" -Pcp "C:\lazarus\cfg_3_2"
# skip the build, just run a prebuilt exe:
powershell -ExecutionPolicy Bypass -File .\run-lcl-leak.ps1 -NoBuild
```

Or `cmd`: `run-lcl-leak.bat` (same paths; prints the three `unfreed` lines via
`findstr`, no verdict).

If `lazbuild` rejects the hand-written `.lpi` (it is best-effort and version
dependent), open `HorseMormotLclLeakTest.lpr` in the IDE once — it offers to
create a project — set the options below, **Save** (that regenerates a correct
`.lpi`), and the scripts' `lazbuild` path then works.

## Build (Lazarus IDE, Windows)

1. **Project → New → Program** (not Application; we create no form), or open a new
   project and replace its `.lpr` with `HorseMormotLclLeakTest.lpr` and add
   `LeakDriver.pas`. The `.lpr` carries `{$APPTYPE GUI}`, so the binary is a
   GUI-subsystem app (`IsConsole = False`) regardless of IDE link flags — this is
   required, or `THorse.Listen` would block and the test would not reproduce the
   LCL lifecycle.
2. **Project → Project Options → Compiler Options → Paths → Other unit files**, add:
   - `..\..\..\src`            (the provider)
   - `<Horse>\src`
   - `<mORMot2>\src` and its subfolders (`core`, `net`, `crypt`, `lib`, …)
3. **Custom Options**: add `-dHORSE_PROVIDER_MORMOT`.
4. **Debugging**: tick **Use Heaptrc unit (-gh)** and **Generate debugging info
   (-g)** / line info (`-gl`) so block backtraces are readable.
5. **LCL widget type**: `win32` (default on Windows).
6. Build.

`lazbuild` works too once you have saved the `.lpi` the IDE generates.

## Run — the two-run heaptrc protocol

heaptrc writes its dump to a file when the `HEAPTRC` environment variable names
one (so a window-less GUI app does not need a console). From **cmd**:

```
set HEAPTRC=log=issue.log
HorseMormotLclLeakTest.exe --nostop

set HEAPTRC=log=fixed.log
HorseMormotLclLeakTest.exe
```

Optional — prove repeated start/stop is clean:

```
set HEAPTRC=log=cycles.log
HorseMormotLclLeakTest.exe --cycles 20
```

A `lcl-leak-run.log` beside the exe records what each run did.

## Reading the result

Look at the last lines of each heaptrc log:

```
NNN unfreed memory blocks : NNN
```

- **`fixed.log`** (stopped cleanly) → **0 unfreed** (or only a small fixed set of
  LCL/widgetset blocks that also appear in `issue.log`). **This is the fix.**
- **`issue.log`** (`--nostop`) → **more** unfreed blocks than `fixed.log`, whose
  `Call trace` names the mORMot server (`THttpServer` / thread pool / `TEvent`).
  **This is the bug: the server was never stopped before the app closed.**
- **`cycles.log`** → the same count as `fixed.log` (not 20× it): `StopListen`
  frees each server, so repeated start/stop does not accumulate.

The **difference** between `issue.log` and `fixed.log` is the leak. heaptrc may
list a handful of LCL/widgetset blocks in **both** logs — that is framework noise,
not the provider; it cancels in the comparison. (Compare counts, and read the
`Call trace` entries that appear only in `issue.log`.)

## The resolution

Call **`THorse.StopListen`** before the LCL app exits. The provider ships a host
form that does exactly this for you — inherit your main form from
**`TfrmHorseMormotLCLHost`** (`Horse.Provider.Mormot.FPC.LCL`), which calls
`THorse.StopListen` in both `OnClose` and the destructor. The leak in #576 is
consistent with an app that calls `THorse.Listen` directly and closes without
ever stopping the server.

If `fixed.log` is **not** 0 — i.e. the server leaks even after `StopListen` — then
it is a real provider defect on the LCL path; send `issue.log` + `fixed.log` and
the `horse-provider-mormot` / `mORMot2` commits and it can be traced from the
block backtraces.

## Note

This targets **Windows/Lazarus** (the #576 environment). On Linux the `Interfaces`
widgetset (gtk2/qt5) needs a display; run it under Windows, or adapt to the
`nogui`/`customdrawn` widgetset if a headless Linux run is wanted.
