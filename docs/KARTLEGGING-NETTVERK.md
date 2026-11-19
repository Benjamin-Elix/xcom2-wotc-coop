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

**Test 2, send historikk (lite kode):** `MPCreateServer 7777 true` hos A, `MPCreateClient <A>` hos B, så
`MPCheckConnections`, og til slutt `MPSendHistory` fra en strategi-lagring. Mottakeren må ha registrert
`OnReceiveHistory`, ellers skjer ingenting synlig. Det krever en liten testklasse i moden.
Ukjent: hvilken adresse klienten skal bruke over `steamsockets` (trolig Steam-ID, ikke IP).

**Test 3, parallelt + fletting:** krever kode. Bygg en minimal versjon av resultatsammendraget
(én soldat får XP, ett loot-objekt) og flett det inn hos verten mens verten har bygget noe imens.
