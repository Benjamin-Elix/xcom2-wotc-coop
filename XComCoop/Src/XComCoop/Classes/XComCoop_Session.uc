//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_Session.uc
//  PURPOSE: The co-op session. Owns the Steam lobby, the network connection, the
//           compatibility check (phase 1) and handing the host's campaign to the client
//           (phase 2), and tells the UI when anything changes.
//
//  Host:   Host() -> CreateLobby -> start the game server (Steam sockets) -> Invite(friend)
//  Client: invite received -> popup -> Join() -> connect to the player who sent the invite
//          (the client does not join the Steam lobby; see Join)
//  Both:   connected -> exchange XComCoop_CompatInfo -> Ready, or Failed with clear reasons
//
//  Phase 2, first step (the client gets a copy of the host's campaign):
//  Host on the Avenger, Ready: StartCampaign() -> announce fingerprint -> SendHistory
//  Client: history arrives (it replaces XCOMHISTORY) -> confirm with its fingerprint ->
//          load the Avenger as if loading a save (phase 0 test 4) -> tell the host it arrived
//
//  Phase 2, mirroring (the client watches the host's campaign as it changes):
//  Host:   every new game state marks the history dirty; after MirrorSendDelaySeconds it
//          sends CMD_MIRROR and then SendPartialHistory (only the frames the client lacks).
//          One send at a time; the client's ACK carries its fingerprint. A mismatch makes
//          the host send the whole campaign again (at most MirrorMaxResyncs times).
//  Client: watches only. Its own game states (rooms entered, popups seen, time on the
//          Geoscape) are thrown away with ObliterateGameStatesFromHistory (phase 2 test 5):
//          when CMD_MIRROR arrives, so the host's frames land on a clean history, and by a
//          guard timer every MirrorGuardSeconds in case the order is not kept.
//
//  The lobby only tells the client who the host is; all game traffic goes through
//  XComGameStateNetworkManager. The class default object (Get()) holds the state, so it
//  survives map changes and is never garbage collected.
//---------------------------------------------------------------------------------------
class XComCoop_Session extends Object dependson(XComCoop_CompatInfo);

enum ECoopSessionState
{
	eCoopState_Idle,
	eCoopState_CreatingLobby,       // host: waiting for Steam
	eCoopState_WaitingForPlayer,    // host: lobby open, server listening
	eCoopState_JoiningLobby,        // client: waiting for Steam
	eCoopState_Connecting,          // client: connecting to the host
	eCoopState_Checking,            // both: connected, comparing versions and mods
	eCoopState_Ready,               // both: connected and compatible
	eCoopState_SendingCampaign,     // host: campaign sent, waiting for the client to confirm
	eCoopState_LoadingCampaign,     // client: receiving the campaign, then loading the Avenger
	eCoopState_InCampaign,          // both: the client mirrors the host's campaign
	eCoopState_Failed,              // see Problems
};

// Remote commands. Not the same names as the phase 0 tests.
const CMD_COMPAT = "XComCoopLobbyCompat";
const CMD_CAMPAIGN = "XComCoopCampaign";            // host -> client: fingerprint of what follows
const CMD_CAMPAIGN_ACK = "XComCoopCampaignAck";     // client -> host: fingerprint of what arrived
const CMD_ARRIVED = "XComCoopArrived";              // client -> host: on the Avenger, in sync, mirroring can start
const CMD_MIRROR = "XComCoopMirror";                // host -> client: changes follow, drop your own now
const CMD_MIRROR_ACK = "XComCoopMirrorAck";         // client -> host: history index and fingerprint after the changes
const CMD_CLOCK = "XComCoopClock";                  // host -> client: the Geoscape clock (year, month, day, second)
const CMD_MOVE = "XComCoopMove";                    // host -> client: position of a flying airship (id, x, y, z, pitch, yaw, roll)
const CMD_POPUP = "XComCoopPopup";                  // host -> client: a popup the host was shown (DynamicPropertySet)
const CMD_HOST_MISSION = "XComCoopHostMission";     // host -> client: the host went on a mission

// How many popups wait at most on either side (a safety cap, not a gameplay value).
const MAX_POPUPS = 20;

// The "watching" banner on the client's Avenger HUD (screen layout in pixels).
const WATCH_BANNER_NAME = 'XComCoopWatchBanner';
const WATCH_BANNER_WIDTH = 600;
const WATCH_BANNER_Y = 10;

// Wire format for CMD_MOVE: positions are sent as ints scaled by this (not a gameplay value).
const MOVE_SCALE = 100000.0;

// Client: an airship gliding from where it is to the last position the host sent.
struct CoopMoverLerp
{
	var int ObjectID;
	var Vector From;
	var Vector To;
	var float StartTime;
};

// A popup in the CMD_POPUP wire format (see WritePopup).
struct CoopPopupData
{
	var array<byte> Data;
};

// Enters strategy the way a normal save load does (see XComCoop_StrategyStartTest).
const STRATEGY_LOAD_COMMAND = "open Avenger_Root?game=XComGame.XComHeadQuartersGame?LoadingSave";

var ECoopSessionState SessionState;
var bool bIsHost;
var UniqueNetId LobbyId;
var UniqueNetId HostId;
var string OtherPlayerName;
var array<string> Problems;     // why we failed, shown to the player
var array<string> Warnings;     // shown but not blocking
var array<string> Notices;      // short info lines, e.g. "invite sent"

var bool bLobbyDelegatesAdded;
var bool bNetDelegatesAdded;
var bool bCompatSent;
var bool bInLobby;
var int ConnectAttemptsLeft;

// Phase 2: handing over the campaign
var string SentFingerprint;         // host
var float CampaignSendTime;         // host, Util.Now() when sent
var string ExpectedFingerprint;     // client, from CMD_CAMPAIGN
var string ReceivedFingerprint;     // client, of the history that arrived
var int ReceivedHistoryIndex;       // client, last index of the history that arrived

// Phase 2: mirroring after the client has arrived
var int CampaignSentIndex;          // host: history index when the whole campaign was sent
var bool bClientLoading;            // host: the client is loading the campaign, send nothing
var bool bMirrorDirty;              // host: the history changed since the last send
var bool bAwaitingMirrorAck;        // host: a send is on its way
var float MirrorSendTime;           // host, Util.Now() of the last send
var string MirrorSentFingerprint;   // host, fingerprint at the last send
var int MirrorSent;                 // host: number of sends
var int MirrorResyncs;              // host: whole campaign sent again after a mismatch
var int SyncedIndex;                // client: last history index that came from the host
var bool bMirrorReady;              // client: arrived and in sync, mirroring runs
var int MirrorReceived;             // client: number of updates applied
var int MirrorRolledBack;           // client: own game states thrown away

// The Geoscape clock runs in memory and is only written to the history when time stops
// (XGGeoscape.Pause). The host sends it on its own so the client's clock follows.
var int ClockYear, ClockMonth, ClockDay, ClockSecond;   // host: last sent; client: last received
var bool bHaveHostClock;            // client

// Airships (Avenger, Skyranger, UFOs) move by changing their state objects in place every
// frame (XComStrategyMap.UpdateMovers), without new game states, so the mirroring cannot
// see a flight. The host sends positions while something flies; the client glides there.
var array<int> MoversInFlight;      // host: object IDs that were flying at the last send
var array<CoopMoverLerp> MoverLerps; // client

// Popups are queued in XComHQ and removed again in the same frame they are shown, so the
// mirroring never carries them. The host sends each shown popup after the update it
// belongs to; the client shows it as soon as the game allows (same rules as on the host).
var array<CoopPopupData> PopupsToSend;  // host
var array<CoopPopupData> PopupsToShow;  // client

var bool bHostInMission;            // both: the host is on a mission; the client waits for the results
var bool bScreenRefreshPending;     // client: the open screen should be redrawn
var float LastScreenRefresh;        // client, Util.Now() of the last redraw
var bool bResendWhenReady;          // host: send the whole campaign once strategy has loaded

// An invite that arrived while we were not in a lobby, waiting for the player's answer.
var UniqueNetId PendingInviteLobbyId;
var UniqueNetId PendingInviteFriendId;      // who sent it; the client connects to this player

// Goes up by one on every change. The lobby screen polls it with its own timer. The session
// lives for the whole game, so it must never hold a reference to a screen or other actor:
// the old map could then not be garbage collected and loading a save crashes.
var int ChangeCount;

