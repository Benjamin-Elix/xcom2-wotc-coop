//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_RollbackTest.uc
//  PURPOSE: Phase 2 test 5 on one PC: can the client throw away its own small changes?
//           The client creates game states just by looking around (entering rooms, popups
//           seen, narrative moments). Before applying the host's changes it must remove
//           them again with XComGameStateHistory.ObliterateGameStatesFromHistory, which the
//           game itself uses for undo (XComCharacterCustomization, XComOnlineEventMgr).
//
//           1. On the Avenger:                 CoopRollbackMark
//           2. Click around, start research, let time pass on the Geoscape
//           3. Back on the Avenger:            CoopRollbackInfo, then CoopRollback
//           4. Check that the game still works, save and load
//
//           State is kept on the class default object. Remove once phase 2 is built.
//---------------------------------------------------------------------------------------
class XComCoop_RollbackTest extends Object;

var bool bMarked;
var int MarkIndex;
var string MarkMap;
var string MarkFingerprint;

static function XComCoop_RollbackTest Get()
{
	return XComCoop_RollbackTest(class'XComEngine'.static.GetClassDefaultObject(class'XComCoop_RollbackTest'));
}

function Mark()
{
	if (!class'XComCoop_Util'.static.IsInStrategy())
	{
		Say("CoopRollbackMark: load a campaign and stand on the Avenger first");
		return;
	}
	MarkIndex = `XCOMHISTORY.GetCurrentHistoryIndex();
	MarkMap = class'WorldInfo'.static.GetWorldInfo().GetMapName();
	MarkFingerprint = class'XComCoop_Util'.static.HistoryFingerprint(`XCOMHISTORY);
	bMarked = true;
	Say("CoopRollbackMark: marked history index " $ MarkIndex $ ". fingerprint " $ MarkFingerprint);
	Say("CoopRollbackMark: now click around, start research, let time pass. Then CoopRollbackInfo and CoopRollback on the Avenger.");
}

function Info()
{
	local XComGameStateHistory History;
	local XComGameStateContext Context;
	local int i;

	if (!CheckMark("CoopRollbackInfo"))
	{
		return;
	}
	History = `XCOMHISTORY;
	Say("CoopRollbackInfo: " $ (History.GetCurrentHistoryIndex() - MarkIndex) $ " new game states since the mark:");
	for (i = MarkIndex + 1; i <= History.GetCurrentHistoryIndex(); i++)
	{
		Context = History.GetGameStateFromHistory(i).GetContext();
		Say("  " $ i $ "  " $ (Context != none ? Context.SummaryString() : "(no context)"));
	}
}

function Rollback()
{
	local XComGameStateHistory History;
	local XComGameState_GameTime TimeState;
	local XComHQPresentationLayer HQPres;
	local string Now;
	local int Count;

	if (!CheckMark("CoopRollback"))
	{
		return;
	}
	History = `XCOMHISTORY;
	Count = History.GetCurrentHistoryIndex() - MarkIndex;
	if (Count <= 0)
	{
		Say("CoopRollback: nothing to roll back");
		return;
	}

	Say("CoopRollback: removing " $ Count $ " game states...");
	History.ObliterateGameStatesFromHistory(Count);

	// The strategy ruleset keeps its own copy of the clock; take it from the history again.
	foreach History.IterateByClassType(class'XComGameState_GameTime', TimeState)
	{
		`STRATEGYRULES.GameTime = TimeState.CurrentTime;
		break;
	}
	HQPres = XComHQPresentationLayer(class'XComCoop_Util'.static.GetPres());
	if (HQPres != none && HQPres.m_kAvengerHUD != none)
	{
		HQPres.m_kAvengerHUD.UpdateResources();
	}

	Now = class'XComCoop_Util'.static.HistoryFingerprint(History);
	Say("CoopRollback: done. history index " $ History.GetCurrentHistoryIndex() $ " (mark " $ MarkIndex $ ")");
	Say("  at mark: " $ MarkFingerprint);
	Say("  now:     " $ Now);
	Say("CoopRollback: fingerprints " $ (Now == MarkFingerprint ? "MATCH" : "DIFFER " $ class'XComCoop_Util'.static.DescribeDifference(MarkFingerprint, Now)));
	Say("CoopRollback: check the research and supplies, open a few screens, let time pass, then save and load.");
}

function bool CheckMark(string Command)
{
	if (!bMarked)
	{
		Say(Command $ ": run CoopRollbackMark first");
		return false;
	}
	if (class'WorldInfo'.static.GetWorldInfo().GetMapName() != MarkMap || `XCOMHISTORY.GetCurrentHistoryIndex() < MarkIndex)
	{
		Say(Command $ ": the map or campaign changed since the mark (a save was loaded?). Run CoopRollbackMark again.");
		return false;
	}
	return true;
}

static function Say(string Msg)
{
	class'XComCoop_Util'.static.Say(Msg);
}
