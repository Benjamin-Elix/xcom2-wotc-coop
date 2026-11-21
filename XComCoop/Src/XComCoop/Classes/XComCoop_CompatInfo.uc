//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_CompatInfo.uc
//  PURPOSE: What two PCs must agree on before they play together (phase 1):
//           protocol version, build of this mod, Highlander version and the list of
//           enabled mods and DLC. Both sides send theirs when they connect, and each side
//           compares. Anything blocking gives a clear message instead of a half-synced
//           campaign (DESIGN.md, section 1).
//
//           Wire format: values written with XComGameStateNetworkManager's
//           AddCommandParam_* in the order of WriteBytes(). ProtocolVersion always comes
//           first, so a build with another protocol can still read and report it.
//---------------------------------------------------------------------------------------
class XComCoop_CompatInfo extends Object;

struct CompatModEntry
{
	var string DLCName;
	var string FriendlyName;
};

var int ProtocolVersion;
var string BuildId;
var int EngineVersion;
var string HighlanderVersion;
var string PlayerName;
var array<CompatModEntry> Mods;     // enabled mods and DLC, minus ModsIgnoredInCompatCheck

// True when the data came from a different protocol; only ProtocolVersion is valid then.
var bool bProtocolOnly;

// Placeholders: %PLAYER, %LOCAL, %REMOTE, %MOD
var localized string strOtherPlayer;
var localized string strBadData;
var localized string strProtocolMismatch;
var localized string strBuildMismatch;
var localized string strBuildUncommitted;
var localized string strHighlanderMismatch;
var localized string strEngineMismatch;
var localized string strModMissingRemote;
var localized string strModMissingLocal;

// --- Building --------------------------------------------------------------------------------

