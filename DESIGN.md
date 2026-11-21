# Design: XCOM 2 WotC Co-op

Co-op-mod for **XCOM 2: War of the Chosen** (UnrealScript, WotC SDK + X2WOTCCommunityHighlander).
Dette dokumentet er kilden til sannhet for designet. Alle tall som nevnes her skal ligge i
[`XComCoop/Config/XComCoop.ini`](XComCoop/Config/XComCoop.ini), ikke hardkodes.

---

## 1. Nettverk

- **Steam-lobby**, hvem som helst av spillerne kan hoste.
- **Verten regner ut** odds og RNG. Klienten viser bare resultatet.
- Alt skjer **automatisk**, uten godkjenn-knapper.
- **Kampanjen synkes til begge** etter lagring og etter hvert oppdrag, slik at den andre kan hoste neste gang.
- **Modliste og versjon sjekkes ved tilkobling.** Avvik gir en tydelig feilmelding, ikke en halvveis synket kampanje.

## 2. Strategi / Geoscape

- **Avenger er felles.** Klikker én av spillerne for å flytte skipet, flyttes det hos begge.
- **Tiden går når en av spillerne skanner.** Den andre får varslene (hendelser, ferdig forskning osv.).

## 3. Avenger (menyer og basebygging)

- **Begge kan bruke alle menyer samtidig.** Endringer synkes som game state-deltaer.
- **Konflikter:**
  - Ressurser og rom: **først til mølla**.
  - Soldat som redigeres: **myk lås**. Den andre ser at soldaten er i bruk.
- **Optimistisk samtidighet** via objektversjoner. **Verten avgjør** ved konflikt.

## 4. Oppdrag (alene)

- **Hvem som helst kan starte et oppdrag alene.** Det kjøres på PC-en til den som startet det.
- Mens oppdraget pågår:
  - Geoscape-tiden er **fryst**.
  - Soldatene på oppdraget er **låst**.
  - Avenger kan fortsatt brukes (forskning, bygging, covert ops).
- **Ett oppdrag om gangen.**
- **Resultatet flettes additivt:** supplies, intel osv. *legges til* den felles kampanjen, de overskriver den ikke.

## 5. Taktisk co-op

- Starter spillerne oppdraget sammen fra lobbyen, **deles troppen likt**: 4 soldater gir 2 + 2.
  Ved oddetall får **den som startet** oppdraget den ekstra soldaten.
- **Hver spiller eier sine soldater.**
- **Felles XCOM-tur.** Turen slutter når alle soldater er ferdige, eller når begge har trykket *Avslutt tur*.
- **Handlinger behandles i den rekkefølgen de kommer inn** hos verten.

## 6. Bli med underveis (join in progress)

- Den som blir med kommer inn som **forsterkning med 2 soldater via Skyranger etter 2 turer**.
- **GTS-kjøp, Rapid Deployment:**

  | Nivå | Effekt | Krav | Pris |
  |------|--------|------|------|
  | Rapid Deployment I  | +1 soldat | Sergeant | 75 supplies |
  | Rapid Deployment II | +1 soldat | Major    | 150 supplies |

- **Resistance Order «Hot Drop»:** −1 tur ventetid.
- **Avveininger:**
  - ADVENT får forsterkninger som **skalerer** med forsterkningen.
  - Det **koster intel/supplies** å bli med.
  - **Ingen ekstra belønning** for å bli med.
  - Maks antall soldater er **troppstørrelse + forsterkning**.
  - Bare **én gang per oppdrag**.
  - Ikke mulig **under evakuering**.

## 7. Standardvalg

- **Ved brudd** går soldatene til den andre spilleren, og den som falt ut kan koble til igjen.
- **Ingen Ironman i v1.**
- **Kampanjen kan spilles alene.**
- **Soldatene er felles** (begge kan bruke alle soldater i strategilaget).
- **Pinger** kommer senere.
- **Angrep på Avenger og siste oppdrag krever begge spillerne fra start.**
  Gjelder `MissionSource_AvengerDefense`, `MissionSource_ChosenAvengerAssault` og `MissionSource_Final`.

## 8. Åpne spørsmål

Disse tallene er ikke bestemt ennå. De har foreløpige verdier i `XComCoop.ini`, merket `FORSLAG`:

