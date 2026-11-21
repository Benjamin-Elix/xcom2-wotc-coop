//---------------------------------------------------------------------------------------
//  FILE:    X2DownloadableContentInfo_XComCoopStrategyTest.uc
//  PURPOSE: Phase 0 test 4 console commands (enter strategy from a history file instead
//           of a save). The logic lives in XComCoop_StrategyStartTest. Requires
//           -allowconsole. Remove this class once phase 0 is done.
//
//  Avenger (normal save):   CoopHistoryToFile
//  Main menu:               CoopHistoryFromFile, then CoopStartStrategy [plain]
//  Avenger (after start):   CoopStrategyCheck
//---------------------------------------------------------------------------------------
class X2DownloadableContentInfo_XComCoopStrategyTest extends X2DownloadableContentInfo;

static event OnLoadedSavedGameToStrategy()
{
	class'XComCoop_StrategyStartTest'.static.Get().OnLoadedToStrategy();
}

exec function CoopHistoryFromFile()
{
	class'XComCoop_StrategyStartTest'.static.Get().ReadFromFile();
}

exec function CoopStartStrategy(optional string Mode)
{
	class'XComCoop_StrategyStartTest'.static.Get().StartStrategy(Mode);
}

exec function CoopStrategyCheck()
{
	class'XComCoop_StrategyStartTest'.static.Get().Check();
}

// Phase 2 mapping: how often and how the campaign changes while playing (XComCoop_ChangeWatch).

exec function CoopWatchStart()
{
	class'XComCoop_ChangeWatch'.static.Get().Start();
}

exec function CoopWatchReport()
{
	class'XComCoop_ChangeWatch'.static.Get().Report();
}

exec function CoopWatchStop()
{
	class'XComCoop_ChangeWatch'.static.Get().Stop();
}
