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
class XComCoop_NetTest extends Object dependson(XComCoop_CompatInfo);

// Remote command names. Both PCs must run the same build.
const CMD_EXPECT_HISTORY = "XComCoopExpectHistory";
const CMD_HISTORY_ACK = "XComCoopHistoryAck";
const CMD_COMPAT = "XComCoopCompat";

// Where CoopHistoryToFile writes. Lands under Documents\My Games\XCOM2 War of the Chosen\XComGame\
// (as <name>.x2hist), not under the game folder as XComGameStateHistory.uc claims.
const HISTORY_FILE_FOLDER = "SaveData_Dev/";
const HISTORY_FILE_NAME = "XComCoop_History";

var bool bDelegatesAdded;
var bool bJoined;
var bool bCompatSent;
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
	bCompatSent = false;
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

	Address = class'XComCoop_Util'.static.ToSteamAddress(HostId);
	if (Address == "")
	{
		Say("Invalid host ID '" $ HostId $ "'. Use the hex form printed by CoopMyId.");
		return;
	}

	AddDelegates();
	bJoined = false;
	bCompatSent = false;
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
	bCompatSent = false;
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

	// Never overwrite the file with an empty history (e.g. typed in the main menu by mistake
	// instead of CoopHistoryFromFile): the file may be the only copy of a campaign.
	if (`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom', true) == none)
	{
		Say("CoopHistoryToFile: no campaign loaded, nothing written. The existing file is kept. (Did you mean CoopHistoryFromFile?)");
		return;
	}

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
	else if (Command == CMD_COMPAT)
	{
		// The client sends first when it has joined; the host answers with its own.
		if (!bCompatSent)
		{
			SendCompat();
		}
		CheckRemoteCompat(RawParams);
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
	SendCompat();
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
	bCompatSent = false;
	Say("CoopNet: connection " $ ConnectionIdx $ " closed at " $ Clock());
}

// --- Compatibility check (phase 1) ---------------------------------------------------------
// For now only reported, not enforced, so the test can go on even if the mod lists differ.

function SendCompat()
{
	local array<byte> Data;

	class'XComCoop_CompatInfo'.static.BuildLocal().WriteBytes(Data);
	`XCOMNETMANAGER.SendRemoteCommand(CMD_COMPAT, Data);
	bCompatSent = true;
	Say("CoopNet: sent compatibility info (" $ Data.Length $ " bytes)");
}

function CheckRemoteCompat(array<byte> Data)
{
	local XComCoop_CompatInfo Remote;
	local array<string> Problems, Warnings;
	local bool bOk;

	Remote = class'XComCoop_CompatInfo'.static.ReadBytes(Data);
	if (Remote != none)
	{
		Say("CoopNet: other PC: " $ Remote.Summary());
	}
	bOk = class'XComCoop_CompatInfo'.static.Compare(class'XComCoop_CompatInfo'.static.BuildLocal(), Remote, Problems, Warnings);
	Report("CoopNet: compatibility check", bOk, Problems, Warnings);
}

/// Tests the check on one PC: write and read back the local info, then compare it with
/// copies that have been changed on purpose.
function CompatSelfTest()
{
	local XComCoop_CompatInfo LocalInfo, Copy;
	local CompatModEntry FakeMod;
	local array<byte> Data;
	local array<string> Problems, Warnings;
	local bool bOk;

	LocalInfo = class'XComCoop_CompatInfo'.static.BuildLocal();
	Say("CoopCompatSelfTest: local " $ LocalInfo.Summary());

	// 1. Round trip through the wire format.
	LocalInfo.WriteBytes(Data);
	Say("CoopCompatSelfTest: written as " $ Data.Length $ " bytes");
	Copy = class'XComCoop_CompatInfo'.static.ReadBytes(Data);
	if (Copy == none)
	{
		Say("CoopCompatSelfTest: 1/3 FAILED, could not read the bytes back");
		return;
	}
	Say("CoopCompatSelfTest: read back " $ Copy.Summary());
	bOk = class'XComCoop_CompatInfo'.static.Compare(LocalInfo, Copy, Problems, Warnings);
	Report("CoopCompatSelfTest: 1/3 identical copy, expect compatible", bOk, Problems, Warnings);

	// 2. Other build, one mod missing, one extra mod, other engine version.
	LocalInfo.WriteBytes(Data);
	Copy = class'XComCoop_CompatInfo'.static.ReadBytes(Data);
	Copy.PlayerName = "TestPlayer";
	Copy.BuildId = "test-build";
	Copy.EngineVersion += 1;
	if (Copy.Mods.Length > 0)
	{
		Copy.Mods.Remove(0, 1);
	}
	FakeMod.DLCName = "XComCoopFakeTestMod";
	FakeMod.FriendlyName = "Fake Test Mod";
	Copy.Mods.AddItem(FakeMod);
	bOk = class'XComCoop_CompatInfo'.static.Compare(LocalInfo, Copy, Problems, Warnings);
	Report("CoopCompatSelfTest: 2/3 changed copy, expect 3 problems (build, 2 mods) and 1 warning (engine)", bOk, Problems, Warnings);

	// 3. Other protocol: only the version can be read.
	Copy.ProtocolVersion += 1;
	Copy.WriteBytes(Data);
	Copy = class'XComCoop_CompatInfo'.static.ReadBytes(Data);
	bOk = class'XComCoop_CompatInfo'.static.Compare(LocalInfo, Copy, Problems, Warnings);
	Report("CoopCompatSelfTest: 3/3 other protocol, expect 1 problem (protocol)", bOk, Problems, Warnings);
}

static function Report(string Title, bool bOk, const out array<string> Problems, const out array<string> Warnings)
{
	local int i;

	Say(Title $ ": " $ (bOk ? "COMPATIBLE" : "NOT COMPATIBLE") $ " (" $ Problems.Length $ " problems, " $ Warnings.Length $ " warnings)");
	for (i = 0; i < Problems.Length; i++)
	{
		Say("  problem: " $ (Problems[i] != "" ? Problems[i] : "(empty text, localization not loaded)"));
	}
	for (i = 0; i < Warnings.Length; i++)
	{
		Say("  warning: " $ (Warnings[i] != "" ? Warnings[i] : "(empty text, localization not loaded)"));
	}
}

// --- Fingerprint ---------------------------------------------------------------------------

static function string Fingerprint(XComGameStateHistory History)
{
	return class'XComCoop_Util'.static.HistoryFingerprint(History);
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

static function string DescribeDifference(string Sent, string Received)
{
	return class'XComCoop_Util'.static.DescribeDifference(Sent, Received);
}

// --- Helpers -------------------------------------------------------------------------------

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
	return class'XComCoop_Util'.static.Pad(Value, Width);
}

static function Say(string Msg)
{
	class'X2DownloadableContentInfo_XComCoopTests'.static.Say(Msg);
}
