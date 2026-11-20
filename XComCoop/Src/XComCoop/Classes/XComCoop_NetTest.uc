//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_NetTest.uc
//  PURPOSE: Phase 0 test 2: connect two PCs through the game's own network manager
//           (XComGameStateNetworkManager over Steam sockets) and send a whole campaign
//           history from one to the other.
//
//           The sender announces a fingerprint of its history, sends the history, and the
//           receiver answers with the fingerprint of what arrived. The sender then prints
//           the round trip time and whether the two match.
//
//           The class default object (Get()) holds the delegates and the test state, so it
//           does not matter which object the console calls the exec functions on, and it is
//           never garbage collected. Same pattern as CHHelpers.GetCDO() in the Highlander.
//           Console commands are in X2DownloadableContentInfo_XComCoopNetTest.
//           Remove this class once phase 0 is done.
//---------------------------------------------------------------------------------------
class XComCoop_NetTest extends Object;

// Remote command names. Both PCs must run the same build.
const CMD_EXPECT_HISTORY = "XComCoopExpectHistory";
const CMD_HISTORY_ACK = "XComCoopHistoryAck";

// Where CoopHistoryToFile writes. Lands under Documents\My Games\XCOM2 War of the Chosen\XComGame\
// (as <name>.x2hist), not under the game folder as XComGameStateHistory.uc claims.
const HISTORY_FILE_FOLDER = "SaveData_Dev/";
const HISTORY_FILE_NAME = "XComCoop_History";

var bool bDelegatesAdded;
var bool bJoined;
var int ConnectAttemptsLeft;

// Sender side
var float SendStartTime;
var string SentFingerprint;

// Receiver side
var string ExpectedFingerprint;
var string ReceivedFingerprint;

// What has arrived so far, to see whether the game sends anything on its own.
var int NumHistories;
var int NumPartialHistories;
var int NumGameStates;
var int NumMergeGameStates;
var int NumContexts;
var int NumRemoteCommands;

static function XComCoop_NetTest Get()
{
	return XComCoop_NetTest(class'XComEngine'.static.GetClassDefaultObject(class'XComCoop_NetTest'));
}

// --- Commands ----------------------------------------------------------------------------

/// Starts a server that the other PC can join with CoopNetJoin.
function Host()
{
	local XComGameStateNetworkManager NetMgr;
	local URL ServerURL;
	local string Error;
	local bool bOk;
	local UniqueNetId MyId;

	NetMgr = `XCOMNETMANAGER;
	if (NetMgr.HasServerConnection() || NetMgr.HasClientConnection())
	{
		Say("CoopNetHost: a connection already exists. Run CoopNetDisconnect first.");
		return;
	}

	AddDelegates();
	ServerURL.Port = class'XComCoop_Config'.default.TestNetPort;
	ServerURL.Op.AddItem("steamsockets");
	bOk = NetMgr.CreateServer(ServerURL, Error);
	if (Error != "")
	{
		Say("CoopNetHost: FAILED (returned " $ bOk $ "): '" $ Error $ "'");
		return;
	}

	Say("CoopNetHost: server started on port " $ ServerURL.Port $ " (returned " $ bOk $ ") at " $ Clock());
	if (class'X2DownloadableContentInfo_XComCoopTests'.static.GetMyId(MyId))
	{
		Say("CoopNetHost: the other player runs:  CoopNetJoin " $ class'OnlineSubsystem'.static.UniqueNetIdToHexString(MyId));
	}
}

/// Connects to a server started with CoopNetHost.
/// HostId: the host's Steam ID in hex (from CoopMyId), as a 17-digit decimal SteamID64,
/// or a full "steam.<SteamID64>" address.
function Join(string HostId)
{
	local XComGameStateNetworkManager NetMgr;
	local URL ClientURL;
	local string Address, Error;
	local bool bOk;

	NetMgr = `XCOMNETMANAGER;
	if (NetMgr.HasServerConnection() || NetMgr.HasClientConnection())
	{
		Say("CoopNetJoin: a connection already exists. Run CoopNetDisconnect first.");
		return;
	}

	Address = ToSteamAddress(HostId);
	if (Address == "")
	{
		return;
	}

	AddDelegates();
	bJoined = false;
	ClientURL.Host = Address;
	ClientURL.Port = class'XComCoop_Config'.default.TestNetPort;
	ClientURL.Op.AddItem("steamsockets");
	bOk = NetMgr.CreateClient(ClientURL, Error);
	if (Error != "")
	{
		Say("CoopNetJoin: FAILED (returned " $ bOk $ "): '" $ Error $ "'");
		return;
	}

	Say("CoopNetJoin: connecting to " $ Address $ ":" $ ClientURL.Port $ " (returned " $ bOk $ ") at " $ Clock());

	// Same as the game's own flow: ask the server for a connection after a short delay.
	ConnectAttemptsLeft = class'XComCoop_Config'.default.TestConnectAttempts;
	ScheduleConnectAttempt();
}