- Hva det koster å bli med underveis (intel/supplies).
- Hvordan ADVENT-forsterkningene skalerer (antall, timing).
- Hvor lenge en myk lås på en soldat varer uten aktivitet.
- Tidsgrenser for heartbeat, brudd og ny tilkobling.

---

## Plan

### Fase 0: Grunnlag og usikkerheter
- Installer SDK og Highlander. Sett opp repo-strukturen.
- Test de største usikkerhetene:
  1. **Egne data over Steam fra UnrealScript.** Reserveplan: hjelpeapp via `TcpLink`/lokal TCP.
  2. **Sende og laste hele `XComGameStateHistory`.**
  3. **Strategi og taktisk parallelt på to maskiner**, med fletting.
  4. **Gå inn i strategidelen fra en mottatt historikk**, uten lagring bak. Spillet gjør det bare for taktisk.
- Kartlegging av klassene og forslag til testene: [docs/KARTLEGGING-NETTVERK.md](docs/KARTLEGGING-NETTVERK.md).

### Fase 1: Lobby
Lobby, invitasjon, sjekk av mods og versjon.
- Sjekken (`XComCoop_CompatInfo`) sammenligner protokollversjon, byggversjon av moden, Highlander-versjon og
  listen over aktive moder og DLC. Byggversjonen er git-commit pluss byggetidspunkt og skrives av `build.ps1`
  ved hvert bygg. Den fanger opp at én spiller ikke har fått siste Workshop-oppdatering.
- Avvik i spillets byggversjon gir bare en advarsel. `bRequireIdenticalModList=false` gjør avvik i modlisten om til advarsler.
- Flyten (`XComCoop_Session`, skjerm `XComCoop_UILobby`):
  1. Verten trykker CO-OP i hovedmenyen. Det lager en Steam-lobby og starter spillserveren (Steam sockets).
  2. Verten inviterer en venn fra listen på skjermen.
  3. Vennen får et spørsmål i spillet, blir med i lobbyen og kobler til lobbyeieren.
  4. Begge sender `XComCoop_CompatInfo`. Svaret er «klar», eller en liste over hva som er feil.
  5. Lobbyen forteller bare hvem verten er. All spilltrafikk går gjennom `XComGameStateNetworkManager`.
- Invitasjoner tas bare imot i hovedmenyen i fase 1. Oppstart av spillet fra en Steam-invitasjon kommer i fase 7.

### Fase 2: Strategisynk én vei
Verten sender, klienten speiler.
- Første steg: klienten får en kopi av kampanjen.
  1. Verten laster inn kampanjen, velger CO-OP i pausemenyen på Avengeren (rett før EXIT GAME) og inviterer.
  2. Når begge er koblet til og sjekket, trykker verten START CO-OP. `XComCoop_Session.StartCampaign` sender
     fingeravtrykket og så hele historikken med `SendHistory`.
  3. Klienten bekrefter med sitt fingeravtrykk, setter `bPerformingStandardLoad` og laster Avengeren som om den lastet
     en lagring (fase 0, test 4). Fremme sier den fra til verten, hvis forbindelsen fortsatt er oppe.
- Kopien lever sitt eget liv etterpå. Speiling av endringer hos verten er neste steg.
- Ukjent til testen med to PC-er: om forbindelsen overlever at klienten laster et nytt kart. Spillets egen flerspiller
  holder forbindelsen når begge åpner taktisk kart (`UIMPShell_Lobby.LoadTacticalMap`), så det er trolig.

### Fase 3: Strategisynk begge veier
Deltaer fra begge, objektversjoner, konflikthåndtering, myke låser.

### Fase 4: Oppdrag alene
Frys tid, lås soldater, additiv fletting av resultatet.

### Fase 5: Taktisk co-op
Deling av troppen, eierskap til soldater, felles tur, handlingskø hos verten.

### Fase 6: Bli med underveis og balanse
Skyranger-forsterkning, GTS Rapid Deployment, Hot Drop, ADVENT-skalering, kostnader.

### Fase 7: Robusthet og ekstra
Ny tilkobling etter brudd, synk av lagringer, spesialoppdrag (Avenger-angrep, siste oppdrag), pinger.
