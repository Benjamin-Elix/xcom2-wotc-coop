# xcom2-wotc-coop

Co-op-mod for **XCOM 2: War of the Chosen**. To spillere deler én kampanje: Avenger og soldatene er felles,
begge kan bruke Avenger samtidig, og oppdrag kan spilles alene eller sammen.

**Hele designet og planen står i [DESIGN.md](DESIGN.md).**

Status: **Fase 0**, grunnlag og tekniske tester. Moden gjør ingenting i spillet ennå.

## Krav

- XCOM 2: War of the Chosen
- [X2WOTCCommunityHighlander](https://steamcommunity.com/sharedfiles/filedetails/?id=1134256495) (påkrevd, sjekkes ved oppstart)
- For å bygge: **XCOM 2 War of the Chosen SDK** (Steam → Bibliotek → Verktøy)

## Struktur

```
xcom2-wotc-coop/
├── DESIGN.md                    Design og plan
├── CLAUDE.md                    Notater som Claude Code leser automatisk
├── docs/
│   └── KARTLEGGING-NETTVERK.md  Nettverks- og MP-klassene i spillet
├── XComCoop/                    ModBuddy-prosjektet
│   ├── XComCoop.x2proj          Prosjektfil (åpnes i ModBuddy)
│   ├── ReadMe.txt               Følger med moden
│   ├── Config/
│   │   ├── XComCoop.ini         Alle tall og innstillinger for co-op
│   │   ├── XComEditor.ini       Registrerer pakken for ModBuddy
│   │   ├── XComEngine.ini       Registrerer pakken for spillet
│   │   └── XComGame.ini         DLCIdentifier og krav om Highlander
│   └── Src/XComCoop/Classes/
│       ├── X2DownloadableContentInfo_XComCoop.uc   Inngangspunkt for moden
│       └── XComCoop_Config.uc                      Leser XComCoop.ini
```

## Bygge

Moden bygges med [X2ModBuildCommon](https://github.com/X2CommunityCore/X2ModBuildCommon) (v1.2.1, git-undermodul).

1. Installer SDK-en og abonner på Highlander i Workshop.
2. Klon med undermodulen: `git clone --recursive <repo>`. Har du allerede klonet: `git submodule update --init`.
3. Lag `.vscode/settings.json` med stiene på din maskin (filen er ikke i git):
   ```json
   {
       "xcom.highlander.sdkroot": "E:\\SteamLibrary\\steamapps\\common\\XCOM 2 War of the Chosen SDK",
       "xcom.highlander.gameroot": "E:\\SteamLibrary\\steamapps\\common\\XCOM 2\\XCom2-WarOfTheChosen"
   }
   ```
4. Bygg i VS Code med **Ctrl+Shift+B**. Det går også i ModBuddy (åpne `XComCoop/XComCoop.x2proj`).

Første bygg kompilerer hele spillet med Highlanders endringer og tar noen minutter. Senere bygg går fortere.
Den ferdige moden havner i `<spill>\XComGame\Mods\XComCoop`.

## Innstillinger

Alle tall (troppsdeling, forsterkning, GTS-priser, tidsgrenser osv.) står i
[`XComCoop/Config/XComCoop.ini`](XComCoop/Config/XComCoop.ini). Koden leser dem via `class'XComCoop_Config'.default.<Navn>`.
Verdier merket `FORSLAG` er foreløpige.
