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
- **Ingen referanser fra objekter som lever hele spillet til actors eller skjermer.** Det gjelder klassens standardobjekt
  (CDO), `UIScreenListener`, og delegater registrert på nettverksmanageren eller Steam-grensesnittene som peker på
  en skjerm. Slike referanser hindrer at det gamle kartet ryddes bort, og spillet krasjer når en lagring lastes
  («World ... not cleaned up by garbage collection»). Slå opp skjermen når du trenger den. La skjermen selv spørre
  etter endringer med en timer på seg selv (se `XComCoop_UILobby.Poll`). Timere og delegater skal peke *fra*
  actoren *til* det varige objektet, ikke omvendt.
- **Lag aldri en Steam-lobby** (`CreateLobby`). Spillet starter da en Steam-spillserver som tar over alle
  Steam-tilkoblingene til spillet lukkes, og ID-en dens kan ikke leses fra skriptet. Se
  [docs/KARTLEGGING-NETTVERK.md](docs/KARTLEGGING-NETTVERK.md).
- **Kall aldri `Disconnect`** (eller `StartServer`, som kobler fra) inne i `OnNotifyConnectionClosed` uten å bytte
  tilstand først. Spillet melder da den samme tilkoblingen på nytt, og det går i ring til spillet krasjer.
- **Slå på Steam-relé før hver co-op-tilkobling** (`XComCoop_Util.SetSteamRelay`, før `CreateServer`/`CreateClient`).
  Spillet slår det av når Steam starter. Uten relé når ikke to vanlige hjemmenett hverandre: forespørselen kommer
  aldri fram til verten. Se [docs/KARTLEGGING-NETTVERK.md](docs/KARTLEGGING-NETTVERK.md).
- **Timere for objekter som ikke er actors** (`XComCoop_Session`, testklassene) går gjennom `XComCoop_Timers`
  (`Schedule`, `Cancel`, `IsScheduled`). Aldri `WorldInfo.SetTimer`: `WorldInfo` har `bTickIsDisabled=true` i
  XCOM 2, så tidtakere på den går aldri av.

## Bygge

Byggeverktøy: X2ModBuildCommon v1.2.1 (git-undermodul i `.scripts/X2ModBuildCommon`), inngang `.scripts/build.ps1`.
Highlanders kildekode tas med automatisk fra Workshop-mappen (kan overstyres med `X2_HIGHLANDER_SRC`).

```
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File .scripts\build.ps1 -srcDirectory "C:\Users\benja\xcom2-wotc-coop" -sdkPath "E:\SteamLibrary\steamapps\common\XCOM 2 War of the Chosen SDK" -gamePath "E:\SteamLibrary\steamapps\common\XCOM 2\XCom2-WarOfTheChosen" -config default
```

I VS Code: Ctrl+Shift+B. Den ferdige moden havner i `<spill>\XComGame\Mods\XComCoop`.