var localized string strCreateLobbyFailed;
var localized string strJoinLobbyFailed;
var localized string strServerFailed;
var localized string strConnectFailed;
var localized string strConnectionLost;
var localized string strPlayerLeft;
var localized string strInviteSent;
var localized string strInviteFailed;
var localized string strSomeone;
var localized string strInviteTitle;
var localized string strInviteText;
var localized string strInviteAccept;
var localized string strInviteDecline;
var localized string strInviteNotInMenu;
var localized string strNotOnAvenger;
var localized string strIronmanNotSupported;
var localized string strCampaignReceived;
var localized string strCampaignMismatch;
var localized string strCampaignInvalid;
var localized string strClientArrived;
var localized string strArrivedClient;
var localized string strConnectionLostLoading;
var localized string strMirrorResync;
var localized string strMirrorGaveUp;
var localized string strHostOnMission;
var localized string strWatchBanner;
var localized string strWatchBannerMission;

static function XComCoop_Session Get()
{
	return XComCoop_Session(class'XComEngine'.static.GetClassDefaultObject(class'XComCoop_Session'));
}

// --- Setup -----------------------------------------------------------------------------------

/// Registers the lobby delegates. Called from the main menu, so invites are caught even
/// before the player opens the co-op screen.
function Init()
{
	local OnlineGameInterfaceXCom GameInterface;
	local OnlinePlayerInterface PlayerInterface;

	if (bLobbyDelegatesAdded)
	{
		return;
	}
	GameInterface = class'XComCoop_Util'.static.GetGameInterface();
	if (GameInterface == none)
	{
		Say("Session: Steam game interface not available, co-op is disabled");
		return;
	}
	GameInterface.AddCreateLobbyCompleteDelegate(HandleCreateLobbyComplete);
	GameInterface.AddJoinLobbyCompleteDelegate(HandleJoinLobbyComplete);
	GameInterface.AddLobbyMemberStatusUpdateDelegate(HandleLobbyMemberStatusUpdate);
	GameInterface.AddLobbyInviteDelegate(HandleLobbyInvite);
	bLobbyDelegatesAdded = true;

	// Warm up the friends list so names are known when an invite arrives.
	PlayerInterface = class'XComCoop_Util'.static.GetPlayerInterface();
	if (PlayerInterface != none)
	{
		PlayerInterface.ReadFriendsList(0);
	}
	Say("Session: ready for co-op invites");
}

function AddNetDelegates()
{
	local XComGameStateNetworkManager NetMgr;

	if (bNetDelegatesAdded)
	{
		return;
	}
	bNetDelegatesAdded = true;
	NetMgr = `XCOMNETMANAGER;
	NetMgr.AddReceiveRemoteCommandDelegate(HandleRemoteCommand);
	NetMgr.AddReceiveHistoryDelegate(HandleReceiveHistory);
	NetMgr.AddReceivePartialHistoryDelegate(HandleReceivePartialHistory);
	NetMgr.AddPlayerJoinedDelegate(HandlePlayerJoined);
	NetMgr.AddNotifyAcceptedConnectionDelegate(HandleAcceptedConnection);
	// Without this the game returns to the main menu when the connection closes.
	NetMgr.AddNotifyConnectionClosedDelegate(HandleConnectionClosed);
}

// --- Commands from the UI --------------------------------------------------------------------

/// Creates a Steam lobby and starts listening for the other player.
function Host()
{
	local OnlineGameInterfaceXCom GameInterface;
	local EOnlineGameInterfaceXCom_LobbyVisibility Visibility;

	if (IsActive())
	{
		return;
	}
	Reset();
	Init();
	GameInterface = class'XComCoop_Util'.static.GetGameInterface();
	if (GameInterface == none)
	{
		Fail(strCreateLobbyFailed);
		return;
	}

	bIsHost = true;
	SetState(eCoopState_CreatingLobby);
	Visibility = class'XComCoop_Config'.default.bLobbyVisibleToFriends ? XLV_Friends : XLV_Private;
	if (!GameInterface.CreateLobby(class'XComCoop_Config'.default.MaxPlayers, Visibility))
	{
		Fail(strCreateLobbyFailed);
	}
}

/// Answers an invite: connects straight to the player who sent it.
///
/// The client does not join the Steam lobby. When a second member joins, the game's
/// native Steam lobby code on the host crashes (access violation in XCom2.exe while
/// handling the Steam lobby callback, 2026-11-22). The game's own multiplayer never
/// uses Steam lobbies, only cheats do. The invite already says who the host is, and that
/// is all the lobby was used for.
function Join(UniqueNetId InLobbyId, UniqueNetId InviterId)
{
	if (IsActive())
	{
		Leave();
	}
	Reset();
	Init();

	bIsHost = false;
	LobbyId = InLobbyId;
	HostId = InviterId;
	OtherPlayerName = class'XComCoop_Util'.static.GetFriendName(HostId);
	Say("Session: answering the invite from " $ OtherName() $ " without joining the Steam lobby");
	Connect();
}

/// Invites a friend to our lobby (host only).
function bool Invite(UniqueNetId FriendId, string FriendName)
{
	local OnlineGameInterfaceXCom GameInterface;
	local bool bOk;

	if (!bIsHost || !bInLobby)
	{
		return false;
	}
	GameInterface = class'XComCoop_Util'.static.GetGameInterface();
	bOk = GameInterface != none && GameInterface.InviteToLobby(LobbyId, FriendId);
	Notices.AddItem(Repl(bOk ? strInviteSent : strInviteFailed, "%PLAYER", FriendName));
	Say("Session: invite to " $ FriendName $ " " $ (bOk ? "sent" : "FAILED"));
	NotifyChanged();
	return bOk;
}

/// Host only: back to waiting for a player after a failed check.
function ResumeHosting()
{
	if (!bIsHost || !bInLobby)
	{
		return;
	}
	Problems.Length = 0;
	Warnings.Length = 0;
	OtherPlayerName = "";
	bCompatSent = false;
	if (!StartServer())
	{
		Fail(strServerFailed);
		return;
	}
	SetState(eCoopState_WaitingForPlayer);
}

/// Leaves the lobby and closes the connection. With bKeepProblems the state ends as
/// Failed and the reasons stay visible; otherwise it ends as Idle.
function Leave(optional bool bKeepProblems)
{
	local OnlineGameInterfaceXCom GameInterface;
	local XComGameStateNetworkManager NetMgr;
	local array<string> KeptProblems, KeptWarnings;

	if (bKeepProblems)
	{
		KeptProblems = Problems;
		KeptWarnings = Warnings;
	}

	StopMirroring();

	// Set the state first, so the connection-closed callback knows this was on purpose.
	SessionState = eCoopState_Idle;
	ConnectAttemptsLeft = 0;

	NetMgr = `XCOMNETMANAGER;
	if (NetMgr.HasServerConnection() || NetMgr.HasClientConnection())
	{
		NetMgr.Disconnect();
	}
	if (bInLobby)
	{
		GameInterface = class'XComCoop_Util'.static.GetGameInterface();
		if (GameInterface != none)
		{
			GameInterface.LeaveLobby(LobbyId);
		}
		bInLobby = false;
	}
	Say("Session: left");
	Reset();
	if (bKeepProblems && KeptProblems.Length > 0)
	{
		Problems = KeptProblems;
		Warnings = KeptWarnings;
		SessionState = eCoopState_Failed;
	}
	NotifyChanged();
}

function bool IsActive()
{
	return SessionState != eCoopState_Idle && SessionState != eCoopState_Failed;
}

// --- Lobby callbacks -------------------------------------------------------------------------

function HandleCreateLobbyComplete(bool bWasSuccessful, UniqueNetId InLobbyId, string Error)
{
	Say("Session: lobby created=" $ bWasSuccessful $ " id=" $ class'XComCoop_Util'.static.IdToHex(InLobbyId) $ " error='" $ Error $ "'");
	if (!bIsHost || SessionState != eCoopState_CreatingLobby)
	{
		return;
	}
	if (!bWasSuccessful)
	{
		Fail(strCreateLobbyFailed $ (Error != "" ? " (" $ Error $ ")" : ""));
		return;
	}

	LobbyId = InLobbyId;
	bInLobby = true;
	class'XComCoop_Util'.static.GetMyId(HostId);
	if (!StartServer())
	{
		Fail(strServerFailed);
		return;
	}
	SetState(eCoopState_WaitingForPlayer);
}

function HandleJoinLobbyComplete(bool bWasSuccessful, const out array<OnlineGameInterfaceXCom_ActiveLobbyInfo> LobbyList, int LobbyIndex, UniqueNetId LobbyUID, string Error)
{
	local OnlineGameInterfaceXCom GameInterface;

	Say("Session: joined lobby=" $ bWasSuccessful $ " id=" $ class'XComCoop_Util'.static.IdToHex(LobbyUID) $ " error='" $ Error $ "'");

	// CreateLobby also joins the new lobby, so the host gets this too.
	if (bIsHost || SessionState != eCoopState_JoiningLobby || LobbyUID != LobbyId)
	{
		return;
	}
	if (!bWasSuccessful)
	{
		Fail(strJoinLobbyFailed $ (Error != "" ? " (" $ Error $ ")" : ""));
		return;
	}
	bInLobby = true;

	GameInterface = class'XComCoop_Util'.static.GetGameInterface();
	if (!GameInterface.GetLobbyAdmin(LobbyId, HostId))
	{
		Fail(strJoinLobbyFailed);
		return;
	}
	OtherPlayerName = class'XComCoop_Util'.static.GetFriendName(HostId);
	Connect();
}

