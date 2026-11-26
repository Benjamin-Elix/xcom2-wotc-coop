//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_Config.uc
//  PURPOSE: All tunable values for the co-op mod. Values live in Config/XComCoop.ini
//           (config(Coop) maps to XComCoop.ini). Read them via
//           class'XComCoop_Config'.default.<Name>. Never hardcode these numbers elsewhere.
//---------------------------------------------------------------------------------------
class XComCoop_Config extends Object config(Coop);

struct RapidDeploymentTier
{
	var int ExtraSoldiers;
	var int RequiredRank;   // 3 = Sergeant, 6 = Major
	var int SupplyCost;
};

// --- Network and connection ---
var config int              ProtocolVersion;
var config int              MaxPlayers;
var config bool             bRequireIdenticalModList;
var config array<string>    ModsIgnoredInCompatCheck;   // DLCNames
var config int              NetPort;
var config float            ConnectRetrySeconds;
var config int              ConnectAttempts;
var config float            ServerRestartDelaySeconds;
var config bool             bAllowSteamRelay;           // see XComCoop_Util.SetSteamRelay
var config float            HeartbeatIntervalSeconds;
var config float            DisconnectTimeoutSeconds;
var config float            ReconnectWindowSeconds;     // 0 = no limit
var config float            CampaignLoadDelaySeconds;
var config float            MirrorSendDelaySeconds;
var config float            MirrorAckTimeoutSeconds;
var config float            MirrorGuardSeconds;
var config int              MirrorMaxResyncs;
var config float            MirrorClockSeconds;
var config float            MirrorMoverSeconds;
var config float            OpenScreenRefreshSeconds;
var config float            ClientTimeFreezeSeconds;

// --- User interface ---
var config float            MainMenuButtonCheckSeconds;
var config float            LobbyRefreshSeconds;

// --- Strategy and Avenger ---
var config float            SoldierSoftLockTimeoutSeconds;
var config int              MaxConcurrentMissions;

// --- Tactical co-op ---
var config bool             bExtraSoldierToMissionStarter;
var config bool             bTransferUnitsOnDisconnect;

// --- Join in progress ---
var config bool             bAllowJoinInProgress;
var config int              JoinBaseSoldiers;
var config int              JoinDelayTurns;
var config int              MaxJoinsPerMission;
var config bool             bBlockJoinDuringEvac;
var config int              JoinCostSupplies;
var config int              JoinCostIntel;
var config float            AdventReinforcementsPerJoinedSoldier;
var config int              HotDropTurnReduction;
var config array<RapidDeploymentTier> RapidDeploymentTiers;

// --- Campaign ---
var config bool             bAllowIronman;
var config bool             bEnablePings;
var config array<name>      MissionSourcesRequiringBothPlayers;

// --- Phase 0 tests (remove when phase 0 is done) ---
var config int              TestNetPort;
var config float            TestConnectRetrySeconds;
var config int              TestConnectAttempts;
