//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_StrategyStartTest.uc
//  PURPOSE: Phase 0 test 4 on one PC: can the game enter strategy (the Avenger) from a
//           history that did not come from a save? This is what the client must do in
//           phase 2 after receiving the host's campaign.
//
//           The game only does this for tactical (challenge, ladder, MP). For strategy,
//           XComHeadquartersGame.StartMatch picks one of two paths:
//             - ONLINEEVENTMGR.bPerformingStandardLoad set: FinishLoadGame, then
//               XGStrategy.OnLoadedGame -> state LoadingGame (what a normal load does).
//             - not set, history has more than one frame: XGStrategy.Init ->
//               TransferFromTactical (the "back from a mission" flow).
//           A received history has no save data behind it, so this test sets the flag
//           itself and sees what FinishLoadGame and the rest make of it.
//
//           1. Load a save on the Avenger:        CoopHistoryToFile (from test 2)
//           2. Restart the game, main menu:       CoopHistoryFromFile
//           3. Go to the Avenger:                 CoopStartStrategy  (or: CoopStartStrategy plain)
//           4. On the Avenger:                    CoopStrategyCheck
//
//           State is kept on the class default object, which survives map loads.
//           Remove this class once phase 0 is done.
//---------------------------------------------------------------------------------------
class XComCoop_StrategyStartTest extends Object;

const STRATEGY_MAP_COMMAND = "open Avenger_Root?game=XComGame.XComHeadQuartersGame";
const LOADING_SAVE_OPTION = "?LoadingSave";

var string FileFingerprint;
var int FileSoldiers;
var int FileSupplies;
var int FileMaxId;
var bool bStarted;
var bool bAsLoadedSave;
var bool bSawLoadedToStrategyHook;

static function XComCoop_StrategyStartTest Get()
{
	return XComCoop_StrategyStartTest(class'XComEngine'.static.GetClassDefaultObject(class'XComCoop_StrategyStartTest'));
}

function ReadFromFile()
{
	local XComGameStateHistory History;

	if (!class'XComCoop_Util'.static.IsInShell())
	{
		Say("CoopHistoryFromFile: run this in the main menu");
		return;
	}

	History = `XCOMHISTORY;
	if (!History.ReadHistoryFromFile(class'XComCoop_NetTest'.const.HISTORY_FILE_FOLDER, class'XComCoop_NetTest'.const.HISTORY_FILE_NAME))
	{
		Say("CoopHistoryFromFile: could not read My Games\\XCOM2 War of the Chosen\\XComGame\\"
			$ class'XComCoop_NetTest'.const.HISTORY_FILE_FOLDER $ class'XComCoop_NetTest'.const.HISTORY_FILE_NAME
			$ ".x2hist. Write it with CoopHistoryToFile on the Avenger first.");
		FileFingerprint = "";
		return;
	}
	if (!ReadNumbers(History, FileSoldiers, FileSupplies, FileMaxId))
	{
		Say("CoopHistoryFromFile: the file has no XCOM HQ. Write it on the Avenger, not in a mission.");
		FileFingerprint = "";
		return;
	}

	FileFingerprint = class'XComCoop_Util'.static.HistoryFingerprint(History);
	bStarted = false;
	bSawLoadedToStrategyHook = false;
	Say("CoopHistoryFromFile: read. fingerprint " $ FileFingerprint);
	Say("CoopHistoryFromFile: compare it with the one CoopHistoryToFile printed, then run CoopStartStrategy.");
}

/// Mode "plain" opens the Avenger without pretending to load a save.
function StartStrategy(string Mode)
{
	local PlayerController PC;
	local string Command;

	if (!class'XComCoop_Util'.static.IsInShell())
	{
		Say("CoopStartStrategy: run this in the main menu");
		return;
	}
	if (FileFingerprint == "")
	{
		Say("CoopStartStrategy: run CoopHistoryFromFile first");
		return;
	}
	PC = class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController();
	if (PC == none)
	{
		Say("CoopStartStrategy: no player controller");
		return;
	}

	bAsLoadedSave = !(Mode ~= "plain");
	bStarted = true;
	bSawLoadedToStrategyHook = false;

	Command = STRATEGY_MAP_COMMAND;
	if (bAsLoadedSave)
	{
		// The same two things a normal load does: the flag makes StartMatch take the
		// loaded-save path, the URL option matches the map command of a real load.
		`ONLINEEVENTMGR.bPerformingStandardLoad = true;
		Command $= LOADING_SAVE_OPTION;
	}
	Say("CoopStartStrategy: " $ (bAsLoadedSave ? "as a loaded save" : "plain") $ ": " $ Command);
	Say("CoopStartStrategy: on the Avenger, run CoopStrategyCheck");
	PC.ConsoleCommand(Command);
}