function HandleLobbyMemberStatusUpdate(const out array<OnlineGameInterfaceXCom_ActiveLobbyInfo> LobbyList, int LobbyIndex, int MemberIndex, int InstigatorIndex, string Status)
{
	Say("Session: lobby member " $ MemberIndex $ " status '" $ Status $ "'");
}

/// Called when an invite arrives (bAccepted=false) or when the player accepted one in the
/// Steam overlay (bAccepted=true).
function HandleLobbyInvite(UniqueNetId InLobbyId, UniqueNetId FriendId, bool bAccepted)
{
	local string FriendName;

	FriendName = class'XComCoop_Util'.static.GetFriendName(FriendId);
	if (FriendName == "")
	{
		FriendName = strSomeone;
	}
	Say("Session: invite from " $ FriendName $ " to lobby " $ class'XComCoop_Util'.static.IdToHex(InLobbyId) $ " accepted=" $ bAccepted);

	if (InLobbyId == LobbyId && IsActive())
	{
		return;
	}

	if (!class'XComCoop_Util'.static.IsInShell())
	{
		// Phase 1 only joins from the main menu.
		ShowMessage(strInviteTitle, Repl(strInviteNotInMenu, "%PLAYER", FriendName));
		return;
	}

	if (bAccepted)
	{
		AcceptInvite(InLobbyId, FriendId);
		return;
	}

	PendingInviteLobbyId = InLobbyId;
	PendingInviteFriendId = FriendId;
	ShowInviteDialog(FriendName);
}

function ShowInviteDialog(string FriendName)
{
	local XComPresentationLayerBase Pres;
	local TDialogueBoxData DialogData;

	Pres = class'XComCoop_Util'.static.GetPres();
	if (Pres == none)
	{
		return;
	}
	DialogData.eType = eDialog_Normal;
	DialogData.strTitle = strInviteTitle;
	DialogData.strText = Repl(strInviteText, "%PLAYER", FriendName);
	DialogData.strAccept = strInviteAccept;
	DialogData.strCancel = strInviteDecline;
	DialogData.fnCallback = HandleInviteDialog;
	Pres.UIRaiseDialog(DialogData);
}

function HandleInviteDialog(Name eAction)
{
	local UniqueNetId EmptyId;

	if (eAction == 'eUIAction_Accept' && PendingInviteFriendId != EmptyId)
	{
		AcceptInvite(PendingInviteLobbyId, PendingInviteFriendId);
	}
	PendingInviteLobbyId = EmptyId;
	PendingInviteFriendId = EmptyId;
}

function AcceptInvite(UniqueNetId InLobbyId, UniqueNetId InviterId)
{
	class'XComCoop_UILobby'.static.Open();
	Join(InLobbyId, InviterId);
}

function ShowMessage(string Title, string Text)
{
	local XComPresentationLayerBase Pres;
	local TDialogueBoxData DialogData;

	Pres = class'XComCoop_Util'.static.GetPres();
	if (Pres == none)
	{
		return;
	}
	DialogData.eType = eDialog_Normal;
	DialogData.strTitle = Title;
	DialogData.strText = Text;
	DialogData.strAccept = class'UIUtilities_Text'.default.m_strGenericOK;
	Pres.UIRaiseDialog(DialogData);
}

// --- Network ---------------------------------------------------------------------------------

function bool StartServer()
{
	local XComGameStateNetworkManager NetMgr;
	local URL ServerURL;
	local string Error;

	NetMgr = `XCOMNETMANAGER;
	if (NetMgr.HasServerConnection() || NetMgr.HasClientConnection())
	{
		NetMgr.Disconnect();
	}
	AddNetDelegates();
	ServerURL.Port = class'XComCoop_Config'.default.NetPort;
	ServerURL.Op.AddItem("steamsockets");
	NetMgr.CreateServer(ServerURL, Error);
	Say("Session: server on port " $ ServerURL.Port $ " error='" $ Error $ "'");
	return Error == "";
}

function Connect()
{
	local XComGameStateNetworkManager NetMgr;
	local URL ClientURL;
	local string Error;

	NetMgr = `XCOMNETMANAGER;
	if (NetMgr.HasServerConnection() || NetMgr.HasClientConnection())
	{
		NetMgr.Disconnect();
	}
	AddNetDelegates();
	ClientURL.Host = class'XComCoop_Util'.static.IdToSteamAddress(HostId);
	ClientURL.Port = class'XComCoop_Config'.default.NetPort;
	ClientURL.Op.AddItem("steamsockets");
	SetState(eCoopState_Connecting);
	NetMgr.CreateClient(ClientURL, Error);
	Say("Session: connecting to " $ ClientURL.Host $ ":" $ ClientURL.Port $ " error='" $ Error $ "'");
	if (Error != "")
	{
		Fail(strConnectFailed);
		return;
	}

	// Same as the game's own flow: ask the host for a connection after a short delay.
	ConnectAttemptsLeft = class'XComCoop_Config'.default.ConnectAttempts;
	ScheduleConnectAttempt();
}

function ScheduleConnectAttempt()
{
	class'Engine'.static.GetCurrentWorldInfo().SetTimer(class'XComCoop_Config'.default.ConnectRetrySeconds, false, nameof(ConnectAttempt), self);
}

function ConnectAttempt()
{
	if (SessionState != eCoopState_Connecting)
	{
		return;
	}
	if (ConnectAttemptsLeft <= 0)
	{
		Problems.AddItem(strConnectFailed);
		Leave(true);
		return;
	}
	ConnectAttemptsLeft--;
	`XCOMNETMANAGER.ForceConnectionAttempt();
	ScheduleConnectAttempt();
}

function HandlePlayerJoined(string RequestURL, string Address, const UniqueNetId UniqueId, bool bSupportsAuth)
{
	Say("Session: connected to the host");
	if (SessionState != eCoopState_Connecting)
	{
		return;
	}
	SetState(eCoopState_Checking);
	SendCompat();
}

function HandleAcceptedConnection(int ConnectionIdx)
{
	Say("Session: the other player connected");
	if (bIsHost && SessionState == eCoopState_WaitingForPlayer)
	{
		// The client sends its compatibility info first; we answer when it arrives.
		SetState(eCoopState_Checking);
	}
}

function HandleConnectionClosed(int ConnectionIdx)
{
	Say("Session: connection closed in state " $ StateName());
	if (bIsHost)
	{
		switch (SessionState)
		{
		case eCoopState_Checking:
		case eCoopState_Ready:
		case eCoopState_SendingCampaign:
		case eCoopState_InCampaign:
			// Keep the lobby open so the host can invite again.
			StopMirroring();
			Notices.AddItem(Repl(strPlayerLeft, "%PLAYER", OtherName()));
			OtherPlayerName = "";
			bCompatSent = false;
			StartServer();
			SetState(eCoopState_WaitingForPlayer);
			break;
		default:
			break;
		}
		return;
	}

	switch (SessionState)
	{
	case eCoopState_Checking:
	case eCoopState_Ready:
		Problems.AddItem(strConnectionLost);
		Leave(true);
		break;
	case eCoopState_LoadingCampaign:
		if (ReceivedFingerprint == "")
		{
			// Lost before the campaign arrived: nothing to load.
			Problems.AddItem(strConnectionLost);
			Leave(true);
		}
		else
		{
			// We have the campaign; load it anyway and report the lost connection.
			Notices.AddItem(strConnectionLostLoading);
			NotifyChanged();
		}
		break;
	case eCoopState_InCampaign:
		// Nothing more will come; stop throwing away what the player does.
		StopMirroring();
		Notices.AddItem(strConnectionLost);
		NotifyChanged();
		break;
	default:
		break;
	}
}

function HandleRemoteCommand(string Command, array<byte> RawParams)
{
	if (Command == CMD_COMPAT)
	{
		HandleCompatCommand(RawParams);
	}
	else if (Command == CMD_CAMPAIGN)
	{
		HandleCampaignCommand(RawParams);
	}
	else if (Command == CMD_CAMPAIGN_ACK)
	{
		HandleCampaignAck(RawParams);
	}
	else if (Command == CMD_ARRIVED)
	{
		HandleArrived(RawParams);
	}
	else if (Command == CMD_MIRROR)
	{
		HandleMirrorCommand();
	}
	else if (Command == CMD_MIRROR_ACK)
	{
		HandleMirrorAck(RawParams);
	}
	else if (Command == CMD_CLOCK)
	{
		HandleClock(RawParams);
	}
	else if (Command == CMD_MOVE)
	{
		HandleMove(RawParams);
	}
	else if (Command == CMD_POPUP)
	{
		HandlePopup(RawParams);
	}
	else if (Command == CMD_HOST_MISSION)
	{
		HandleHostMission();
	}
}

// --- Compatibility check ---------------------------------------------------------------------

function HandleCompatCommand(array<byte> RawParams)
{
	// The client's info can arrive before the host has seen the accepted connection.
	if (bIsHost && SessionState == eCoopState_WaitingForPlayer)
	{
		SetState(eCoopState_Checking);
	}
	if (SessionState != eCoopState_Checking)
	{
		return;
	}
	if (!bCompatSent)
	{
		SendCompat();
	}
	CheckCompat(RawParams);
}

function SendCompat()
{
	local array<byte> Data;

	class'XComCoop_CompatInfo'.static.BuildLocal().WriteBytes(Data);
	`XCOMNETMANAGER.SendRemoteCommand(CMD_COMPAT, Data);
	bCompatSent = true;
	Say("Session: sent compatibility info (" $ Data.Length $ " bytes)");
}