static function XComCoop_CompatInfo BuildLocal()
{
	local XComCoop_CompatInfo Info;
	local XComOnlineEventMgr EventMgr;
	local OnlineSubsystem OnlineSub;
	local CompatModEntry Entry;
	local int i;

	Info = new class'XComCoop_CompatInfo';
	Info.ProtocolVersion = class'XComCoop_Config'.default.ProtocolVersion;
	Info.BuildId = class'XComCoop_BuildInfo'.const.BUILD_ID;
	Info.EngineVersion = Info.GetEngineVersion();
	Info.HighlanderVersion = class'CHXComGameVersionTemplate'.default.MajorVersion
		$ "." $ class'CHXComGameVersionTemplate'.default.MinorVersion
		$ "." $ class'CHXComGameVersionTemplate'.default.PatchVersion;

	OnlineSub = class'GameEngine'.static.GetOnlineSubsystem();
	if (OnlineSub != none && OnlineSub.PlayerInterface != none)
	{
		Info.PlayerName = OnlineSub.PlayerInterface.GetPlayerNickname(0);
	}

	EventMgr = `ONLINEEVENTMGR;
	for (i = 0; i < EventMgr.GetNumDLC(); i++)
	{
		Entry.DLCName = string(EventMgr.GetDLCNames(i));
		if (IsIgnored(Entry.DLCName))
		{
			continue;
		}
		Entry.FriendlyName = EventMgr.GetDLCFriendlyName(Entry.DLCName);
		if (Entry.FriendlyName == "")
		{
			Entry.FriendlyName = Entry.DLCName;
		}
		Info.Mods.AddItem(Entry);
	}

	return Info;
}

// --- Wire format -----------------------------------------------------------------------------

function WriteBytes(out array<byte> Data)
{
	local int i;

	Data.Length = 0;
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(ProtocolVersion, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(BuildId, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(EngineVersion, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(HighlanderVersion, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(PlayerName, Data);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Mods.Length, Data);
	for (i = 0; i < Mods.Length; i++)
	{
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(Mods[i].DLCName, Data);
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(Mods[i].FriendlyName, Data);
	}
}

/// Returns none if the data is empty or cut short.
static function XComCoop_CompatInfo ReadBytes(array<byte> Data)
{
	local XComCoop_CompatInfo Info;
	local CompatModEntry Entry;
	local int NumMods, i;

	if (Data.Length == 0)
	{
		return none;
	}

	Info = new class'XComCoop_CompatInfo';
	Info.ProtocolVersion = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(Data);
	if (Info.ProtocolVersion != class'XComCoop_Config'.default.ProtocolVersion)
	{
		// The rest may be in a format this build does not know.
		Info.bProtocolOnly = true;
		return Info;
	}

	if (Data.Length == 0) return none;
	Info.BuildId = class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data);
	if (Data.Length == 0) return none;
	Info.EngineVersion = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(Data);
	if (Data.Length == 0) return none;
	Info.HighlanderVersion = class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data);
	if (Data.Length == 0) return none;
	Info.PlayerName = class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data);
	if (Data.Length == 0) return none;
	NumMods = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(Data);

	for (i = 0; i < NumMods; i++)
	{
		if (Data.Length == 0) return none;
		Entry.DLCName = class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data);
		if (Data.Length == 0) return none;
		Entry.FriendlyName = class'XComGameStateNetworkManager'.static.GetCommandParam_String(Data);
		Info.Mods.AddItem(Entry);
	}

	return Info;
}

// --- Comparing -------------------------------------------------------------------------------

/// Compares the local info with the other player's. Problems block playing together,
/// warnings are shown but do not block. Returns true when there are no problems.
static function bool Compare(XComCoop_CompatInfo LocalInfo, XComCoop_CompatInfo RemoteInfo, out array<string> Problems, out array<string> Warnings)
{
	local string Player;
	local int i;

	Problems.Length = 0;
	Warnings.Length = 0;

	if (RemoteInfo == none)
	{
		Problems.AddItem(default.strBadData);
		return false;
	}

	Player = RemoteInfo.PlayerName != "" ? RemoteInfo.PlayerName : default.strOtherPlayer;

	if (RemoteInfo.bProtocolOnly || LocalInfo.ProtocolVersion != RemoteInfo.ProtocolVersion)
	{
		// Nothing else can be trusted across protocols.
		Problems.AddItem(Fill(default.strProtocolMismatch, Player, string(LocalInfo.ProtocolVersion), string(RemoteInfo.ProtocolVersion), ""));
		return false;
	}

	// Two builds of the same commit only differ in build time, which is fine (each player may
	// build from the repo). A build with uncommitted changes may differ, so that only warns.
	if (BuildCommit(LocalInfo.BuildId) != BuildCommit(RemoteInfo.BuildId))
	{
		Problems.AddItem(Fill(default.strBuildMismatch, Player, LocalInfo.BuildId, RemoteInfo.BuildId, ""));
	}
	else if (LocalInfo.BuildId != RemoteInfo.BuildId && (IsDirtyBuild(LocalInfo.BuildId) || IsDirtyBuild(RemoteInfo.BuildId)))
	{
		Warnings.AddItem(Fill(default.strBuildUncommitted, Player, LocalInfo.BuildId, RemoteInfo.BuildId, ""));
	}
	if (LocalInfo.HighlanderVersion != RemoteInfo.HighlanderVersion)
	{
		Problems.AddItem(Fill(default.strHighlanderMismatch, Player, LocalInfo.HighlanderVersion, RemoteInfo.HighlanderVersion, ""));
	}
	if (LocalInfo.EngineVersion != RemoteInfo.EngineVersion)
	{
		Warnings.AddItem(Fill(default.strEngineMismatch, Player, string(LocalInfo.EngineVersion), string(RemoteInfo.EngineVersion), ""));
	}

	for (i = 0; i < LocalInfo.Mods.Length; i++)
	{
		if (!IsIgnored(LocalInfo.Mods[i].DLCName) && RemoteInfo.FindMod(LocalInfo.Mods[i].DLCName) == INDEX_NONE)
		{
			AddModDifference(Fill(default.strModMissingRemote, Player, "", "", LocalInfo.Mods[i].FriendlyName), Problems, Warnings);
		}
	}
	for (i = 0; i < RemoteInfo.Mods.Length; i++)
	{
		if (!IsIgnored(RemoteInfo.Mods[i].DLCName) && LocalInfo.FindMod(RemoteInfo.Mods[i].DLCName) == INDEX_NONE)
		{
			AddModDifference(Fill(default.strModMissingLocal, Player, "", "", RemoteInfo.Mods[i].FriendlyName), Problems, Warnings);
		}
	}

	return Problems.Length == 0;
}

/// A different mod list blocks only when bRequireIdenticalModList is set.
static function AddModDifference(string Msg, out array<string> Problems, out array<string> Warnings)
{
	if (class'XComCoop_Config'.default.bRequireIdenticalModList)
	{
		Problems.AddItem(Msg);
	}
	else
	{
		Warnings.AddItem(Msg);
	}
}

function int FindMod(string DLCName)
{
	local int i;

	for (i = 0; i < Mods.Length; i++)
	{
		if (Mods[i].DLCName ~= DLCName)
		{
			return i;
		}
	}
	return INDEX_NONE;
}

static function bool IsIgnored(string DLCName)
{
	local string Ignored;

	foreach class'XComCoop_Config'.default.ModsIgnoredInCompatCheck(Ignored)
	{
		if (Ignored ~= DLCName)
		{
			return true;
		}
	}
	return false;
}

/// The commit part of a build ID ("901d79f-dirty 20261121-214016Z" -> "901d79f").
static function string BuildCommit(string Id)
{
	local int Space;

	Space = InStr(Id, " ");
	if (Space != INDEX_NONE)
	{
		Id = Left(Id, Space);
	}
	return Repl(Id, "-dirty", "");
}

static function bool IsDirtyBuild(string Id)
{
	return InStr(Id, "-dirty") != INDEX_NONE;
}

static function string Fill(string Msg, string Player, string LocalValue, string RemoteValue, string ModName)
{
	Msg = Repl(Msg, "%PLAYER", Player);
	Msg = Repl(Msg, "%LOCAL", LocalValue);
	Msg = Repl(Msg, "%REMOTE", RemoteValue);
	Msg = Repl(Msg, "%MOD", ModName);
	return Msg;
}

/// One line for logs and the console.
function string Summary()
{
	return "protocol=" $ ProtocolVersion
		$ " build='" $ BuildId $ "'"
		$ " engine=" $ EngineVersion
		$ " highlander=" $ HighlanderVersion
		$ " player='" $ PlayerName $ "'"
		$ " mods=" $ Mods.Length;
}