function Check()
{
	local XComHeadquartersGame HQGame;
	local XGStrategy GameCore;
	local int Soldiers, Supplies, MaxId;

	HQGame = XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game);
	if (HQGame == none)
	{
		Say("CoopStrategyCheck: not on the Avenger");
		return;
	}
	if (!bStarted)
	{
		Say("CoopStrategyCheck: this game was not started with CoopStartStrategy (normal save?). Checking anyway.");
	}
	else
	{
		Say("CoopStrategyCheck: started " $ (bAsLoadedSave ? "as a loaded save" : "plain"));
	}

	GameCore = HQGame.GetGameCore();
	if (GameCore == none)
	{
		Say("CoopStrategyCheck: no strategy game core (XGStrategy) yet");
	}
	else
	{
		Say("CoopStrategyCheck: game core state=" $ GameCore.GetStateName() $ " loadedFromSave=" $ GameCore.m_bLoadedFromSave
			$ " standardLoadFlag=" $ `ONLINEEVENTMGR.bPerformingStandardLoad);
	}
	Say("CoopStrategyCheck: OnLoadedSavedGameToStrategy hook " $ (bSawLoadedToStrategyHook ? "ran" : "did not run"));

	if (FileFingerprint != "")
	{
		Say("  from file: " $ FileFingerprint);
	}
	Say("  now:       " $ class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY));

	if (FileFingerprint != "" && ReadNumbers(`XCOMHISTORY, Soldiers, Supplies, MaxId))
	{
		Say("CoopStrategyCheck: soldiers " $ Verdict(Soldiers == FileSoldiers) $ " (" $ FileSoldiers $ " -> " $ Soldiers $ ")"
			$ ", supplies " $ Verdict(Supplies == FileSupplies) $ " (" $ FileSupplies $ " -> " $ Supplies $ ")"
			$ ", maxid " $ Verdict(MaxId >= FileMaxId) $ " (" $ FileMaxId $ " -> " $ MaxId $ ")");
	}
	Say("CoopStrategyCheck: now look around (Armory, Research, Geoscape scan), then save and load that save.");
}

function OnLoadedToStrategy()
{
	// Only the first load after CoopStartStrategy; later loads are normal saves.
	if (bStarted && !bSawLoadedToStrategyHook)
	{
		bSawLoadedToStrategyHook = true;
		Say("CoopStartStrategy: the game ran OnLoadedSavedGameToStrategy (loaded-save path)");
	}
}

static function bool ReadNumbers(XComGameStateHistory History, out int Soldiers, out int Supplies, out int MaxId)
{
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_BaseObject Obj;
	local bool bFound;

	MaxId = 0;
	foreach History.IterateByClassType(class'XComGameState_BaseObject', Obj,, true)
	{
		MaxId = Max(MaxId, Obj.ObjectID);
	}
	foreach History.IterateByClassType(class'XComGameState_HeadquartersXCom', XComHQ)
	{
		Soldiers = XComHQ.GetNumberOfSoldiers();
		Supplies = XComHQ.GetSupplies();
		bFound = true;
		break;
	}
	return bFound;
}

static function string Verdict(bool bOk)
{
	return bOk ? "MATCH" : "DIFFER";
}

static function Say(string Msg)
{
	class'XComCoop_Util'.static.Say(Msg);
}