function CheckCompat(array<byte> Data)
{
	local XComCoop_CompatInfo RemoteInfo;
	local array<string> NewProblems, NewWarnings;
	local int i;

	RemoteInfo = class'XComCoop_CompatInfo'.static.ReadBytes(Data);
	if (RemoteInfo != none && RemoteInfo.PlayerName != "")
	{
		OtherPlayerName = RemoteInfo.PlayerName;
	}

	Warnings.Length = 0;
	if (class'XComCoop_CompatInfo'.static.Compare(class'XComCoop_CompatInfo'.static.BuildLocal(), RemoteInfo, NewProblems, NewWarnings))
	{
		Warnings = NewWarnings;
		Say("Session: compatible with " $ OtherPlayerName $ " (" $ Warnings.Length $ " warnings)");
		SetState(eCoopState_Ready);
		return;
	}

	Say("Session: NOT compatible with " $ OtherPlayerName);
	for (i = 0; i < NewProblems.Length; i++)
	{
		Say("  problem: " $ NewProblems[i]);
	}
	Problems = NewProblems;
	Warnings = NewWarnings;
	if (bIsHost)
	{
		// The client leaves; the host keeps the lobby, shows why and can try again.
		SetState(eCoopState_Failed);
	}
	else
	{
		Leave(true);
	}
}

// --- Phase 2: hand the campaign to the client ------------------------------------------------

/// Host: can the campaign be sent now? Reason is empty when the button simply does not apply.
function bool CanStartCampaign(out string Reason)
{
	local XComGameState_CampaignSettings Settings;

	Reason = "";
	if (!bIsHost || SessionState != eCoopState_Ready)
	{
		return false;
	}
	if (!class'XComCoop_Util'.static.IsInStrategy())
	{
		Reason = strNotOnAvenger;
		return false;
	}
	Settings = XComGameState_CampaignSettings(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_CampaignSettings', true));
	if (Settings == none)
	{
		Reason = strNotOnAvenger;
		return false;
	}
	if (Settings.bIronmanEnabled && !class'XComCoop_Config'.default.bAllowIronman)
	{
		Reason = strIronmanNotSupported;
		return false;
	}
	return true;
}

/// Host: sends the whole campaign. The client confirms with CMD_CAMPAIGN_ACK.
function StartCampaign()
{
	local string Reason;

	if (!CanStartCampaign(Reason))
	{
		if (Reason != "")
		{
			Notices.AddItem(Reason);
			NotifyChanged();
		}
		return;
	}
	MirrorResyncs = 0;
	SendCampaign();
}

/// Host: announces the fingerprint and sends the whole history. Also used to get the
/// client back in sync after a mismatch.
function SendCampaign()
{
	local XComGameStateNetworkManager NetMgr;
	local array<byte> Params;

	NetMgr = `XCOMNETMANAGER;
	bClientLoading = true;
	bAwaitingMirrorAck = false;
	bMirrorDirty = false;
	SentFingerprint = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	CampaignSentIndex = `XCOMHISTORY.GetCurrentHistoryIndex();
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(SentFingerprint, Params);
	NetMgr.SendRemoteCommand(CMD_CAMPAIGN, Params);
	CampaignSendTime = class'XComCoop_Util'.static.Now();
	NetMgr.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	Say("Session: campaign sent to " $ OtherName() $ ", index " $ CampaignSentIndex $ ", fingerprint " $ SentFingerprint);
	SetState(eCoopState_SendingCampaign);
}

/// Client: the host announces the campaign that follows (the first time, or again to get
/// back in sync).
function HandleCampaignCommand(array<byte> RawParams)
{
	if (bIsHost || (SessionState != eCoopState_Ready && SessionState != eCoopState_InCampaign))
	{
		return;
	}
	StopMirroring();
	bHostInMission = false;
	ExpectedFingerprint = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	Say("Session: the host is sending the campaign: " $ ExpectedFingerprint);
	SetState(eCoopState_LoadingCampaign);
}

/// Client: the campaign arrived. The network manager has already put it in XCOMHISTORY.
function HandleReceiveHistory(XComGameStateHistory InHistory, X2EventManager EventManager)
{
	local array<byte> Params;

	if (bIsHost || (SessionState != eCoopState_LoadingCampaign && SessionState != eCoopState_Ready && SessionState != eCoopState_InCampaign))
	{
		Say("Session: ignored a history in state " $ StateName());
		return;
	}
	StopMirroring();
	if (InHistory != none && InHistory != `XCOMHISTORY)
	{
		Say("Session: WARNING the received history is not XCOMHISTORY");
	}

	ReceivedFingerprint = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	ReceivedHistoryIndex = `XCOMHISTORY.GetCurrentHistoryIndex();
	Say("Session: campaign received, index " $ ReceivedHistoryIndex $ ", fingerprint " $ ReceivedFingerprint);
	if (ExpectedFingerprint != "" && ExpectedFingerprint != ReceivedFingerprint)
	{
		Say("Session: fingerprints DIFFER " $ class'XComCoop_Util'.static.DescribeDifference(ExpectedFingerprint, ReceivedFingerprint));
	}

	class'XComGameStateNetworkManager'.static.AddCommandParam_String(ReceivedFingerprint, Params);
	`XCOMNETMANAGER.SendRemoteCommand(CMD_CAMPAIGN_ACK, Params);

	if (SessionState != eCoopState_LoadingCampaign)
	{
		SetState(eCoopState_LoadingCampaign);
	}
	else
	{
		NotifyChanged();
	}

	// Give the confirmation a moment to go out before the map load.
	class'Engine'.static.GetCurrentWorldInfo().SetTimer(class'XComCoop_Config'.default.CampaignLoadDelaySeconds, false, nameof(EnterCampaign), self);
}

/// Client: loads the Avenger from the received campaign, as if loading a save.
function EnterCampaign()
{
	local PlayerController PC;

	if (bIsHost || SessionState != eCoopState_LoadingCampaign)
	{
		return;
	}
	if (`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom', true) == none)
	{
		Problems.AddItem(strCampaignInvalid);
		Leave(true);
		return;
	}
	PC = class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController();
	if (PC == none)
	{
		Say("Session: no player controller, cannot load the campaign");
		return;
	}
	Say("Session: loading the host's campaign: " $ STRATEGY_LOAD_COMMAND);
	`ONLINEEVENTMGR.bPerformingStandardLoad = true;
	PC.ConsoleCommand(STRATEGY_LOAD_COMMAND);
}

/// Called from X2DownloadableContentInfo_XComCoop.OnLoadedSavedGameToStrategy.
function OnLoadedToStrategy()
{
	if (bIsHost)
	{
		if (SessionState == eCoopState_InCampaign || SessionState == eCoopState_SendingCampaign)
		{
			// The host loaded another save: the client needs this campaign instead.
			Say("Session: the host loaded a save, the whole campaign goes to " $ OtherName() $ " again");
			ResendWhenStrategyRuns();
		}
		return;
	}
	if (SessionState != eCoopState_LoadingCampaign)
	{
		return;
	}
	Notices.AddItem(Repl(strArrivedClient, "%PLAYER", OtherName()));
	SyncedIndex = ReceivedHistoryIndex;
	bMirrorReady = false;
	SetState(eCoopState_InCampaign);
	if (!class'XComCoop_Util'.static.IsConnected())
	{
		Notices.AddItem(strConnectionLostLoading);
		Say("Session: on the Avenger, but the connection to the host is closed");
		return;
	}
	// The load itself adds a few game states. The guard drops them once the Avenger is up
	// and then tells the host, which starts sending changes.
	class'WorldInfo'.static.GetWorldInfo().SetTimer(class'XComCoop_Config'.default.MirrorGuardSeconds, true, nameof(MirrorGuard), self);
	// Only the host runs time; keep the client's Geoscape stopped.
	class'WorldInfo'.static.GetWorldInfo().SetTimer(class'XComCoop_Config'.default.ClientTimeFreezeSeconds, true, nameof(FreezeClientTime), self);
}

/// Host: the client confirms what arrived.
function HandleCampaignAck(array<byte> RawParams)
{
	local string Fp, Seconds;

	if (!bIsHost || SessionState != eCoopState_SendingCampaign)
	{
		return;
	}
	Fp = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	Seconds = class'XComCoop_Util'.static.FormatSeconds(class'XComCoop_Util'.static.Now() - CampaignSendTime);
	Say("Session: " $ OtherName() $ " confirmed the campaign after " $ Seconds $ " s (round trip)");
	if (Fp == SentFingerprint)
	{
		Say("Session: fingerprints MATCH");
		Notices.AddItem(Repl(Repl(strCampaignReceived, "%PLAYER", OtherName()), "%SECONDS", Seconds));
	}
	else
	{
		Say("Session: fingerprints DIFFER " $ class'XComCoop_Util'.static.DescribeDifference(SentFingerprint, Fp));
		Warnings.AddItem(Repl(strCampaignMismatch, "%PLAYER", OtherName()));
	}
	SetState(eCoopState_InCampaign);
}

/// Host: the client is on the Avenger, in sync, and the connection survived its map load.
/// Start sending changes.
function HandleArrived(array<byte> RawParams)
{
	local string Fp;

	if (!bIsHost)
	{
		return;
	}
	Fp = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	Say("Session: " $ OtherName() $ " is on the Avenger, the connection survived the map load. fingerprint " $ Fp);
	if (Fp != SentFingerprint)
	{
		Say("Session: " $ OtherName() $ " arrived with another campaign: " $ class'XComCoop_Util'.static.DescribeDifference(SentFingerprint, Fp));
		Resync();
		return;
	}
	Notices.AddItem(Repl(strClientArrived, "%PLAYER", OtherName()));
	bClientLoading = false;
	StartMirroring();
	if (`XCOMHISTORY.GetCurrentHistoryIndex() > CampaignSentIndex)
	{
		// Changes made while the client was loading.
		bMirrorDirty = true;
		ScheduleMirrorSend();
	}
	NotifyChanged();
}

// --- Phase 2: mirroring ------------------------------------------------------------------------

/// Host: listen for new game states. The history drops its delegates on map changes, so
/// this registers again every time.
function StartMirroring()
{
	`XCOMHISTORY.UnRegisterOnNewGameStateDelegate(HandleNewGameState);
	`XCOMHISTORY.RegisterOnNewGameStateDelegate(HandleNewGameState);
	bAwaitingMirrorAck = false;
	ClockYear = 0;
	MoversInFlight.Length = 0;
	class'WorldInfo'.static.GetWorldInfo().SetTimer(class'XComCoop_Config'.default.MirrorClockSeconds, true, nameof(MirrorClock), self);
	class'WorldInfo'.static.GetWorldInfo().SetTimer(class'XComCoop_Config'.default.MirrorMoverSeconds, true, nameof(MirrorMovers), self);
	Say("Session: mirroring started");
}

/// Both: stop sending (host) or throwing away own game states (client).
function StopMirroring()
{
	local WorldInfo WI;

	`XCOMHISTORY.UnRegisterOnNewGameStateDelegate(HandleNewGameState);
	WI = class'WorldInfo'.static.GetWorldInfo();
	if (WI != none)
	{
		WI.ClearTimer(nameof(MirrorSend), self);
		WI.ClearTimer(nameof(MirrorGuard), self);
		WI.ClearTimer(nameof(MirrorClock), self);
		WI.ClearTimer(nameof(MirrorMovers), self);
		WI.ClearTimer(nameof(FreezeClientTime), self);
		WI.ClearTimer(nameof(ResendWhenReady), self);
	}
	MoversInFlight.Length = 0;
	MoverLerps.Length = 0;
	PopupsToSend.Length = 0;
	PopupsToShow.Length = 0;
	bResendWhenReady = false;
	RemoveWatchBanner();
	bMirrorDirty = false;
	bAwaitingMirrorAck = false;
	bMirrorReady = false;
}

/// Host: a new game state was added to the history.
function HandleNewGameState(XComGameState NewGameState)
{
	if (!bIsHost || SessionState != eCoopState_InCampaign || bClientLoading)
	{
		return;
	}
	bMirrorDirty = true;
	ScheduleMirrorSend();
}

/// Host: send after a short delay, so a burst of game states goes out as one update.
function ScheduleMirrorSend()
{
	local WorldInfo WI;

	WI = class'WorldInfo'.static.GetWorldInfo();
	if (!WI.IsTimerActive(nameof(MirrorSend), self))
	{
		WI.SetTimer(class'XComCoop_Config'.default.MirrorSendDelaySeconds, false, nameof(MirrorSend), self);
	}
}

/// Host: tells the client to drop its own game states, then sends the frames it lacks.
function MirrorSend()
{
	local XComGameStateNetworkManager NetMgr;
	local array<byte> Params;

	if (!bIsHost || SessionState != eCoopState_InCampaign || bClientLoading || !bMirrorDirty || !class'XComCoop_Util'.static.IsConnected())
	{
		return;
	}
	if (bAwaitingMirrorAck)
	{
		if (class'XComCoop_Util'.static.Now() - MirrorSendTime < class'XComCoop_Config'.default.MirrorAckTimeoutSeconds)
		{
			// HandleMirrorAck sends again when the answer comes.
			return;
		}
		Say("Session: no answer to update " $ MirrorSent $ ", sending the next one anyway");
	}

	NetMgr = `XCOMNETMANAGER;
	bMirrorDirty = false;
	bAwaitingMirrorAck = true;
	MirrorSendTime = class'XComCoop_Util'.static.Now();
	MirrorSentFingerprint = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	MirrorSent++;
	Params.Length = 0;
	NetMgr.SendRemoteCommand(CMD_MIRROR, Params);
	NetMgr.SendPartialHistory(`XCOMHISTORY, `XEVENTMGR);
	// Popups shown since the last update go after the changes they belong to.
	SendPopups();
	`log("Session: update " $ MirrorSent $ " sent, index " $ `XCOMHISTORY.GetCurrentHistoryIndex() $ ", fingerprint " $ MirrorSentFingerprint,, 'XComCoop');
	NotifyChanged();
}

