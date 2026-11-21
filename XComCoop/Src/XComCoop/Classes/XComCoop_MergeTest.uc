//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_MergeTest.uc
//  PURPOSE: Phase 0 test 3 on one PC: play a mission on one copy of the campaign, then
//           merge the result into another copy where other things happened meanwhile.
//
//           1. Load save A on the Avenger:          CoopMissionBegin
//           2. Play a mission, back on the Avenger: CoopMissionSummary
//           3. Load save A again, build or buy something on the Avenger
//           4. Merge the mission result:             CoopMissionApply
//
//           The snapshot and the summary are kept on the class default object, which
//           survives loading saves. Remove this class once phase 0 is done.
//---------------------------------------------------------------------------------------
class XComCoop_MergeTest extends Object dependson(XComCoop_MissionResult);

var CoopMissionSnapshot Before;
var CoopMissionSnapshot Summary;
var bool bApplied;

static function XComCoop_MergeTest Get()
{
	return XComCoop_MergeTest(class'XComEngine'.static.GetClassDefaultObject(class'XComCoop_MergeTest'));
}

function Begin()
{
	local CoopMissionSnapshot Empty;

	Before = class'XComCoop_MissionResult'.static.Capture();
	Summary = Empty;
	bApplied = false;
	if (!Before.bValid)
	{
		Say("CoopMissionBegin: load a campaign first (no XCOM HQ found)");
		return;
	}
	Say("CoopMissionBegin: snapshot taken. soldiers=" $ Before.Soldiers.Length $ " item types=" $ Before.Items.Length
		$ " objects=" $ Before.NumObjects $ " maxid=" $ Before.MaxObjectID);
	Say("CoopMissionBegin: now play a mission. Back on the Avenger, run CoopMissionSummary before promoting anyone.");
}

function MakeSummary()
{
	local CoopMissionSnapshot After;
	local array<string> Report;
	local int i;

	if (!Before.bValid)
	{
		Say("CoopMissionSummary: run CoopMissionBegin before the mission first");
		return;
	}
	After = class'XComCoop_MissionResult'.static.Capture();
	if (!After.bValid)
	{
		Say("CoopMissionSummary: not in a campaign");
		return;
	}
	Summary = class'XComCoop_MissionResult'.static.Diff(Before, After);
	bApplied = false;

	Say("CoopMissionSummary: " $ Summary.Soldiers.Length $ " soldiers and " $ Summary.Items.Length $ " item types changed. objects "
		$ class'XComCoop_MissionResult'.static.Signed(Summary.NumObjects) $ ", maxid " $ Before.MaxObjectID $ " -> " $ After.MaxObjectID);
	ShowSummary();

	class'XComCoop_MissionResult'.static.ReportNewObjects(Before, Report);
	for (i = 0; i < Report.Length; i++)
	{
		Say("  " $ Report[i]);
	}
	Say("CoopMissionSummary: now load the save from before the mission, change something on the Avenger, then run CoopMissionApply.");
}

function ShowSummary()
{
	local int i;

	if (!Summary.bValid)
	{
		Say("CoopMissionShow: no summary yet");
		return;
	}
	for (i = 0; i < Summary.Soldiers.Length; i++)
	{
		Say("  soldier " $ Summary.Soldiers[i].FullName $ ": " $ class'XComCoop_MissionResult'.static.DescribeSoldier(Summary.Soldiers[i]));
	}
	for (i = 0; i < Summary.Items.Length; i++)
	{
		Say("  item " $ Summary.Items[i].TemplateName $ " " $ class'XComCoop_MissionResult'.static.Signed(Summary.Items[i].Quantity));
	}
}

function Apply()
{
	local array<string> Report;
	local int i;

	if (!Summary.bValid)
	{
		Say("CoopMissionApply: no summary. Run CoopMissionBegin and CoopMissionSummary first.");
		return;
	}
	if (bApplied)
	{
		Say("CoopMissionApply: already applied once. Load the save again to apply it again.");
		return;
	}
	if (class'XComCoop_MissionResult'.static.Apply(Summary, Report))
	{
		bApplied = true;
	}
	for (i = 0; i < Report.Length; i++)
	{
		Say("CoopMissionApply: " $ Report[i]);
	}
	Say("CoopMissionApply: done. Check the Armory and Engineering > Inventory, and that your own Avenger changes are still there.");
}

static function Say(string Msg)
{
	class'XComCoop_Util'.static.Say(Msg);
}
