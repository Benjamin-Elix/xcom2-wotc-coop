//---------------------------------------------------------------------------------------
//  FILE:    X2DownloadableContentInfo_XComCoopTests.uc
//  PURPOSE: Phase 0 console commands for testing Steam P2P between two PCs.
//           The game's own MP* cheat commands report through `log, which is compiled out
//           of the release build, so they print nothing. These commands print to the
//           console window and to Launch.log (tag XComCoop). Requires -allowconsole.
//           Remove this class once phase 0 is done.
//---------------------------------------------------------------------------------------
class X2DownloadableContentInfo_XComCoopTests extends X2DownloadableContentInfo;

var int PingCounter;

/// Prints the local player's Steam ID in the hex form the other commands take.
exec function CoopMyId()
{
	local UniqueNetId MyId;

	if (!GetMyId(MyId))
	{
		Say("CoopMyId: could not read own Steam ID (is Steam running?)");
		return;
	}
	Say("CoopMyId: " $ class'OnlineSubsystem'.static.UniqueNetIdToHexString(MyId));
}

/// Sends one short text packet to the given Steam ID (hex).
exec function CoopP2PSend(string SteamIdHex)
{
	local OnlineGameInterfaceXCom GameInterface;
	local UniqueNetId TargetId, MyId;
	local array<byte> Data;
	local string Text;
	local bool bSent;

	GameInterface = GetGameInterface();
	if (GameInterface == none || !ParseId(SteamIdHex, TargetId))
	{
		return;
	}

	PingCounter++;
	GetMyId(MyId);
	Text = "XComCoop ping #" $ PingCounter $ " from " $ class'OnlineSubsystem'.static.UniqueNetIdToHexString(MyId);
	StringToBytes(Text, Data);

	bSent = GameInterface.SendP2PData(TargetId, Data);
	Say("CoopP2PSend to " $ SteamIdHex $ ": " $ (bSent ? "sent" : "FAILED") $ " (" $ Data.Length $ " bytes) '" $ Text $ "'");
}

/// Accepts a P2P session with the given Steam ID (hex).
exec function CoopP2PAccept(string SteamIdHex)
{
	local OnlineGameInterfaceXCom GameInterface;
	local UniqueNetId TargetId;
	local bool bAccepted;

	GameInterface = GetGameInterface();
	if (GameInterface == none || !ParseId(SteamIdHex, TargetId))
	{
		return;
	}

	bAccepted = GameInterface.AcceptP2PSessionWithUser(TargetId);
	Say("CoopP2PAccept " $ SteamIdHex $ ": " $ (bAccepted ? "ok" : "FAILED"));
}

/// Reads every packet waiting in the queue and prints sender and content.
exec function CoopP2PRead()
{
	local OnlineGameInterfaceXCom GameInterface;
	local UniqueNetId SenderId;
	local array<byte> Data;
	local int Count;

	GameInterface = GetGameInterface();
	if (GameInterface == none)
	{
		return;
	}

	// Cap the loop so a flood of packets cannot hang the game.
	while (Count < 64)
	{
		Data.Length = 0;
		if (!GameInterface.ReadP2PData(Data, SenderId) || Data.Length == 0)
		{
			break;
		}
		Count++;
		Say("CoopP2PRead #" $ Count $ " from " $ class'OnlineSubsystem'.static.UniqueNetIdToHexString(SenderId)
			$ " (" $ Data.Length $ " bytes): '" $ BytesToString(Data) $ "'");
	}

	if (Count == 0)
	{
		Say("CoopP2PRead: nothing received");
	}
}

/// Prints whether Steam reports an active P2P session with the given Steam ID (hex).
exec function CoopP2PState(string SteamIdHex)
{
	local OnlineGameInterfaceXCom GameInterface;
	local UniqueNetId TargetId;

	GameInterface = GetGameInterface();
	if (GameInterface == none || !ParseId(SteamIdHex, TargetId))
	{
		return;
	}

	Say("CoopP2PState " $ SteamIdHex $ ": " $ (GameInterface.GetP2PSessionState(TargetId) ? "active" : "none"));
}

// --- Helpers -----------------------------------------------------------------------------

static function Say(string Msg)
{
	class'X2DownloadableContentInfo_XComCoop'.static.Say(Msg);
}

static function OnlineGameInterfaceXCom GetGameInterface()
{
	local OnlineSubsystem OnlineSub;
	local OnlineGameInterfaceXCom GameInterface;

	OnlineSub = class'GameEngine'.static.GetOnlineSubsystem();
	if (OnlineSub != none)
	{
		GameInterface = OnlineGameInterfaceXCom(OnlineSub.GameInterface);
	}
	if (GameInterface == none)
	{
		Say("Steam game interface not available (is Steam running?)");
	}
	return GameInterface;
}

static function bool GetMyId(out UniqueNetId MyId)
{
	local OnlineSubsystem OnlineSub;

	OnlineSub = class'GameEngine'.static.GetOnlineSubsystem();
	return OnlineSub != none && OnlineSub.PlayerInterface != none && OnlineSub.PlayerInterface.GetUniquePlayerId(0, MyId);
}

static function bool ParseId(string SteamIdHex, out UniqueNetId Id)
{
	if (SteamIdHex == "" || !class'OnlineSubsystem'.static.StringToUniqueNetId(SteamIdHex, Id))
	{
		Say("Invalid Steam ID '" $ SteamIdHex $ "'. Use the hex form printed by CoopMyId.");
		return false;
	}
	return true;
}

static function StringToBytes(string Text, out array<byte> Data)
{
	local int i;

	Data.Length = Len(Text);
	for (i = 0; i < Len(Text); i++)
	{
		Data[i] = Asc(Mid(Text, i, 1)) & 0xFF;
	}
}

static function string BytesToString(const out array<byte> Data)
{
	local string Text;
	local int i;

	for (i = 0; i < Data.Length; i++)
	{
		// Show non-printable bytes as '?' so binary data stays readable.
		Text $= (Data[i] >= 32 && Data[i] < 127) ? Chr(Data[i]) : "?";
	}
	return Text;
}