/// Host: the client applied an update. A different fingerprint means the campaigns drifted
/// apart, so the whole campaign goes out again.
function HandleMirrorAck(array<byte> RawParams)
{
	local int ClientIndex;
	local string Fp;

	if (!bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	ClientIndex = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Fp = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	bAwaitingMirrorAck = false;
	if (Fp != MirrorSentFingerprint)
	{
		Say("Session: update " $ MirrorSent $ " DIFFERS on " $ OtherName() $ " (index " $ ClientIndex $ "): "
			$ class'XComCoop_Util'.static.DescribeDifference(MirrorSentFingerprint, Fp));
		Resync();
		return;
	}
	`log("Session: update " $ MirrorSent $ " confirmed after "
		$ class'XComCoop_Util'.static.FormatSeconds(class'XComCoop_Util'.static.Now() - MirrorSendTime) $ " s, client index " $ ClientIndex,, 'XComCoop');
	if (bMirrorDirty)
	{
		ScheduleMirrorSend();
	}
	else
	{
		// Popups shown while this update was on its way, with no new changes to wait for.
		SendPopups();
	}
	NotifyChanged();
}

/// Host: sends the whole campaign again, a limited number of times.
function Resync()
{
	StopMirroring();
	if (MirrorResyncs >= class'XComCoop_Config'.default.MirrorMaxResyncs)
	{
		Say("Session: giving up on mirroring after " $ MirrorResyncs $ " resends");
		Warnings.AddItem(Repl(strMirrorGaveUp, "%PLAYER", OtherName()));
		bClientLoading = true;
		NotifyChanged();
		return;
	}
	MirrorResyncs++;
	Notices.AddItem(Repl(strMirrorResync, "%PLAYER", OtherName()));
	SendCampaign();
}

/// Client: changes from the host follow; make sure they land on a clean history.
function HandleMirrorCommand()
{
	if (bIsHost || SessionState != eCoopState_InCampaign || !bMirrorReady)
	{
		return;
	}
	RollbackLocalChanges();
}

/// Client: the host's changes are in XCOMHISTORY now. Show them and confirm.
function HandleReceivePartialHistory(XComGameStateHistory InHistory, X2EventManager EventManager)
{
	local array<byte> Params;
	local string Fp;
	local int Index;

	if (bIsHost || SessionState != eCoopState_InCampaign)
	{
		Say("Session: ignored changes in state " $ StateName());
		return;
	}
	Index = `XCOMHISTORY.GetCurrentHistoryIndex();
	`log("Session: update " $ (MirrorReceived + 1) $ " applied, index " $ SyncedIndex $ " -> " $ Index,, 'XComCoop');
	SyncedIndex = Index;
	MirrorReceived++;
	RefreshStrategyView(true);

	Fp = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Index, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(Fp, Params);
	`XCOMNETMANAGER.SendRemoteCommand(CMD_MIRROR_ACK, Params);
	NotifyChanged();
}

/// Client timer: throws away own game states. The first time, once the Avenger is up, it
/// also tells the host that mirroring can start.
function MirrorGuard()
{
	local array<byte> Params;
	local string Fp;

	if (bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	UpdateWatchBanner();
	RefreshOpenScreen();
	if (!bMirrorReady)
	{
		if (!IsStrategyRunning())
		{
			return;
		}
		RollbackLocalChanges();
		bMirrorReady = true;
		Fp = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(Fp, Params);
		`XCOMNETMANAGER.SendRemoteCommand(CMD_ARRIVED, Params);
		Say("Session: on the Avenger and in sync with the host, index " $ SyncedIndex $ ". fingerprint " $ Fp);
		NotifyChanged();
		return;
	}
	RollbackLocalChanges();
}

/// Client: removes every game state after the last one that came from the host.
function int RollbackLocalChanges()
{
	local XComGameStateHistory History;
	local int Count;

	History = `XCOMHISTORY;
	Count = History.GetCurrentHistoryIndex() - SyncedIndex;
	if (Count <= 0)
	{
		return 0;
	}
	History.ObliterateGameStatesFromHistory(Count);
	MirrorRolledBack += Count;
	`log("Session: dropped " $ Count $ " own game states, back at index " $ SyncedIndex,, 'XComCoop');
	RefreshStrategyView();
	return Count;
}

/// Client: the strategy ruleset keeps its own copy of the clock, and the resource bar only
/// redraws when asked. After an update from the host (bAfterUpdate) the Avenger overview
/// and the room props are redrawn too. Other screens read the history when they open.
function RefreshStrategyView(optional bool bAfterUpdate)
{
	local XComGameState_GameTime TimeState;
	local XComHQPresentationLayer HQPres;
	local XGGeoscape Geoscape;

	if (!class'XComCoop_Util'.static.IsInStrategy())
	{
		return;
	}
	if (bHaveHostClock)
	{
		// The host's running clock is never behind the one in the history.
		ApplyHostClock();
	}
	else
	{
		foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_GameTime', TimeState)
		{
			`STRATEGYRULES.GameTime = TimeState.CurrentTime;
			break;
		}
	}
	HQPres = XComHQPresentationLayer(class'XComCoop_Util'.static.GetPres());
	if (HQPres != none && HQPres.m_kAvengerHUD != none)
	{
		HQPres.m_kAvengerHUD.UpdateResources();
	}
	// The screen the player is looking at; also after his own changes were undone.
	bScreenRefreshPending = true;
	RefreshOpenScreen();
	if (!bAfterUpdate)
	{
		return;
	}
	if (HQPres != none && HQPres.m_kFacilityGrid != none)
	{
		HQPres.m_kFacilityGrid.UpdateData();
	}
	Geoscape = GetGeoscape();
	if (Geoscape != none && Geoscape.m_kBase != none)
	{
		Geoscape.m_kBase.UpdateFacilityProps();
	}
}

/// Host timer: sends the Geoscape clock when it has moved.
function MirrorClock()
{
	local XGGeoscape Geoscape;
	local array<byte> Params;
	local int Second;

	if (!bIsHost || SessionState != eCoopState_InCampaign || bClientLoading || !class'XComCoop_Util'.static.IsConnected())
	{
		return;
	}
	Geoscape = GetGeoscape();
	if (Geoscape == none)
	{
		return;
	}
	Second = int(Geoscape.m_kDateTime.m_fTime);
	if (Geoscape.m_kDateTime.m_iYear == ClockYear && Geoscape.m_kDateTime.m_iMonth == ClockMonth
		&& Geoscape.m_kDateTime.m_iDay == ClockDay && Second == ClockSecond)
	{
		return;
	}
	ClockYear = Geoscape.m_kDateTime.m_iYear;
	ClockMonth = Geoscape.m_kDateTime.m_iMonth;
	ClockDay = Geoscape.m_kDateTime.m_iDay;
	ClockSecond = Second;
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(ClockYear, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(ClockMonth, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(ClockDay, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(ClockSecond, Params);
	`XCOMNETMANAGER.SendRemoteCommand(CMD_CLOCK, Params);
}

/// Client: the host's clock moved.
function HandleClock(array<byte> RawParams)
{
	if (bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	ClockYear = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	ClockMonth = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	ClockDay = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	ClockSecond = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	bHaveHostClock = true;
	ApplyHostClock();
}

/// Client: shows the host's clock (Geoscape, strategy rules, day and night on the globe).
/// Only what is on screen changes; the history is left alone.
function ApplyHostClock()
{
	local XComHeadquartersGame HQGame;
	local XGGeoscape Geoscape;

	HQGame = XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game);
	Geoscape = GetGeoscape();
	if (Geoscape == none)
	{
		return;
	}
	Geoscape.m_kDateTime.m_iYear = ClockYear;
	Geoscape.m_kDateTime.m_iMonth = ClockMonth;
	Geoscape.m_kDateTime.m_iDay = ClockDay;
	Geoscape.m_kDateTime.m_fTime = ClockSecond;
	`STRATEGYRULES.GameTime = Geoscape.m_kDateTime;
	if (HQGame.GetEarth() != none)
	{
		HQGame.GetEarth().SetTime(Geoscape.m_kDateTime);
	}
}

/// Client timer: time only runs on the host. A stopped Geoscape advances nothing and
/// creates no game states (XGGeoscape.Tick returns early).
function FreezeClientTime()
{
	local XGGeoscape Geoscape;

	if (bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	Geoscape = GetGeoscape();
	if (Geoscape != none && Geoscape.m_fTimeScale != class'XGGeoscape'.const.PAUSED)
	{
		Geoscape.m_fTimeScale = class'XGGeoscape'.const.PAUSED;
	}
	// The same fast timer moves the airships smoothly between the host's positions and
	// shows the host's popups as soon as the game allows.
	UpdateMoverLerps();
	ShowPendingPopups();
}

/// Host timer: sends the position of everything that flies, and one last position for
/// whatever stopped flying since the last send.
function MirrorMovers()
{
	local XComGameState_Airship Ship;
	local array<int> NowInFlight;
	local int i;

	if (!bIsHost || SessionState != eCoopState_InCampaign || bClientLoading || !class'XComCoop_Util'.static.IsConnected())
	{
		return;
	}
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Airship', Ship)
	{
		if (Ship.IsCurrentlyInFlight())
		{
			NowInFlight.AddItem(Ship.ObjectID);
			SendMove(Ship);
		}
	}
	for (i = 0; i < MoversInFlight.Length; i++)
	{
		if (NowInFlight.Find(MoversInFlight[i]) == INDEX_NONE)
		{
			Ship = XComGameState_Airship(`XCOMHISTORY.GetGameStateForObjectID(MoversInFlight[i]));
			if (Ship != none)
			{
				SendMove(Ship);
			}
		}
	}
	MoversInFlight = NowInFlight;
}

function SendMove(XComGameState_Airship Ship)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Ship.ObjectID, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(int(Ship.Location.X * MOVE_SCALE), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(int(Ship.Location.Y * MOVE_SCALE), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(int(Ship.Location.Z * MOVE_SCALE), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Ship.Rotation.Pitch, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Ship.Rotation.Yaw, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Ship.Rotation.Roll, Params);
	`XCOMNETMANAGER.SendRemoteCommand(CMD_MOVE, Params);
}

/// Client: a new position for an airship. Rotation is set at once; the position glides
/// there over one send interval.
function HandleMove(array<byte> RawParams)
{
	local XComGameState_Airship Ship;
	local CoopMoverLerp Lerp;
	local int ObjectID, i;

	if (bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	ObjectID = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Ship = XComGameState_Airship(`XCOMHISTORY.GetGameStateForObjectID(ObjectID));
	if (Ship == none)
	{
		return;
	}
	Lerp.ObjectID = ObjectID;
	Lerp.From = Ship.Location;
	Lerp.To.X = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams) / MOVE_SCALE;
	Lerp.To.Y = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams) / MOVE_SCALE;
	Lerp.To.Z = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams) / MOVE_SCALE;
	Ship.Rotation.Pitch = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Ship.Rotation.Yaw = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Ship.Rotation.Roll = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Lerp.StartTime = class'XComCoop_Util'.static.Now();

	for (i = 0; i < MoverLerps.Length; i++)
	{
		if (MoverLerps[i].ObjectID == ObjectID)
		{
			MoverLerps[i] = Lerp;
			return;
		}
	}
	MoverLerps.AddItem(Lerp);
}

/// Client: moves each airship along its glide and lets the camera follow a flying Avenger
/// or Skyranger, as XGGeoscape.UpdateUI does on the host.
function UpdateMoverLerps()
{
	local XComGameState_Airship Ship;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_Skyranger Skyranger;
	local XComHeadquartersGame HQGame;
	local Vector2D Delta, View;
	local float Alpha;
	local int i;

	if (MoverLerps.Length == 0)
	{
		return;
	}
	for (i = MoverLerps.Length - 1; i >= 0; i--)
	{
		Ship = XComGameState_Airship(`XCOMHISTORY.GetGameStateForObjectID(MoverLerps[i].ObjectID));
		Alpha = FClamp((class'XComCoop_Util'.static.Now() - MoverLerps[i].StartTime) / class'XComCoop_Config'.default.MirrorMoverSeconds, 0.0, 1.0);
		if (Ship != none)
		{
			Ship.Location = VLerp(MoverLerps[i].From, MoverLerps[i].To, Alpha);
		}
		if (Ship == none || Alpha >= 1.0)
		{
			MoverLerps.Remove(i, 1);
		}
	}

	HQGame = XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game);
	if (HQGame == none || HQGame.GetEarth() == none)
	{
		return;
	}
	XComHQ = XComGameState_HeadquartersXCom(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom'));
	Skyranger = XComGameState_Skyranger(`XCOMHISTORY.GetGameStateForObjectID(XComHQ.SkyrangerRef.ObjectID));
	if (XComHQ.IsCurrentlyInFlight())
	{
		Delta = XComHQ.Get2DLocation();
	}
	else if (Skyranger != none && Skyranger.IsCurrentlyInFlight())
	{
		Delta = Skyranger.Get2DLocation();
	}
	else
	{
		return;
	}
	View = HQGame.GetEarth().GetViewLocation();
	Delta.X -= View.X;
	Delta.Y -= View.Y;
	HQGame.GetEarth().MoveViewLocation(Delta);
}

static function XGGeoscape GetGeoscape()
{
	local XComHeadquartersGame HQGame;

	HQGame = XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game);
	if (HQGame == none || HQGame.GetGameCore() == none)
	{
		return none;
	}
	return HQGame.GetGameCore().GetGeoscape();
}

// --- Phase 2: missions and loads on the host ---------------------------------------------------

/// Host (DLC hook OnPreMission): mirroring is strategy only. Tell the client and pause.
function OnMissionStart()
{
	local array<byte> Params;

	if (!bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	StopMirroring();
	bClientLoading = true;
	bHostInMission = true;
	if (class'XComCoop_Util'.static.IsConnected())
	{
		Params.Length = 0;
		`XCOMNETMANAGER.SendRemoteCommand(CMD_HOST_MISSION, Params);
	}
	Say("Session: the host went on a mission; mirroring paused");
}

/// Host (DLC hook OnExitPostMissionSequence): back on the Avenger. The client gets the whole
/// campaign with the mission's results.
function OnBackFromMission()
{
	if (!bIsHost || !bHostInMission)
	{
		return;
	}
	bHostInMission = false;
	if (SessionState == eCoopState_InCampaign && class'XComCoop_Util'.static.IsConnected())
	{
		Say("Session: back from the mission, the whole campaign goes to " $ OtherName() $ " again");
		SendCampaign();
	}
}

/// Host: send the whole campaign once the strategy game has finished loading.
function ResendWhenStrategyRuns()
{
	StopMirroring();
	bClientLoading = true;
	bResendWhenReady = true;
	class'WorldInfo'.static.GetWorldInfo().SetTimer(class'XComCoop_Config'.default.MirrorGuardSeconds, true, nameof(ResendWhenReady), self);
}

function ResendWhenReady()
{
	if (!bResendWhenReady || !IsStrategyRunning())
	{
		return;
	}
	class'WorldInfo'.static.GetWorldInfo().ClearTimer(nameof(ResendWhenReady), self);
	bResendWhenReady = false;
	if ((SessionState == eCoopState_InCampaign || SessionState == eCoopState_SendingCampaign) && class'XComCoop_Util'.static.IsConnected())
	{
		SendCampaign();
	}
}

/// Client: the host went on a mission.
function HandleHostMission()
{
	if (bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	bHostInMission = true;
	Notices.AddItem(Repl(strHostOnMission, "%PLAYER", OtherName()));
	Say("Session: " $ OtherName() $ " is on a mission");
	NotifyChanged();
}

// --- Phase 2: popups ---------------------------------------------------------------------------

/// Both (DLC hook DisplayQueuedDynamicPopup): a popup is being shown. The host passes it on.
function OnPopupShown(X2StrategyGameRulesetDataStructures.DynamicPropertySet PropertySet)
{
	local CoopPopupData Popup;

	if (!bIsHost || SessionState != eCoopState_InCampaign || bClientLoading)
	{
		return;
	}
	WritePopup(PropertySet, Popup.Data);
	if (PopupsToSend.Length >= MAX_POPUPS)
	{
		PopupsToSend.Remove(0, 1);
	}
	PopupsToSend.AddItem(Popup);
	`log("Session: popup " $ PropertySet.PrimaryRoutingKey $ "/" $ PropertySet.SecondaryRoutingKey $ " queued for " $ OtherName(),, 'XComCoop');

	// The changes that led to the popup go first; MirrorSend or HandleMirrorAck sends it then.
	if (bMirrorDirty || bAwaitingMirrorAck || class'WorldInfo'.static.GetWorldInfo().IsTimerActive(nameof(MirrorSend), self))
	{
		return;
	}
	SendPopups();
}

function SendPopups()
{
	local int i;

	if (!class'XComCoop_Util'.static.IsConnected())
	{
		return;
	}
	for (i = 0; i < PopupsToSend.Length; i++)
	{
		`XCOMNETMANAGER.SendRemoteCommand(CMD_POPUP, PopupsToSend[i].Data);
	}
	PopupsToSend.Length = 0;
}

/// Client: a popup from the host; shown by ShowPendingPopups.
function HandlePopup(array<byte> RawParams)
{
	local CoopPopupData Popup;

	if (bIsHost || SessionState != eCoopState_InCampaign)
	{
		return;
	}
	Popup.Data = RawParams;
	if (PopupsToShow.Length >= MAX_POPUPS)
	{
		PopupsToShow.Remove(0, 1);
	}
	PopupsToShow.AddItem(Popup);
}

/// Client: shows waiting popups the way the game shows its queued ones: only when the
/// game says it fits (XComPresentationLayerBase.IsPropertySetApplicableForDisplay).
/// Buttons only close the popup here; the host's game handles what they do.
function ShowPendingPopups()
{
	local X2StrategyGameRulesetDataStructures.DynamicPropertySet PropertySet;
	local XComPresentationLayerBase Pres;
	local array<byte> Data;
	local int i;

	if (PopupsToShow.Length == 0 || !bMirrorReady)
	{
		return;
	}
	Pres = class'XComCoop_Util'.static.GetPres();
	if (Pres == none)
	{
		return;
	}
	for (i = 0; i < PopupsToShow.Length; i++)
	{
		Data = PopupsToShow[i].Data;
		if (!ReadPopup(Data, PropertySet))
		{
			PopupsToShow.Remove(i, 1);
			i--;
			continue;
		}
		// The same button handler as on the host (a delegate cannot be sent).
		class'XComCoop_PopupCallbacks'.static.SetCallback(XComHQPresentationLayer(Pres), PropertySet);
		if (Pres.DisplayDynamicPopupImmediate(PropertySet))
		{
			`log("Session: showed the host's popup " $ PropertySet.PrimaryRoutingKey $ "/" $ PropertySet.SecondaryRoutingKey,, 'XComCoop');
			PopupsToShow.Remove(i, 1);
			i--;
		}
	}
}

/// CMD_POPUP wire format: routing keys, display flags, then the properties (recursive).
/// The callback cannot be sent; the client's popup just closes.
static function WritePopup(const out X2StrategyGameRulesetDataStructures.DynamicPropertySet PropertySet, out array<byte> Data)
{
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(PropertySet.PrimaryRoutingKey), Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(PropertySet.SecondaryRoutingKey), Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Bool(PropertySet.bDisplayImmediate, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Bool(PropertySet.bDisplayOnAvengerSideViewIdle, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Bool(PropertySet.bDisplayOnGeoscapeIdle, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Bool(PropertySet.bDisplayInTacticalIdle, Data);
	WriteProperties(PropertySet.DynamicProperties, Data);
}

static function WriteProperties(const out array<X2StrategyGameRulesetDataStructures.DynamicProperty> Properties, out array<byte> Data)
{
	local array<X2StrategyGameRulesetDataStructures.DynamicProperty> Nested;
	local int i;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Properties.Length, Data);
	for (i = 0; i < Properties.Length; i++)
	{
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Properties[i].Key), Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Properties[i].ValueName), Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Properties[i].ValueInt, Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Properties[i].ValueFloat), Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(Properties[i].ValueString, Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Properties[i].ValueVector.X), Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Properties[i].ValueVector.Y), Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Properties[i].ValueVector.Z), Data);
		// An array element cannot be passed as an out parameter; copy it first.
		Nested = Properties[i].ValueArray;
		WriteProperties(Nested, Data);
	}
}

/// Reads what WritePopup wrote. Data is consumed. False if the data is cut short.
static function bool ReadPopup(out array<byte> Data, out X2StrategyGameRulesetDataStructures.DynamicPropertySet PropertySet)
{
	local X2StrategyGameRulesetDataStructures.DynamicPropertySet Empty;

	PropertySet = Empty;
	if (Data.Length == 0) return false;
	PropertySet.PrimaryRoutingKey = name(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
	if (Data.Length == 0) return false;
	PropertySet.SecondaryRoutingKey = name(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
	if (Data.Length == 0) return false;
	PropertySet.bDisplayImmediate = class'XComGameStateNetworkManager'.static.GetCommandParam_Bool(Data);
	if (Data.Length == 0) return false;
	PropertySet.bDisplayOnAvengerSideViewIdle = class'XComGameStateNetworkManager'.static.GetCommandParam_Bool(Data);
	if (Data.Length == 0) return false;
	PropertySet.bDisplayOnGeoscapeIdle = class'XComGameStateNetworkManager'.static.GetCommandParam_Bool(Data);
	if (Data.Length == 0) return false;
	PropertySet.bDisplayInTacticalIdle = class'XComGameStateNetworkManager'.static.GetCommandParam_Bool(Data);
	return ReadProperties(Data, PropertySet.DynamicProperties);
}

static function bool ReadProperties(out array<byte> Data, out array<X2StrategyGameRulesetDataStructures.DynamicProperty> Properties)
{
	local X2StrategyGameRulesetDataStructures.DynamicProperty Property;
	local array<X2StrategyGameRulesetDataStructures.DynamicProperty> Nested;
	local int Count, i;

	Properties.Length = 0;
	if (Data.Length == 0) return false;
	Count = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(Data);
	for (i = 0; i < Count; i++)
	{
		if (Data.Length == 0) return false;
		Property.Key = name(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
		Property.ValueName = name(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
		Property.ValueInt = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(Data);
		Property.ValueFloat = float(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
		Property.ValueString = class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data);
		Property.ValueVector.X = float(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
		Property.ValueVector.Y = float(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
		Property.ValueVector.Z = float(class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data));
		if (!ReadProperties(Data, Nested))
		{
			return false;
		}
		Property.ValueArray = Nested;
		Properties.AddItem(Property);
	}
	return true;
}

// --- Phase 2: "watching" banner on the client --------------------------------------------------

/// Client: a line at the top of the Avenger HUD so it is clear this is the host's campaign.
/// The banner belongs to the HUD screen and is looked up by name; the session keeps no
/// reference to it.
function UpdateWatchBanner()
{
	local XComHQPresentationLayer HQPres;
	local UIText Banner;
	local string Text;

	HQPres = XComHQPresentationLayer(class'XComCoop_Util'.static.GetPres());
	if (HQPres == none || HQPres.m_kAvengerHUD == none)
	{
		return;
	}
	Text = Repl(bHostInMission ? strWatchBannerMission : strWatchBanner, "%PLAYER", OtherName());
	Text = class'UIUtilities_Text'.static.AlignCenter(class'UIUtilities_Text'.static.GetColoredText(Text, eUIState_Warning));
	Banner = UIText(HQPres.m_kAvengerHUD.GetChildByName(WATCH_BANNER_NAME, false));
	if (Banner == none)
	{
		Banner = HQPres.m_kAvengerHUD.Spawn(class'UIText', HQPres.m_kAvengerHUD);
		Banner.InitText(WATCH_BANNER_NAME);
		Banner.AnchorTopCenter();
		Banner.SetWidth(WATCH_BANNER_WIDTH);
		Banner.SetPosition(-WATCH_BANNER_WIDTH / 2, WATCH_BANNER_Y);
		Banner.SetHtmlText(Text);
	}
	else if (Banner.HtmlText != Text)
	{
		Banner.SetHtmlText(Text);
	}
}

function RemoveWatchBanner()
{
	local XComHQPresentationLayer HQPres;
	local UIPanel Banner;

	HQPres = XComHQPresentationLayer(class'XComCoop_Util'.static.GetPres());
	if (HQPres == none || HQPres.m_kAvengerHUD == none)
	{
		return;
	}
	Banner = HQPres.m_kAvengerHUD.GetChildByName(WATCH_BANNER_NAME, false);
	if (Banner != none)
	{
		Banner.Remove();
	}
}

/// Client: redraws the screen on top of the stack, at most once every
/// OpenScreenRefreshSeconds (the guard timer catches up on a skipped one). Each screen
/// type has its own redraw function; the ones listed cover the main strategy screens
/// through inheritance. Other screens show changes when they are opened again.
function RefreshOpenScreen()
{
	local XComPresentationLayerBase Pres;
	local UIScreen Screen;

	if (!bScreenRefreshPending
		|| class'XComCoop_Util'.static.Now() - LastScreenRefresh < class'XComCoop_Config'.default.OpenScreenRefreshSeconds)
	{
		return;
	}
	Pres = class'XComCoop_Util'.static.GetPres();
	if (Pres == none || Pres.ScreenStack == none)
	{
		return;
	}
	bScreenRefreshPending = false;
	LastScreenRefresh = class'XComCoop_Util'.static.Now();
	Screen = Pres.ScreenStack.GetCurrentScreen();

	// Research, Proving Ground, Black Market, class choice, Engineering builds, storage
	if (UIInventory(Screen) != none)
	{
		UIInventory(Screen).PopulateData();
	}
	else if (UIArmory(Screen) != none)
	{
		UIArmory(Screen).PopulateData();
	}
	else if (UIPersonnel(Screen) != none)
	{
		UIPersonnel(Screen).RefreshData();
	}
	// Labs, Power Core, Infirmary and the other rooms
	else if (UIFacility(Screen) != none)
	{
		UIFacility(Screen).RealizeFacility();
	}
	else if (UIResistance(Screen) != none)
	{
		UIResistance(Screen).UpdateData();
	}
}

/// True when the strategy game has finished loading and runs normally.
static function bool IsStrategyRunning()
{
	local XComHeadquartersGame HQGame;

	HQGame = XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game);
	return HQGame != none && HQGame.GetGameCore() != none && HQGame.GetGameCore().IsInState('Headquarters');
}

// --- SessionState ----------------------------------------------------------------------------

function SetState(ECoopSessionState NewState)
{
	SessionState = NewState;
	Say("Session: state " $ StateName());
	NotifyChanged();
}

function string StateName()
{
	return string(GetEnum(Enum'ECoopSessionState', SessionState));
}

function string OtherName()
{
	return OtherPlayerName != "" ? OtherPlayerName : strSomeone;
}

function Fail(string Reason)
{
	Problems.AddItem(Reason);
	SetState(eCoopState_Failed);
}

function Reset()
{
	local UniqueNetId EmptyId;

	SessionState = eCoopState_Idle;
	bIsHost = false;
	bInLobby = false;
	bCompatSent = false;
	LobbyId = EmptyId;
	HostId = EmptyId;
	OtherPlayerName = "";
	Problems.Length = 0;
	Warnings.Length = 0;
	Notices.Length = 0;
	ConnectAttemptsLeft = 0;
	SentFingerprint = "";
	CampaignSendTime = 0;
	ExpectedFingerprint = "";
	ReceivedFingerprint = "";
	ReceivedHistoryIndex = 0;
	CampaignSentIndex = 0;
	bClientLoading = false;
	bMirrorDirty = false;
	bAwaitingMirrorAck = false;
	MirrorSendTime = 0;
	MirrorSentFingerprint = "";
	MirrorSent = 0;
	MirrorResyncs = 0;
	SyncedIndex = 0;
	bMirrorReady = false;
	MirrorReceived = 0;
	MirrorRolledBack = 0;
	ClockYear = 0;
	ClockMonth = 0;
	ClockDay = 0;
	ClockSecond = 0;
	bHaveHostClock = false;
	MoversInFlight.Length = 0;
	MoverLerps.Length = 0;
	PopupsToSend.Length = 0;
	PopupsToShow.Length = 0;
	bHostInMission = false;
	bResendWhenReady = false;
	bScreenRefreshPending = false;
	LastScreenRefresh = 0;
}

function NotifyChanged()
{
	ChangeCount++;
}

static function Say(string Msg)
{
	class'XComCoop_Util'.static.Say(Msg);
}
