# Kartlegging: nettverk og flerspiller i WotC

Kartlagt 2026-11-19 fra `XCOM 2 War of the Chosen SDK\Development\SrcOrig`.
Stier under er relative til `SrcOrig\` med mindre noe annet står. Linjenumre gjelder SDK-versjonen som er installert nå.

## Kort svar på de tre usikkerhetene i fase 0

| # | Usikkerhet | Svar fra koden | Må testes |
|---|---|---|---|
| 1 | Egne data over Steam fra UnrealScript | **Ja, på to måter.** Rå Steam P2P (`SendP2PData`/`ReadP2PData`) og `XComGameStateNetworkManager.SendRemoteCommand(string, array<byte>)`. Lobby med invitasjoner og binærdata finnes også. | At det virker utenfor MP-menyen, og hvor store meldinger tåler |
| 2 | Sende og laste hele `XComGameStateHistory` | **Ja.** `SendHistory`/`OnReceiveHistory`, `SendPartialHistory` (deltaer), `SendMergeGameState`, og `ReadHistoryFromFile`/`WriteHistoryToFile`. Alt er native. | At en strategi-historikk overlever turen, og hvor lang tid det tar |
| 3 | Strategi og taktisk parallelt + fletting | **Må bygges selv.** Spillet har én historikk, og taktisk bygges oppå strategien. `ObjectID` kan ikke settes fra UnrealScript, så to maskiner vil lage kolliderende ID-er. | Hele fletteopplegget |

Reserveplanen (hjelpeapp via `TcpLink`) trengs trolig ikke. `IpDrv\Classes\TcpLink.uc` finnes hvis den skulle trengs likevel.

---

## Lag 1: Steam (`OnlineSubsystemSteamworks`)

`OnlineSubsystemSteamworks\Classes\OnlineGameInterfaceXCom.uc`. Hentes via `OnlineGameInterfaceXCom(OnlineSub.GameInterface)`.

| Funksjon | Linje | Bruk for oss |
|---|---|---|
| `CreateLobby(MaxPlayers, Type, InitialSettings)` | 298 | Fase 1: verten lager lobby |
| `JoinLobby` / `LeaveLobby` | 426 / 493 | Fase 1 |
| `InviteToLobby(LobbyId, PlayerId)` + `OnLobbyInvite` | 947 / 956 | Fase 1: invitasjon |
| `GameBootIsFromInvite`, `GetLobbyFromCommandline` | 1005 / 991 | Spillet startet fra Steam-invitasjon |
| `SetLobbySetting` / `SetLobbyUserSetting` | 888 / 504 | **Modliste og versjon** i lobbydata, sjekkes før tilkobling |
| `SendLobbyMessage` / `SendLobbyBinaryData` + `OnLobbyReceive*` | 513 / 521 | Små meldinger via lobbyen |
| `SetLobbyServer(LobbyId, ServerUID, IP)` + `OnLobbyJoinGame` | 909 / 812 | Forteller klienten hvem som er vert |
| `SendP2PData` / `ReadP2PData` / `AcceptP2PSessionWithUser` | 283–288 | Rå Steam P2P, uten noe XCOM-lag |
| `SetLobbyOwner` | 938 | Ny vert, f.eks. ved bytte av hvem som hoster |

Flyten Firaxis selv brukte er beskrevet i en kommentar i `XComGame\Classes\XComCheatManager.uc:3766-3789`:
vert `CreateLobby` → klient `JoinLobby` → vert `PublishSteamServer` + `SetLobbyServer` → begge klare for P2P.

## Lag 2: transport for game state (`XComGameStateNetworkManager`)

`XComGame\Classes\XComGameStateNetworkManager.uc`. Hentes med makroen `` `XCOMNETMANAGER ``. Native, med UnrealScript-API.

- **Tilkobling:** `CreateServer(URL)`, `CreateClient(URL)`, `ForceConnectionAttempt()`, `Disconnect()` (244–254).
  Med `URL.Op.AddItem("steamsockets")` går det over Steam (se `UIMPShell_Lobby.uc:505-524`).
  Nettverksdriveren er `OnlineSubsystemSteamworks.IpNetDriverSteamworks` (spillets `XComGame\Config\DefaultEngine.ini:102`),
  og navnene er `MPListenServer`/`MPClient` (453–454).
