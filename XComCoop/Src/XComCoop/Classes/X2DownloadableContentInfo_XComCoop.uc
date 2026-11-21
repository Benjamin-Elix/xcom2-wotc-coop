//---------------------------------------------------------------------------------------
//  FILE:    X2DownloadableContentInfo_XComCoop.uc
//  PURPOSE: Entry point for the co-op mod. The game calls the static events on this class
//           (OnLoadedSavedGame, InstallNewCampaign, OnPostTemplatesCreated, ...).
//           DLCIdentifier is set in Config/XComGame.ini.
//
//           Also holds the permanent diagnostic console commands (need -allowconsole).
//---------------------------------------------------------------------------------------
class X2DownloadableContentInfo_XComCoop extends X2DownloadableContentInfo;

/// Runs for every load into strategy, including the client entering the host's campaign.
static event OnLoadedSavedGameToStrategy()
{
	class'XComCoop_Session'.static.Get().OnLoadedToStrategy();
}

/// Prints what the compatibility check sends to the other player.
exec function CoopCompatInfo()
{
	local XComCoop_CompatInfo Info;
	local int i;

	Info = class'XComCoop_CompatInfo'.static.BuildLocal();
	Say("CoopCompatInfo: " $ Info.Summary());
	for (i = 0; i < Info.Mods.Length; i++)
	{
		Say("  " $ Info.Mods[i].DLCName $ " (" $ Info.Mods[i].FriendlyName $ ")");
	}
}

/// Prints to the console window and to Launch.log (tag XComCoop).
static function Say(string Msg)
{
	local GameViewportClient Viewport;

	`log(Msg,, 'XComCoop');

	Viewport = class'Engine'.static.GetEngine().GameViewport;
	if (Viewport != none && Viewport.ViewportConsole != none)
	{
		Viewport.ViewportConsole.OutputTextLine("[XComCoop] " $ Msg);
	}
}
