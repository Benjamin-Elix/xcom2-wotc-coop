//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_Util.uc
//  PURPOSE: Small shared helpers: Steam IDs, addresses, the online interfaces and the
//           presentation layer.
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

static function Say(string Msg)
{
	class'X2DownloadableContentInfo_XComCoop'.static.Say(Msg);
}
