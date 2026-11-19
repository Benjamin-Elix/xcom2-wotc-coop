# xcom2-wotc-coop

Co-op-mod for XCOM 2: War of the Chosen. **Les [DESIGN.md](DESIGN.md) før du endrer noe.** Den har designet og fasene.
Brukeren skriver norsk; svar på norsk.

## Stier på denne maskinen

- Spill (WotC): `E:\SteamLibrary\steamapps\common\XCOM 2\XCom2-WarOfTheChosen`
- SDK: `E:\SteamLibrary\steamapps\common\XCOM 2 War of the Chosen SDK`
  - Originalkilde: `Development\SrcOrig`
  - Kartlegging av nettverk/MP-klassene: [docs/KARTLEGGING-NETTVERK.md](docs/KARTLEGGING-NETTVERK.md)
- Highlander (Workshop 1134256495): `E:\SteamLibrary\steamapps\workshop\content\268500\1134256495`
  - `Src\XComGame` har **bare de ~344 filene Highlander endrer**, ikke hele XComGame. Bruk SrcOrig for resten.
- Spillogg: `%USERPROFILE%\Documents\My Games\XCOM2 War of the Chosen\XComGame\Logs\Launch.log`

## Konvensjoner

- Alle tall og innstillinger ligger i `XComCoop/Config/XComCoop.ini` og leses via `XComCoop_Config`
  (`config(Coop)` → `XComCoop.ini`). Nye tall legges til begge steder. Ingen hardkoding.
- INI: kommentarer på egen linje, aldri bak en verdi.
- Pakke, DLCName og DLCIdentifier heter `XComCoop`.
- Nye filer bør føres opp i `XComCoop/XComCoop.x2proj` så de vises i ModBuddy (byggeverktøyet tar med alt i mappen uansett).
- Lokaliseringsfiler (`.int` osv.) lagres som UTF-8. X2ModBuildCommon gjør dem om til UTF-16 ved bygging.

## Bygge

Byggeverktøy: X2ModBuildCommon v1.2.1 (git-undermodul i `.scripts/X2ModBuildCommon`), inngang `.scripts/build.ps1`.
Highlanders kildekode tas med automatisk fra Workshop-mappen (kan overstyres med `X2_HIGHLANDER_SRC`).

```
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File .scripts\build.ps1 -srcDirectory "C:\Users\benja\xcom2-wotc-coop" -sdkPath "E:\SteamLibrary\steamapps\common\XCOM 2 War of the Chosen SDK" -gamePath "E:\SteamLibrary\steamapps\common\XCOM 2\XCom2-WarOfTheChosen" -config default
```

I VS Code: Ctrl+Shift+B. Den ferdige moden havner i `<spill>\XComGame\Mods\XComCoop`.
