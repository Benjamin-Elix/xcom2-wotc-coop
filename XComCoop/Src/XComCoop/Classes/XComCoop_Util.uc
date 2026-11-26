//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_Util.uc
//  PURPOSE: Small shared helpers: Steam IDs, addresses, the online interfaces, the
//           presentation layer and a fingerprint of the campaign history.
//---------------------------------------------------------------------------------------
class XComCoop_Util extends Object;

static function OnlineGameInterfaceXCom GetGameInterface()
{
	local OnlineSubsystem OnlineSub;

	OnlineSub = class'GameEngine'.static.GetOnlineSubsystem();
	if (OnlineSub == none)
	{
		return none;
	}
	return OnlineGameInterfaceXCom(OnlineSub.GameInterface);
}

/// Turns Steam's P2P relay on or off for this player's own Steam connection.
///
/// XCOM turns relay off when Steam starts: UOnlineSubsystemSteamworks' init calls
/// SteamNetworking()->AllowP2PPacketRelay(false) (XCom2.exe, found 22.11.2026). Without relay
/// two players only reach each other if their routers let a direct connection through, and
/// that failed between two ordinary home networks: the host never saw a request
/// (docs/KARTLEGGING-NETTVERK.md). Steam game servers keep relay on.
/// bForceClient=true: the player's own connection even when a Steam game server exists.
/// Steam applies the setting to connections made after the call.
static function SetSteamRelay(bool bAllow)
{
	local OnlineGameInterfaceXCom GameInterface;

	GameInterface = GetGameInterface();
	if (GameInterface != none)
	{
		GameInterface.AllowP2PPacketRelay(bAllow, true);
	}
}

static function OnlinePlayerInterface GetPlayerInterface()
{
	local OnlineSubsystem OnlineSub;

	OnlineSub = class'GameEngine'.static.GetOnlineSubsystem();
	if (OnlineSub == none)
	{
		return none;
	}
	return OnlineSub.PlayerInterface;
}

static function bool GetMyId(out UniqueNetId MyId)
{
	local OnlinePlayerInterface PlayerInterface;

	PlayerInterface = GetPlayerInterface();
	return PlayerInterface != none && PlayerInterface.GetUniquePlayerId(0, MyId);
}

static function string GetMyName()
{
	local OnlinePlayerInterface PlayerInterface;

	PlayerInterface = GetPlayerInterface();
	return PlayerInterface != none ? PlayerInterface.GetPlayerNickname(0) : "";
}

static function string IdToHex(UniqueNetId Id)
{
	return class'OnlineSubsystem'.static.UniqueNetIdToHexString(Id);
}

/// The Steam name of a friend, or "" if the ID is not on the friends list.
static function string GetFriendName(UniqueNetId Id)
{
	local OnlinePlayerInterface PlayerInterface;
	local array<OnlineFriend> Friends;
	local int i;

	PlayerInterface = GetPlayerInterface();
	if (PlayerInterface == none)
	{
		return "";
	}
	PlayerInterface.GetFriendsList(0, Friends);
	for (i = 0; i < Friends.Length; i++)
	{
		if (Friends[i].UniqueId == Id)
		{
			return Friends[i].NickName;
		}
	}
	return "";
}

/// Turns a player ID into the "steam.<SteamID64>" address the Steam net driver expects
/// (format string "steam.%I64u" in XCom2.exe). Accepts the hex form from
/// UniqueNetIdToHexString (with or without 0x), a 17-digit decimal SteamID64, or a full
/// "steam." address. Returns "" for invalid input.
static function string ToSteamAddress(string Id)
{
	local string Decimal;

	if (Left(Id, 6) ~= "steam.")
	{
		return Id;
	}
	if (Left(Id, 2) ~= "0x")
	{
		Id = Mid(Id, 2);
	}
	// A SteamID64 is 17 decimal digits; the hex form is shorter.
	if (Len(Id) == 17 && IsDigits(Id))
	{
		return "steam." $ Id;
	}

	Decimal = HexToDecimal(Id);
	return Decimal != "" ? "steam." $ Decimal : "";
}

static function string IdToSteamAddress(UniqueNetId Id)
{
	return ToSteamAddress(IdToHex(Id));
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

static function XComPresentationLayerBase GetPres()
{
	local XComPlayerController PC;

	PC = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController());
	return PC != none ? PC.Pres : none;
}

static function bool IsInShell()
{
	return XComShellPresentationLayer(GetPres()) != none;
}

/// True on the Avenger / Geoscape (strategy), false in the main menu and in missions.
static function bool IsInStrategy()
{
	return XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game) != none;
}

static function bool IsConnected()
{
	return `XCOMNETMANAGER.HasConnections();
}

/// Seconds since the current map was loaded. Only for measuring times on one map.
static function float Now()
{
	return class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds;
}

/// "12.3" for 12.345
static function string FormatSeconds(float Seconds)
{
	local int Tenths;

	Tenths = int(Seconds * 10.0 + 0.5);
	return (Tenths / 10) $ "." $ (Tenths % 10);
}

// --- Fingerprint of a history ----------------------------------------------------------------

/// A short summary of a history that both PCs can compare. Fields are separated by '|'.
static function string HistoryFingerprint(XComGameStateHistory History)
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

/// Lists the fields that differ between two fingerprints, as "[sent -> received]".
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
	class'X2DownloadableContentInfo_XComCoop'.static.Say(Msg);
}