/// Asks the server for a connection again. Normally CoopNetJoin does this by itself.
function Retry()
{
	Say("CoopNetRetry: ForceConnectionAttempt returned " $ `XCOMNETMANAGER.ForceConnectionAttempt());
}

/// Prints the connection state and what has been received.
function Status()
{
	local XComGameStateNetworkManager NetMgr;
	local int i;

	NetMgr = `XCOMNETMANAGER;
	Say("CoopNetStatus: server=" $ NetMgr.HasServerConnection()
		$ " client=" $ NetMgr.HasClientConnection()
		$ " joined=" $ bJoined
		$ " connections=" $ NetMgr.Connections.Length
		$ " pending in/out=" $ NetMgr.InGameData.Length $ "/" $ NetMgr.OutGameData.Length
		$ " (" $ QueuedBytes(NetMgr) $ " bytes out)");
	for (i = 0; i < NetMgr.Connections.Length; i++)
	{
		Say("  connection " $ NetMgr.GetConnectionInfoDebugString(i));
	}
	Say("  received: histories=" $ NumHistories
		$ " partial=" $ NumPartialHistories
		$ " gamestates=" $ NumGameStates
		$ " merges=" $ NumMergeGameStates
		$ " contexts=" $ NumContexts
		$ " commands=" $ NumRemoteCommands);
}

/// Sends the whole local history to the other PC.
function SendHistory()
{
	local XComGameStateNetworkManager NetMgr;
	local XComGameStateHistory History;
	local array<byte> Params;
	local int BytesBefore, BytesQueued;

	NetMgr = `XCOMNETMANAGER;
	if (!NetMgr.HasConnections())
	{
		Say("CoopNetSendHistory: not connected. Use CoopNetHost / CoopNetJoin first.");
		return;
	}

	History = `XCOMHISTORY;
	SentFingerprint = Fingerprint(History);

	// Announce what is coming so the receiver can compare on its own.
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(SentFingerprint, Params);
	NetMgr.SendRemoteCommand(CMD_EXPECT_HISTORY, Params);

	BytesBefore = QueuedBytes(NetMgr);
	SendStartTime = Now();
	NetMgr.SendHistory(History, `XEVENTMGR);
	BytesQueued = QueuedBytes(NetMgr) - BytesBefore;

	Say("CoopNetSendHistory: sending at " $ Clock() $ ", " $ BytesQueued $ " bytes queued (0 = not visible from script)");
	Say("CoopNetSendHistory: fingerprint " $ SentFingerprint);
	Say("CoopNetSendHistory: waiting for the other PC to confirm...");
}

/// Closes the connection. Our NotifyConnectionClosed delegate stays registered so the game
/// does not throw us back to the main menu.
function Disconnect()
{
	`XCOMNETMANAGER.Disconnect();
	bJoined = false;
	ConnectAttemptsLeft = 0;
	Say("CoopNetDisconnect: disconnected at " $ Clock());
}

/// Prints the fingerprint of the local history.
function HistoryInfo()
{
	Say("CoopHistoryInfo: " $ Fingerprint(`XCOMHISTORY));
}

/// Writes the local history to My Games\...\XComGame\SaveData_Dev\XComCoop_History.x2hist, to measure its size.
function HistoryToFile()
{
	local bool bOk;

	bOk = `XCOMHISTORY.WriteHistoryToFile(HISTORY_FILE_FOLDER, HISTORY_FILE_NAME);
	Say("CoopHistoryToFile: " $ (bOk ? "written" : "FAILED") $ " to My Games\\XCOM2 War of the Chosen\\XComGame\\" $ HISTORY_FILE_FOLDER $ HISTORY_FILE_NAME $ ".x2hist");
	Say("CoopHistoryToFile: fingerprint " $ Fingerprint(`XCOMHISTORY));
}

// --- Connection ----------------------------------------------------------------------------

function ScheduleConnectAttempt()
{
	class'Engine'.static.GetCurrentWorldInfo().SetTimer(class'XComCoop_Config'.default.TestConnectRetrySeconds, false, nameof(ConnectAttempt), self);
}

function ConnectAttempt()
{
	local bool bOk;

	if (bJoined || ConnectAttemptsLeft <= 0)
	{
		if (!bJoined)
		{
			Say("CoopNetJoin: no answer from the host. Check that the host ran CoopNetHost, then try CoopNetRetry.");
		}
		return;
	}

	ConnectAttemptsLeft--;
	bOk = `XCOMNETMANAGER.ForceConnectionAttempt();
	Say("CoopNetJoin: connection attempt " $ (class'XComCoop_Config'.default.TestConnectAttempts - ConnectAttemptsLeft) $ " sent=" $ bOk);
	ScheduleConnectAttempt();
}

function AddDelegates()
{
	local XComGameStateNetworkManager NetMgr;

	if (bDelegatesAdded)
	{
		return;
	}
	bDelegatesAdded = true;

	NetMgr = `XCOMNETMANAGER;
	NetMgr.AddReceiveHistoryDelegate(HandleReceiveHistory);
	NetMgr.AddReceivePartialHistoryDelegate(HandleReceivePartialHistory);
	NetMgr.AddReceiveGameStateDelegate(HandleReceiveGameState);
	NetMgr.AddReceiveMergeGameStateDelegate(HandleReceiveMergeGameState);
	NetMgr.AddReceiveGameStateContextDelegate(HandleReceiveGameStateContext);
	NetMgr.AddReceiveRemoteCommandDelegate(HandleReceiveRemoteCommand);
	NetMgr.AddPlayerJoinedDelegate(HandlePlayerJoined);
	NetMgr.AddPlayerLeftDelegate(HandlePlayerLeft);
	NetMgr.AddNotifyAcceptedConnectionDelegate(HandleAcceptedConnection);
	// Without this the game returns to the main menu when the connection closes.
	NetMgr.AddNotifyConnectionClosedDelegate(HandleConnectionClosed);
}

// --- Delegates -----------------------------------------------------------------------------

function HandleReceiveHistory(XComGameStateHistory History, X2EventManager EventManager)
{
	local array<byte> Params;

	NumHistories++;
	if (History == none)
	{
		History = `XCOMHISTORY;
	}
	ReceivedFingerprint = Fingerprint(History);
	Say("CoopNet: received a full history at " $ Clock());
	Say("CoopNet: fingerprint " $ ReceivedFingerprint);
	CompareReceived();

	class'XComGameStateNetworkManager'.static.AddCommandParam_String(ReceivedFingerprint, Params);
	`XCOMNETMANAGER.SendRemoteCommand(CMD_HISTORY_ACK, Params);
	Say("CoopNet: confirmation sent to the other PC. Restart the game before playing on (the received history replaced yours in memory).");
}

function HandleReceivePartialHistory(XComGameStateHistory History, X2EventManager EventManager)
{
	NumPartialHistories++;
	SayFirstFew("partial history", NumPartialHistories);
}

function HandleReceiveGameState(XComGameState GameState)
{
	NumGameStates++;
	SayFirstFew("game state", NumGameStates);
}

function HandleReceiveMergeGameState(XComGameState GameState)
{
	NumMergeGameStates++;
	SayFirstFew("merge game state", NumMergeGameStates);
}

function HandleReceiveGameStateContext(XComGameStateContext Context)
{
	NumContexts++;
	SayFirstFew("context " $ (Context != none ? string(Context.Class.Name) : "none"), NumContexts);
}

function HandleReceiveRemoteCommand(string Command, array<byte> RawParams)
{
	local string Fp;

	NumRemoteCommands++;
	if (Command == CMD_EXPECT_HISTORY)
	{
		ExpectedFingerprint = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
		Say("CoopNet: the other PC is sending its history: " $ ExpectedFingerprint);
		if (ReceivedFingerprint != "")
		{
			CompareReceived();
		}
	}
	else if (Command == CMD_HISTORY_ACK)
	{
		Fp = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
		Say("CoopNetSendHistory: confirmed by the other PC after " $ (Now() - SendStartTime) $ " s (round trip)");
		if (Fp == SentFingerprint)
		{
			Say("CoopNetSendHistory: fingerprints MATCH");
		}
		else
		{
			Say("CoopNetSendHistory: fingerprints DIFFER. " $ DescribeDifference(SentFingerprint, Fp));
		}
	}
	else
	{
		Say("CoopNet: remote command '" $ Command $ "' (" $ RawParams.Length $ " bytes)");
	}
}

function HandlePlayerJoined(string RequestURL, string Address, const UniqueNetId UniqueId, bool bSupportsAuth)
{
	bJoined = true;
	Say("CoopNet: connected at " $ Clock() $ ". Player " $ class'OnlineSubsystem'.static.UniqueNetIdToHexString(UniqueId) $ " address '" $ Address $ "'");
}

function HandlePlayerLeft(const UniqueNetId UniqueId)
{
	Say("CoopNet: player " $ class'OnlineSubsystem'.static.UniqueNetIdToHexString(UniqueId) $ " left at " $ Clock());
}

function HandleAcceptedConnection(int ConnectionIdx)
{
	Say("CoopNet: accepted connection " $ ConnectionIdx $ " at " $ Clock() $ ". Run CoopNetStatus to see it.");
}

function HandleConnectionClosed(int ConnectionIdx)
{
	bJoined = false;
	Say("CoopNet: connection " $ ConnectionIdx $ " closed at " $ Clock());
}

// --- Fingerprint ---------------------------------------------------------------------------

/// A short summary of a history that both PCs can compare. Fields are separated by '|'.
static function string Fingerprint(XComGameStateHistory History)
{
	local XComGameState_BaseObject Obj;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_GameTime GameTime;
	local int NumObjects, IdSum, MaxId;
	local string Result;

	// bUnlimitedSearch: also count objects from before the last start state.
	foreach History.IterateByClassType(class'XComGameState_BaseObject', Obj,, true)
	{
		NumObjects++;
		IdSum += Obj.ObjectID;
		MaxId = Max(MaxId, Obj.ObjectID);
	}

	Result = "frames=" $ (History.GetCurrentHistoryIndex() + 1)
		$ "|objects=" $ NumObjects
		$ "|idsum=" $ IdSum
		$ "|maxid=" $ MaxId;

	foreach History.IterateByClassType(class'XComGameState_HeadquartersXCom', XComHQ)
	{
		Result $= "|soldiers=" $ XComHQ.GetNumberOfSoldiers() $ "|supplies=" $ XComHQ.GetSupplies();
		break;
	}

	foreach History.IterateByClassType(class'XComGameState_GameTime', GameTime)
	{
		Result $= "|date=" $ GameTime.CurrentTime.m_iYear $ "-" $ Pad(GameTime.CurrentTime.m_iMonth, 2) $ "-" $ Pad(GameTime.CurrentTime.m_iDay, 2)
			$ "|hour=" $ int(GameTime.CurrentTime.m_fTime / 3600.0);
		break;
	}

	return Result;
}

function CompareReceived()
{
	if (ExpectedFingerprint == "")
	{
		return;
	}
	if (ExpectedFingerprint == ReceivedFingerprint)
	{
		Say("CoopNet: fingerprints MATCH");
	}
	else
	{
		Say("CoopNet: fingerprints DIFFER. " $ DescribeDifference(ExpectedFingerprint, ReceivedFingerprint));
	}
}

/// Lists the fields that differ, as "name: sent -> received".
static function string DescribeDifference(string Sent, string Received)
{
	local array<string> SentParts, ReceivedParts;
	local string Result;
	local int i;

	ParseStringIntoArray(Sent, SentParts, "|", true);
	ParseStringIntoArray(Received, ReceivedParts, "|", true);
	for (i = 0; i < Max(SentParts.Length, ReceivedParts.Length); i++)
	{
		if (i >= SentParts.Length || i >= ReceivedParts.Length || SentParts[i] != ReceivedParts[i])
		{
			Result $= "[" $ (i < SentParts.Length ? SentParts[i] : "-") $ " -> " $ (i < ReceivedParts.Length ? ReceivedParts[i] : "-") $ "] ";
		}
	}
	return Result;
}

// --- Helpers -------------------------------------------------------------------------------

/// Turns a host ID into the "steam.<SteamID64>" address the Steam net driver expects
/// (format string "steam.%I64u" in XCom2.exe).
static function string ToSteamAddress(string HostId)
{
	local string Decimal;

	if (Left(HostId, 6) ~= "steam.")
	{
		return HostId;
	}
	if (Left(HostId, 2) ~= "0x")
	{
		HostId = Mid(HostId, 2);
	}
	// A SteamID64 is 17 decimal digits; the hex form from CoopMyId is shorter.
	if (Len(HostId) == 17 && IsDigits(HostId))
	{
		return "steam." $ HostId;
	}

	Decimal = HexToDecimal(HostId);
	if (Decimal == "")
	{
		Say("Invalid host ID '" $ HostId $ "'. Use the hex form printed by CoopMyId.");
		return "";
	}
	return "steam." $ Decimal;
}

/// Converts a hex string of any length to decimal. UnrealScript ints are 32-bit, so this
/// works on decimal digits instead. Returns "" for invalid input.
static function string HexToDecimal(string Hex)
{
	local array<int> Digits;   // least significant first
	local int i, j, Value, Carry;
	local string Result;

	if (Hex == "")
	{
		return "";
	}

	Digits.AddItem(0);
	for (i = 0; i < Len(Hex); i++)
	{
		Carry = InStr("0123456789ABCDEF", Caps(Mid(Hex, i, 1)));
		if (Carry < 0)
		{
			return "";
		}
		for (j = 0; j < Digits.Length; j++)
		{
			Value = Digits[j] * 16 + Carry;
			Carry = Value / 10;
			Digits[j] = Value - Carry * 10;
		}
		while (Carry > 0)
		{
			Digits.AddItem(Carry - (Carry / 10) * 10);
			Carry = Carry / 10;
		}
	}

	for (i = Digits.Length - 1; i >= 0; i--)
	{
		Result $= string(Digits[i]);
	}
	return Result;
}

static function bool IsDigits(string Text)
{
	local int i;

	for (i = 0; i < Len(Text); i++)
	{
		if (InStr("0123456789", Mid(Text, i, 1)) < 0)
		{
			return false;
		}
	}
	return Text != "";
}

static function int QueuedBytes(XComGameStateNetworkManager NetMgr)
{
	local int i, Total;

	for (i = 0; i < NetMgr.OutGameData.Length; i++)
	{
		Total += NetMgr.OutGameData[i].GameStateRaw.Length;
	}
	return Total;
}

function SayFirstFew(string What, int Count)
{
	// Only print the first few so automatic traffic cannot flood the console.
	if (Count <= 3)
	{
		Say("CoopNet: received " $ What $ " #" $ Count $ " at " $ Clock());
	}
}

static function float Now()
{
	return class'Engine'.static.GetCurrentWorldInfo().RealTimeSeconds;
}

/// Wall clock as HH:MM:SS.mmm, to line up the two PCs' logs.
function string Clock()
{
	local int Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec;

	GetSystemTime(Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec);
	return Pad(Hour, 2) $ ":" $ Pad(Min, 2) $ ":" $ Pad(Sec, 2) $ "." $ Pad(MSec, 3);
}

static function string Pad(int Value, int Width)
{
	local string Text;

	Text = string(Value);
	while (Len(Text) < Width)
	{
		Text = "0" $ Text;
	}
	return Text;
}

static function Say(string Msg)
{
	class'X2DownloadableContentInfo_XComCoopTests'.static.Say(Msg);
}