- **Egne kommandoer:** `SendRemoteCommand(string Command, array<byte> Params)` + delegaten `OnReceiveRemoteCommand` (311–314).
  Hjelpere for å pakke parametre: `AddCommandParam_String/Int/Bool` og `GetCommandParam_*` (235–241).
  **Dette er hovedkanalen vår for strategisynk.**
- **Game state:** `SendHistory`, `SendPartialHistory`, `SendGameState`, `SendMergeGameState`, `SendGameStateContext`,
  hver med sin `OnReceive*`-delegat (320–359).
- **Robusthet som følger med:** data deles i biter («bunches») og sendes på nytt ved tap (`NetworkResendTimeout`, 126).
  Heartbeat, validering og oppdaging av desynk (`eConnectionValidationState`, `SendValidateConnection`,
  `GenerateValidationReport`), og `OnNotifyConnectionClosed` ved brudd.
- **Fallgruve:** finnes det ingen `OnNotifyConnectionClosed`-delegat når forbindelsen ryker, sender spillet deg til
  hovedmenyen (441–445). Vi **må** registrere en egen delegat.
- **Fallgruve:** `SubmitContextToRuleset` (295–305) sender mottatte contexts rett til `` `TACTICALRULES ``. I strategilaget er den
  `none`. Strategisynk kan derfor ikke bruke den innebygde context-sendingen. Vi bruker egne kommandoer.

## Lag 3: regelsett og contexts

- `X2GameRuleset.uc:226-245`: når en context sendes inn og det finnes tilkoblinger, legges den i sendekøen automatisk hvis
  `Context.bSendGameState` er satt (`XComGameStateContext.uc:22`, setter `SetSendGameState` på 498).
  Contexts fra nettverket får `bNetworkAdded` og **spilles av med samme tilfeldighetsfrø** som hos avsenderen
  (`SetEngineRandSeedFromContext`).
- Både `X2StrategyGameRuleset` og `X2TacticalGameRuleset` arver fra `X2GameRuleset`.
- `X2TacticalGameRuleset.UnitActionPlayerIsRemote()` (4132) finnes allerede for å skille lokal og ekstern spiller.

### Slik gjør vanlig MP det (forbilde for fase 5)

`X2TacticalMPGameRuleset.uc`: **spilleren som har turen regner ut alt** og sender `SendPartialHistory` (348–354) til
den andre. Turbytte og slutt på kampen går som remote commands (`SwitchTurn` 1223, `EndTacticalGame` 1566).
Lobbyen (`UIMPShell_Lobby.uc`) sender hele historikken med `SendHistory` (757–761), og klientens lag med
`SendGameState` (2029).

**For co-op** må vi snu dette til «**verten regner alltid**»: klienten sender sin handling som context, verten kjører den
og sender `SendPartialHistory` tilbake. Klienten kjører aldri regler selv.

## Lag 4: historikk og ObjectID

`XComGame\Classes\XComGameStateHistory.uc`:
- `WriteHistoryToFile` / `ReadHistoryFromFile` (475 / 468), `ArchiveHistory` (285).
- `GetStartState` / `FindStartStateIndex` (343 / 348): skillet mellom strategi og taktisk i historikken.
- `GetNextObjectID()` (431): **native og løpende**. ID-er deles ut fra den lokale historikken.

`XComGameState_BaseObject.uc:13`: `var() privatewrite int ObjectID;`. UnrealScript kan ikke sette ID-er selv.

## Lag 5: strategi ↔ taktisk

- **Til taktisk:** `XGStrategy.PrepareTacticalBattle` (200) og `LaunchTacticalBattle`. En kommentar der sier at strategilaget
  **ikke er helt basert på game state** («the strategy game is not yet operating using the game state system»).
  Det må undersøkes i fase 2.
- **Tilbake:** `XComGameStateContext_StrategyGameRule.CreateStrategyGameStartFromTactical` (237): tar strategi-tilstanden
  fra **før** oppdraget og fører alle objekter videre med endringene fra taktisk. Kommentaren på 271–273 sier rett ut at
  nye objekter fra taktisk ikke håndteres generelt.
- `CompleteStrategyFromTacticalTransfer` (324): `ProcessMissionResults`, `SquadTacticalToStrategyTransfer`, og til slutt
  `X2DownloadableContentInfo.OnPostMission()` for alle mods (340). **Det er et naturlig sted å hekte på flettingen.**

## Andre nyttige funn

- **Modliste:** `class'Helpers'.static.GetInstalledModNames()` (`Helpers.uc:103`).
- **Lagring:** `XComOnlineEventMgr.SaveGame(...)` / `LoadGame(...)` (3208 / 3214). `SaveGame` har `bPostMissionSave` og
  `PartialHistoryLength`.
- **Invitasjoner i vanlig MP:** `XComOnlineEventMgr.OnGameInviteAccepted` (3502), `CheckInviteGameVersionMismatch` (3593).
- **Highlander erstatter disse klassene** (de ligger i Highlanders `Src\XComGame`): `X2GameRuleset`, `X2TacticalGameRuleset`,
  `XComOnlineEventMgr`, `XGStrategy`, `XComGameStateContext_StrategyGameRule`, `XComGameStateContext_TacticalGameRule`.
  Vi kan ikke overstyre dem med `ModClassOverrides`. Vi må bruke Highlander-hendelser, eller be om nye hooks.
  `XComGameStateNetworkManager` og `OnlineGameInterfaceXCom` er **ikke** endret av Highlander.

---

## Den største risikoen: ObjectID-kollisjon (usikkerhet 3)

Spiller A spiller et oppdrag alene. Spiller B forsker og bygger imens. Begge starter med samme historikk, så begge
`GetNextObjectID()` gir **samme neste ID**. Et nytt rom hos B og et nytt loot-objekt hos A kan få ID 4711 begge to.
Siden ID-en ikke kan settes fra UnrealScript, kan vi ikke bare kopiere objekter fra den ene maskinen til den andre.

**Anbefaling:** **verten er den eneste som skriver i strategi-historikken.** Den som spilte oppdraget sender bare et
**resultatsammendrag** tilbake: hvilke soldater, HP/XP/drap/sår/død, loot som template-navn, om oppdraget lyktes, og
belønninger. Verten bruker det med vanlige spill-API-er, slik at nye objekter får ID-er fra vertens historikk.
Det passer med designet («resultatet flettes additivt») og unngår kollisjoner helt. Prisen er at alt i sammendraget
må håndteres eksplisitt, med egen kode for f.eks. reddede VIP-er, fangede soldater og Chosen-endringer.

## Forslag til fase 0-tester

Alle cheat managers (`XComShellCheatManager`, `XComHeadquartersCheatManager`, `XComTacticalCheatManager`) arver fra
`XComCheatManager`, så **MP-konsollkommandoene virker overalt**. Spillet startes med `-allowconsole`.

> **Viktig (funnet 2026-11-19):** Firaxis' MP-konsollkommandoer kjører, men **skriver ingenting i loggen**. Release-utgaven er bygget med
> `FINAL_RELEASE`, og da gjør `` `log `` ingenting (`Core\Globals.uci:56-60`). Første runde av test 1 ga derfor ikke noe svar.
> Bruk i stedet modens egne kommandoer i `X2DownloadableContentInfo_XComCoopTests.uc`: `CoopMyId`, `CoopP2PSend <hex>`,
> `CoopP2PAccept <hex>`, `CoopP2PRead` og `CoopP2PState <hex>`. De skriver til konsollen og til `Launch.log` med taggen `XComCoop`.
> Moden vår bygges uten `FINAL_RELEASE`, så `` `log `` virker der.

**Test 1, Steam-data (opprinnelig plan med Firaxis' kommandoer, gir ingen logg):** to PC-er, to Steam-kontoer som er venner.
1. Begge: `MPAddLobbyDelegates`
2. A: `MPCreateLobby`. Lobby-ID-en skal komme i `Launch.log` via `OnJoinLobbyComplete` (`LobbyUIDString`).
   Det er ikke bekreftet at den callbacken også kommer for den som lager lobbyen.
3. B: `MPJoinLobby <lobby-id i hex>`
4. A: `MPSendP2PData <Bs SteamID i hex>`. B: `MPReadP2PData`.
   SteamID i hex er SteamID64 (fra Steam-profilen) skrevet i hex, f.eks. `76561197970675231` → `1100001009ED61F`.
5. Sjekk `Launch.log` hos begge for linjer merket `XCom_Online`. Logglinjer med `XCom_Online`/`XCom_Net` kan være skjult
   av `Suppress=` i spillets config. I så fall må det fjernes.

**Test 2, send historikk:** testklassen finnes nå, se
`X2DownloadableContentInfo_XComCoopNetTest.uc` (kommandoer) og `XComCoop_NetTest.uc` (logikk).
1. A (i en kampanje, på Avenger): `CoopNetHost`. Det kaller `CreateServer` med port `TestNetPort` og `steamsockets`.
2. B (i hovedmenyen): `CoopNetJoin <As hex-ID fra CoopMyId>`. Det kaller `CreateClient`, og deretter
   `ForceConnectionAttempt` hvert `TestConnectRetrySeconds` til `OnPlayerJoined` kommer, slik
   `XComShellPresentationLayer.StartNetworkGame` / `OnSteamClientTimer` gjør (1103–1192).
3. A: `CoopNetSendHistory`. A sender først et fingeravtrykk av historikken som fjernkommando, så `SendHistory`.
   B svarer med fingeravtrykket av det som kom fram. A skriver ut tur-retur-tid og om avtrykkene er like.
   Avtrykket består av antall rammer, antall objekter, summen og maksimum av ObjectID-ene, soldater, supplies og dato.

Adressen klienten bruker over `steamsockets` er `steam.<SteamID64 i desimal>`. Formatstrengen `steam.%I64u`
står i `XCom2.exe`, og `StartNetworkGame` deler `<host>:<port>` på kolon. `CoopNetJoin` regner hex-ID-en
om til desimal selv, fordi `int` i UnrealScript bare er 32 bit.

Mottakeren får historikken rett inn i sin egen `XCOMHISTORY`. Lobbyen bruker den direkte etterpå
(`UIMPShell_Lobby.uc:820-824`, 1944–1949). B bør derfor stå i hovedmenyen og starte spillet på nytt etter testen.

Alene: `CoopHistoryInfo` skriver ut fingeravtrykket. `CoopHistoryToFile` skriver historikken med `WriteHistoryToFile`
til `Documents\My Games\XCOM2 War of the Chosen\XComGame\SaveData_Dev\XComCoop_History.x2hist`, ikke til spillmappen,
selv om kommentaren i `XComGameStateHistory.uc` sier `appGameDir()`.

Målt 20.11.2026, tidlig kampanje (1. mars 2035, 13 soldater): 1515 rammer, 898 objekter, **226 KB**. Det er omtrent
like stort som lagringsfilen for samme kampanje (224 KB). De største lagringsfilene på maskinen er rundt 7,3 MB, så
en sen kampanje er trolig 7–8 MB å sende.

**Invitasjoner til Steam-lobbyer (funnet 20.11.2026):** spillets egen flerspiller bruker *game sessions*
(`OnGameInviteAccepted` i `XComOnlineEventMgr.uc:3502`), ikke lobby-API-et. Lobby-API-et brukes bare av juksekommandoene.
Logglinjene i `XCom2.exe` viser hvordan en godtatt lobbyinvitasjon håndteres (`OnSteamAcceptLobbyInvite`):
«Triggering the lobby delegates» og «Creating the game information and firing autoinvite delegates».
Det er uklart om begge kjøres, eller bare én av dem. Kjøres den siste, kan spillet prøve å bruke vanlig flerspiller
(feilmelding eller hopp til MP-menyen) når invitasjonen godtas i Steam-overlayet. Derfor viser moden en egen
dialog når invitasjonen *mottas* (`OnLobbyInvite` med `bAccepted=false`), og kaller `JoinLobby` selv.
Testen med to PC-er må vise hva som skjer i begge tilfeller.

**Test 3, alene på én PC:** `XComCoop_MissionResult` (sammendrag og fletting) og `XComCoop_MergeTest` (kommandoer).
1. Last inn lagring A på Avenger og kjør `CoopMissionBegin`. Det tar et øyeblikksbilde av soldater, lager og alle objekt-ID-er.
2. Spill et oppdrag og kjør `CoopMissionSummary` når du er tilbake på Avenger, før noen forfremmes.
   Kommandoen skriver ut endringene per soldat og per type i lageret, og hvilke nye state-objekter oppdraget lagde.
3. Last inn lagring A på nytt og gjør noe på Avenger, for eksempel bygg eller kjøp noe.
4. Kjør `CoopMissionApply`. Sammendraget legges på som én ny game state, oppå det som skjedde imens.

Sammendraget bruker tall, ikke referanser. `KilledUnits` peker på fiender med ID-er fra oppdragssiden, så den flyttes ikke.
Rangen i WotC styres av drap (`KillCount`, `KillAssistsCount`, `BonusKills`, `NonTacticalKills`), og XP teller bare
med `bUseFullXpSystem`. Forfremmelse skjer i Armory når `CanRankUpSoldier()` sier ja, så det holder å flytte tellerne.
Rang, sår, død, fangenskap og nytt personell rapporteres foreløpig bare.

**Test 3, opprinnelig plan, parallelt + fletting:** krever kode. Bygg en minimal versjon av resultatsammendraget
(én soldat får XP, ett loot-objekt) og flett det inn hos verten mens verten har bygget noe imens.

**Test 4, alene på én PC: gå inn i strategidelen fra en historikk uten lagring.** Det er dette klienten må gjøre i
fase 2 etter å ha fått kampanjen til verten. Spillet gjør det bare for taktisk (challenge, ladder og flerspiller bruker
`ReadHistoryFromFile` og åpner kartet), aldri for strategi.

`XComHeadquartersGame.StartMatch` velger vei ut fra `ONLINEEVENTMGR.bPerformingStandardLoad`:
- Satt: `FinishLoadGame()` (native, laster de lagrede actorene), så `XGStrategy.OnLoadedGame()` og tilstanden
  `LoadingGame`. Dette er veien for en vanlig innlasting.
- Ikke satt, og historikken har mer enn én ramme: `XGStrategy.Init()` og så `TransferFromTactical`, altså flyten for
  hjemkomst etter et oppdrag. Én ramme betyr ny kampanje.

Flagget er en vanlig `var bool` og kan settes fra moden. Det ukjente er hva `FinishLoadGame` gjør når det ikke finnes
lagringsdata bak historikken. Highlander endrer ikke denne delen.

Kommandoer (`XComCoop_StrategyStartTest`):
1. Last inn en lagring på Avenger og kjør `CoopHistoryToFile` (fra test 2). Noter fingeravtrykket.
2. Avslutt spillet og start det på nytt, så ingenting fra lagringen ligger igjen i minnet.
3. I hovedmenyen: `CoopHistoryFromFile`. Fingeravtrykket skal være likt det fra steg 1.
4. `CoopStartStrategy` setter flagget, åpner `Avenger_Root` med `?LoadingSave` og later som det er en vanlig innlasting.
   `CoopStartStrategy plain` åpner uten flagget, for å se hjemkomst-veien.
5. På Avenger: `CoopStrategyCheck` skriver ut tilstanden til `XGStrategy`, om `OnLoadedSavedGameToStrategy` ble kjørt,
   og sammenligner soldater, supplies og høyeste ObjectID med filen. Se deg rundt, lagre og last inn den nye lagringen.

**Resultat 21.11.2026: virker.** `CoopStartStrategy` (med flagget) tok veien for innlastet lagring:
`OnLoadedSavedGameToStrategy` ble kjørt, og `XGStrategy` endte i `Headquarters`. `FinishLoadGame` uten lagringsdata
ga ingen feil, og `bPerformingStandardLoad` ble nullstilt av spillet. Soldater, supplies, objekter, ID-sum og høyeste
ID var like. Antall rammer gikk fra 1528 til 1535, som er det spillet selv legger til ved innlasting. Fra Avengeren
til ferdig innlastet tok det under 2 sekunder. Spilleren gjorde endringer, lagret, gikk til hovedmenyen og lastet den
nye lagringen uten feil. Advarslene i loggen (filmscener i `AVG_QuartersCommander`, `State_UINarrative`) finnes også
ved vanlige innlastinger. `plain` er ikke prøvd; det trengs ikke.

Klientens del av fase 2 blir dermed: ta imot historikken, sett `ONLINEEVENTMGR.bPerformingStandardLoad = true`, åpne
`Avenger_Root?game=XComGame.XComHeadQuartersGame?LoadingSave`.

## Fase 2: speiling av kampanjen (kartlagt 21.11.2026)

**Sende bare endringer.** `XComGameStateNetworkManager` holder for hver tilkobling en speilkopi av historikken
(`ConnectionInfo.HistoryMirror`, `EventManagerMirror`) og hvor langt den har sendt (`CurrentSendHistoryIndex`).
`SendPartialHistory(History, EventManager)` sender rammene den andre siden mangler, og mottakeren får
`OnReceivePartialHistory`. Det native laget kan også be om ny full historikk (`ReceiveRequestNewHistory`) eller en
delta (`ReceiveRequestDelta`), og har en vei for å oppdage avvik (`Desynchronize`).
Spillets flerspiller (`X2TacticalMPGameRuleset.uc:310-359`) sender `SendPartialHistory` ved turbytte. Mottakeren kaller
`RebuildLocalStateObjectCache` og svarer med kommandoen `HistoryReceived`, og avsenderen venter på det svaret før
den sender igjen (`bSendingPartialHistory`).

**Kontekst-sending passer ikke strategi.** `X2GameRuleset.SubmitGameStateContext` (226-249) legger contexts med
`bSendGameState` i sendekøen, og mottakeren kjører dem i `` `TACTICALRULES `` (`SubmitContextToRuleset`), som ikke
finnes i strategi. Speilingen bruker derfor `SendPartialHistory`.

