//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_Session.uc
//  PURPOSE: The co-op session. Owns the Steam lobby, the network connection, the
//           compatibility check (phase 1) and handing the host's campaign to the client
//           (phase 2), and tells the UI when anything changes.
//
//  Host:   Host() -> CreateLobby -> start the game server (Steam sockets) -> Invite(friend)
//  Client: invite received -> popup -> Join() -> JoinLobby -> connect to the lobby owner
//  Both:   connected -> exchange XComCoop_CompatInfo -> Ready, or Failed with clear reasons
//
//  Phase 2, first step (the client gets a copy of the host's campaign):
//  Host on the Avenger, Ready: StartCampaign() -> announce fingerprint -> SendHistory
//  Client: history arrives (it replaces XCOMHISTORY) -> confirm with its fingerprint ->
//          load the Avenger as if loading a save (phase 0 test 4) -> tell the host it arrived
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
	eCoopState_InCampaign,          // both: the client has a copy of the host's campaign
	eCoopState_Failed,              // see Problems
};

// Remote commands. Not the same names as the phase 0 tests.
const CMD_COMPAT = "XComCoopLobbyCompat";
const CMD_CAMPAIGN = "XComCoopCampaign";            // host -> client: fingerprint of what follows
const CMD_CAMPAIGN_ACK = "XComCoopCampaignAck";     // client -> host: fingerprint of what arrived
const CMD_ARRIVED = "XComCoopArrived";              // client -> host: on the Avenger, still connected

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

// An invite that arrived while we were not in a lobby, waiting for the player's answer.
var UniqueNetId PendingInviteLobbyId;

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

/// Joins the lobby of an invite.
function Join(UniqueNetId InLobbyId)
{
	local OnlineGameInterfaceXCom GameInterface;

	if (IsActive())
	{
		Leave();
	}
	Reset();
	Init();
	GameInterface = class'XComCoop_Util'.static.GetGameInterface();

	bIsHost = false;
	LobbyId = InLobbyId;
	SetState(eCoopState_JoiningLobby);
	if (GameInterface == none || !GameInterface.JoinLobby(LobbyId))
	{
		Fail(strJoinLobbyFailed);
	}
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
		AcceptInvite(InLobbyId);
		return;
	}

	PendingInviteLobbyId = InLobbyId;
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

	if (eAction == 'eUIAction_Accept' && PendingInviteLobbyId != EmptyId)
	{
		AcceptInvite(PendingInviteLobbyId);
	}
	PendingInviteLobbyId = EmptyId;
}

function AcceptInvite(UniqueNetId InLobbyId)
{
	class'XComCoop_UILobby'.static.Open();
	Join(InLobbyId);
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
	local XComGameStateNetworkManager NetMgr;
	local array<byte> Params;
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

	NetMgr = `XCOMNETMANAGER;
	SentFingerprint = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(SentFingerprint, Params);
	NetMgr.SendRemoteCommand(CMD_CAMPAIGN, Params);
	CampaignSendTime = class'XComCoop_Util'.static.Now();
	NetMgr.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	Say("Session: campaign sent to " $ OtherName() $ ", fingerprint " $ SentFingerprint);
	SetState(eCoopState_SendingCampaign);
}

/// Client: the host announces the campaign that follows.
function HandleCampaignCommand(array<byte> RawParams)
{
	if (bIsHost || SessionState != eCoopState_Ready)
	{
		return;
	}
	ExpectedFingerprint = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	Say("Session: the host is sending the campaign: " $ ExpectedFingerprint);
	SetState(eCoopState_LoadingCampaign);
}

/// Client: the campaign arrived. The network manager has already put it in XCOMHISTORY.
function HandleReceiveHistory(XComGameStateHistory InHistory, X2EventManager EventManager)
{
	local array<byte> Params;

	if (bIsHost || (SessionState != eCoopState_LoadingCampaign && SessionState != eCoopState_Ready))
	{
		Say("Session: ignored a history in state " $ StateName());
		return;
	}
	if (InHistory != none && InHistory != `XCOMHISTORY)
	{
		Say("Session: WARNING the received history is not XCOMHISTORY");
	}

	ReceivedFingerprint = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	Say("Session: campaign received, fingerprint " $ ReceivedFingerprint);
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
	local array<byte> Params;
	local string Fp;

	if (bIsHost || SessionState != eCoopState_LoadingCampaign)
	{
		return;
	}
	Fp = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	Notices.AddItem(Repl(strArrivedClient, "%PLAYER", OtherName()));
	if (class'XComCoop_Util'.static.IsConnected())
	{
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(Fp, Params);
		`XCOMNETMANAGER.SendRemoteCommand(CMD_ARRIVED, Params);
		Say("Session: on the Avenger and still connected to the host. fingerprint " $ Fp);
	}
	else
	{
		Notices.AddItem(strConnectionLostLoading);
		Say("Session: on the Avenger, but the connection to the host is closed. fingerprint " $ Fp);
	}
	SetState(eCoopState_InCampaign);
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

/// Host: the client is on the Avenger and the connection survived its map load.
function HandleArrived(array<byte> RawParams)
{
	if (!bIsHost)
	{
		return;
	}
	Say("Session: " $ OtherName() $ " is on the Avenger, the connection survived the map load. fingerprint "
		$ class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams));
	Notices.AddItem(Repl(strClientArrived, "%PLAYER", OtherName()));
	NotifyChanged();
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
}

function NotifyChanged()
{
	ChangeCount++;
}

static function Say(string Msg)
{
	class'XComCoop_Util'.static.Say(Msg);
}
