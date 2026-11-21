//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_Session.uc
//  PURPOSE: Phase 1: the co-op lobby. Owns the Steam lobby, the network connection and
//           the compatibility check, and tells the UI when anything changes.
//
//  Host:   Host() -> CreateLobby -> start the game server (Steam sockets) -> Invite(friend)
//  Client: invite received -> popup -> Join() -> JoinLobby -> connect to the lobby owner
//  Both:   connected -> exchange XComCoop_CompatInfo -> Ready, or Failed with clear reasons
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
	eCoopState_Failed,              // see Problems
};

// Remote command for the compatibility check. Not the same name as the phase 0 test.
const CMD_COMPAT = "XComCoopLobbyCompat";

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
	switch (SessionState)
	{
	case eCoopState_Checking:
	case eCoopState_Ready:
		if (bIsHost)
		{
			// Keep the lobby open so the host can invite again.
			Notices.AddItem(Repl(strPlayerLeft, "%PLAYER", OtherPlayerName != "" ? OtherPlayerName : strSomeone));
			OtherPlayerName = "";
			bCompatSent = false;
			StartServer();
			SetState(eCoopState_WaitingForPlayer);
		}
		else
		{
			Problems.AddItem(strConnectionLost);
			Leave(true);
		}
		break;
	default:
		break;
	}
}

function HandleRemoteCommand(string Command, array<byte> RawParams)
{
	if (Command != CMD_COMPAT)
	{
		return;
	}
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

// --- Compatibility check ---------------------------------------------------------------------

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

// --- SessionState -----------------------------------------------------------------------------------

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
}

function NotifyChanged()
{
	ChangeCount++;
}

static function Say(string Msg)
{
	class'XComCoop_Util'.static.Say(Msg);
}