**Oppdage endringer hos verten.** `XComGameStateHistory.RegisterOnNewGameStateDelegate` (129) kalles hver gang en ny
tilstand legges i historikken. Delegatene ryddes ved kartbytte (kommentar på linje 43 og 261), så de må registreres
på nytt etter hver innlasting.

**Oppdatere Avengeren hos klienten.** Strategi har ingen avspilling som taktisk. Skjermene leser data når de åpnes,
og noen få oppdateres når de blir bedt om det (`UIAvengerHUD.UpdateResources`, `UIFacilityGrid.UpdateData`).
Klienten må selv be skjermene oppdatere seg når det kommer endringer.

**Klientens egne endringer.** Klienten kjører sitt eget strategilag og kan lage tilstander selv: tid som går på
jordkloden, flagg for «sett», popup-er. Da sklir historikkene fra hverandre. Verktøy som finnes:
`ObliterateGameStatesFromHistory(Count)` (310) fjerner de siste rammene, og `AddHistoryLock`/`RemoveHistoryLock`
(483-484) skal hindre nye tilstander mens historikken er låst. Hvordan det native laget reagerer når klienten har
egne rammer, må testes med to PC-er.

**Ukjent før testen med to PC-er:** hva `OnReceivePartialHistory` gjør med rammer klienten har laget selv, og hvor
ofte verten lager nye tilstander under vanlig spill. Det siste kan måles alene.

**Måling 21.11.2026 (`CoopWatchStart`/`CoopWatchReport`, `XComCoop_ChangeWatch`):** 12,5 minutter vanlig spill på
Avenger og jordkloden ga 194 nye tilstander, 15,5 i minuttet. Til sammen 386 endrede objekter, i snitt 2 per
tilstand, høyst 17. Nesten alt er `ChangeContainer`-contexts. Tre grupper, med 64 ulike typer:
- **Spillerens valg** (om lag 15): `Adding Research Project`, `Adding Facility Project`, `Squad Selection`,
  `Set Pending Point Of Travel`, `Launch Mission Selected`.
- **Tid som går** (om lag halvparten): `Unit Recovered Will`, `Unit Healed`, `Update Scanning Site`, flyging
  (`Airship Flight Beginning/Completed`, `Update Skyranger location`), `Pause/Resume All Projects`, `Geoscape Pause`,
  `ResearchCompleted`, `Update Mission Calendar`. Bare verten kan eie tiden.
- **Bare ved å se på** (om lag en tredel): `Entered/Exited Facility` (0 objekter, bare hendelser),
  `First visit to Labs`, `Unmark needs attention`, popup-er merket som sett, `Trigger Objective Narrative Moment`
  (22 ganger), og troppvalget (`Blast Backpack and MissionItems`, 78 objekter; `Make Wounded Soldier Items Available`).
  Klienten lager disse selv når spilleren klikker rundt.

Følger for fase 2: verten kan sende etter hver endring, for mengden er liten. Klienten kan ikke styre tiden eller
ta valg. Klientens egne småendringer fra den tredje gruppen må kastes når nye rammer kommer fra verten, for eksempel
med `ObliterateGameStatesFromHistory`. Om spillet tåler det, kan testes alene.
