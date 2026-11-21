//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_MissionResult.uc
//  PURPOSE: The mission result summary from DESIGN.md section 4 ("results merged
//           additively"), first version for phase 0 test 3.
//
//           The player who runs a mission plays on a copy of the campaign. Afterwards only
//           a summary goes back to the host, never game state objects: object IDs created
//           on the mission side would collide with the host's (see KARTLEGGING-NETTVERK.md).
//
//           Capture() takes a snapshot, Diff() turns two snapshots into a summary of what
//           changed, and Apply() adds that summary on top of the host's current campaign,
//           whatever the host did in the meantime.
//
//           Covered so far: soldier kills, kill assists, XP and ability points, and the
//           HQ inventory (loot and resources such as supplies and intel). Ranks, wounds,
//           deaths, captures and new personnel are only reported, not merged yet.
//           Everything is plain structs, so a summary can be kept across save loads.
//---------------------------------------------------------------------------------------
class XComCoop_MissionResult extends Object;

struct CoopSoldierProgress
{
	var int ObjectID;
	var string FullName;
	var int Rank;
	var int Xp;
	var float KillCount;
	var float KillAssistsCount;
	var float BonusKills;
	var int WetWorkKills;
	var int NonTacticalKills;
	var int NumKills;           // KilledUnits.Length, what the UI shows as kills
	var int AbilityPoints;
	var bool bDead;
	var bool bCaptured;
};

struct CoopItemCount
{
	var name TemplateName;
	var int Quantity;
};

struct CoopMissionSnapshot
{
	var bool bValid;
	var array<CoopSoldierProgress> Soldiers;
	var array<CoopItemCount> Items;
	var array<int> ObjectIDs;       // every state object, to see what a mission creates
	var int NumObjects;
	var int MaxObjectID;
};

// --- Snapshot --------------------------------------------------------------------------------

static function CoopMissionSnapshot Capture()
{
	local CoopMissionSnapshot Snapshot;
	local XComGameStateHistory History;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_BaseObject Obj;
	local int i;

	History = `XCOMHISTORY;
	XComHQ = XComGameState_HeadquartersXCom(History.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom', true));
	if (XComHQ == none)
	{
		return Snapshot;
	}

	for (i = 0; i < XComHQ.Crew.Length; i++)
	{
		AddSoldier(Snapshot, XComHQ.Crew[i].ObjectID);
	}
	for (i = 0; i < XComHQ.DeadCrew.Length; i++)
	{
		AddSoldier(Snapshot, XComHQ.DeadCrew[i].ObjectID);
	}

	for (i = 0; i < XComHQ.Inventory.Length; i++)
	{
		AddItem(Snapshot, XComHQ.Inventory[i].ObjectID);
	}

	foreach History.IterateByClassType(class'XComGameState_BaseObject', Obj,, true)
	{
		Snapshot.ObjectIDs.AddItem(Obj.ObjectID);
		Snapshot.MaxObjectID = Max(Snapshot.MaxObjectID, Obj.ObjectID);
	}
	Snapshot.NumObjects = Snapshot.ObjectIDs.Length;
	Snapshot.bValid = true;
	return Snapshot;
}

static function AddSoldier(out CoopMissionSnapshot Snapshot, int ObjectID)
{
	local XComGameState_Unit Unit;
	local CoopSoldierProgress Progress;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(ObjectID));
	if (Unit == none || !Unit.IsSoldier() || FindSoldier(Snapshot, ObjectID) != INDEX_NONE)
	{
		return;
	}
	Progress.ObjectID = ObjectID;
	Progress.FullName = Unit.GetFullName();
	Progress.Rank = Unit.GetRank();
	Progress.Xp = Unit.GetXPValue();
	Progress.KillCount = Unit.KillCount;
	Progress.KillAssistsCount = Unit.KillAssistsCount;
	Progress.BonusKills = Unit.BonusKills;
	Progress.WetWorkKills = Unit.WetWorkKills;
	Progress.NonTacticalKills = Unit.NonTacticalKills;
	Progress.NumKills = Unit.GetNumKills();
	Progress.AbilityPoints = Unit.AbilityPoints;
	Progress.bDead = Unit.IsDead();
	Progress.bCaptured = Unit.bCaptured;
	Snapshot.Soldiers.AddItem(Progress);
}

static function AddItem(out CoopMissionSnapshot Snapshot, int ObjectID)
{
	local XComGameState_Item Item;
	local CoopItemCount Count;
	local int Index;

	Item = XComGameState_Item(`XCOMHISTORY.GetGameStateForObjectID(ObjectID));
	if (Item == none || Item.GetMyTemplate() == none)
	{
		return;
	}
	Index = FindItem(Snapshot.Items, Item.GetMyTemplateName());
	if (Index == INDEX_NONE)
	{
		Count.TemplateName = Item.GetMyTemplateName();
		Count.Quantity = Item.Quantity;
		Snapshot.Items.AddItem(Count);
	}
	else
	{
		Snapshot.Items[Index].Quantity += Item.Quantity;
	}
}

// --- Summary ---------------------------------------------------------------------------------

/// What changed from Before to After. Soldiers and items with no change are left out.
/// The result is a snapshot of differences: every number is "after minus before".
static function CoopMissionSnapshot Diff(const out CoopMissionSnapshot Before, const out CoopMissionSnapshot After)
{
	local CoopMissionSnapshot Delta;
	local CoopSoldierProgress D;
	local CoopItemCount Count;
	local int i, j, BeforeQuantity;

	for (i = 0; i < After.Soldiers.Length; i++)
	{
		j = FindSoldier(Before, After.Soldiers[i].ObjectID);
		if (j == INDEX_NONE)
		{
			// New soldier (a reward): reported by ReportNewObjects, not merged yet.
			continue;
		}
		D = After.Soldiers[i];
		D.Rank -= Before.Soldiers[j].Rank;
		D.Xp -= Before.Soldiers[j].Xp;
		D.KillCount -= Before.Soldiers[j].KillCount;
		D.KillAssistsCount -= Before.Soldiers[j].KillAssistsCount;
		D.BonusKills -= Before.Soldiers[j].BonusKills;
		D.WetWorkKills -= Before.Soldiers[j].WetWorkKills;
		D.NonTacticalKills -= Before.Soldiers[j].NonTacticalKills;
		D.NumKills -= Before.Soldiers[j].NumKills;
		D.AbilityPoints -= Before.Soldiers[j].AbilityPoints;
		// Flags: set when they became true during the mission.
		D.bDead = After.Soldiers[i].bDead && !Before.Soldiers[j].bDead;
		D.bCaptured = After.Soldiers[i].bCaptured && !Before.Soldiers[j].bCaptured;
		if (HasProgress(D))
		{
			Delta.Soldiers.AddItem(D);
		}
	}

	for (i = 0; i < After.Items.Length; i++)
	{
		j = FindItem(Before.Items, After.Items[i].TemplateName);
		BeforeQuantity = j != INDEX_NONE ? Before.Items[j].Quantity : 0;
		if (After.Items[i].Quantity != BeforeQuantity)
		{
			Count.TemplateName = After.Items[i].TemplateName;
			Count.Quantity = After.Items[i].Quantity - BeforeQuantity;
			Delta.Items.AddItem(Count);
		}
	}
	for (i = 0; i < Before.Items.Length; i++)
	{
		if (FindItem(After.Items, Before.Items[i].TemplateName) == INDEX_NONE)
		{
			Count.TemplateName = Before.Items[i].TemplateName;
			Count.Quantity = -Before.Items[i].Quantity;
			Delta.Items.AddItem(Count);
		}
	}

	Delta.NumObjects = After.NumObjects - Before.NumObjects;
	Delta.MaxObjectID = After.MaxObjectID;
	Delta.bValid = true;
	return Delta;
}

static function bool HasProgress(const out CoopSoldierProgress D)
{
	return D.Rank != 0 || D.Xp != 0 || D.KillCount != 0 || D.KillAssistsCount != 0 || D.BonusKills != 0
		|| D.WetWorkKills != 0 || D.NonTacticalKills != 0 || D.NumKills != 0 || D.AbilityPoints != 0
		|| D.bDead || D.bCaptured;
}

// --- Merge -----------------------------------------------------------------------------------

/// Adds a summary from Diff() on top of the current campaign as one new game state.
/// Lines describing what was done and what was skipped are added to Report.
static function bool Apply(const out CoopMissionSnapshot Delta, out array<string> Report)
{
	local XComGameStateHistory History;
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_Unit Unit;
	local XComGameState_Item NewItem;
	local X2ItemTemplate ItemTemplate;
	local CoopSoldierProgress D;
	local CoopItemCount Count;
	local int n;

	History = `XCOMHISTORY;
	XComHQ = XComGameState_HeadquartersXCom(History.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom', true));
	if (!Delta.bValid || XComHQ == none)
	{
		Report.AddItem("nothing to apply (no summary, or not in a campaign)");
		return false;
	}

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("XComCoop: merge mission result");

	foreach Delta.Soldiers(D)
	{
		Unit = XComGameState_Unit(History.GetGameStateForObjectID(D.ObjectID));
		if (Unit == none)
		{
			Report.AddItem("skipped " $ D.FullName $ ": not in this campaign (object " $ D.ObjectID $ ")");
			continue;
		}
		if (Unit.IsDead())
		{
			Report.AddItem("skipped " $ D.FullName $ ": already dead here");
			continue;
		}

		Unit = XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', D.ObjectID));
		Unit.KillCount += D.KillCount;
		Unit.KillAssistsCount += D.KillAssistsCount;
		Unit.BonusKills += D.BonusKills;
		Unit.WetWorkKills += D.WetWorkKills;
		Unit.NonTacticalKills += D.NonTacticalKills;
		Unit.AbilityPoints += D.AbilityPoints;
		if (D.Xp != 0)
		{
			Unit.AddXp(D.Xp);
		}
		Report.AddItem("merged " $ D.FullName $ ": " $ DescribeSoldier(D) $ (Unit.CanRankUpSoldier() ? ", promotion now available" : ""));

		if (D.Rank != 0)
		{
			Report.AddItem("  not merged yet: rank " $ Signed(D.Rank) $ " (promote in the Armory)");
		}
		if (D.NumKills != 0)
		{
			Report.AddItem("  not merged yet: kill list " $ Signed(D.NumKills) $ " (counts toward rank, but the kill number shown in the UI stays)");
		}
		if (D.bDead || D.bCaptured)
		{
			Report.AddItem("  not merged yet: " $ (D.bDead ? "died" : "captured") $ " on the mission");
		}
	}

	XComHQ = XComGameState_HeadquartersXCom(NewGameState.ModifyStateObject(class'XComGameState_HeadquartersXCom', XComHQ.ObjectID));
	foreach Delta.Items(Count)
	{
		if (Count.Quantity < 0)
		{
			Report.AddItem("not merged: " $ Count.TemplateName $ " " $ Signed(Count.Quantity) $ " (used or spent on the mission side)");
			continue;
		}
		ItemTemplate = class'X2ItemTemplateManager'.static.GetItemTemplateManager().FindItemTemplate(Count.TemplateName);
		if (ItemTemplate == none)
		{
			Report.AddItem("skipped " $ Count.TemplateName $ ": unknown item");
			continue;
		}
		if (ItemTemplate.bAlwaysUnique)
		{
			// Each one is its own item (e.g. PCS).
			for (n = 0; n < Count.Quantity; n++)
			{
				NewItem = ItemTemplate.CreateInstanceFromTemplate(NewGameState);
				XComHQ.PutItemInInventory(NewGameState, NewItem);
			}
		}
		else
		{
			NewItem = ItemTemplate.CreateInstanceFromTemplate(NewGameState);
			NewItem.Quantity = Count.Quantity;
			XComHQ.PutItemInInventory(NewGameState, NewItem);
		}
		Report.AddItem("merged " $ Count.TemplateName $ " " $ Signed(Count.Quantity));
	}

	`GAMERULES.SubmitGameState(NewGameState);
	return true;
}

// --- Text ------------------------------------------------------------------------------------

static function string DescribeSoldier(CoopSoldierProgress D)
{
	local string Text;

	Text = "kills " $ Signed(int(D.KillCount)) $ ", assists " $ Signed(int(D.KillAssistsCount)) $ ", xp " $ Signed(D.Xp) $ ", ability points " $ Signed(D.AbilityPoints);
	if (D.BonusKills != 0 || D.WetWorkKills != 0 || D.NonTacticalKills != 0)
	{
		Text $= ", other kills " $ Signed(int(D.BonusKills) + D.WetWorkKills + D.NonTacticalKills);
	}
	if (D.Rank != 0)
	{
		Text $= ", rank " $ Signed(D.Rank);
	}
	if (D.bDead)
	{
		Text $= ", DIED";
	}
	if (D.bCaptured)
	{
		Text $= ", CAPTURED";
	}
	return Text;
}

/// Counts the state objects that exist now but not in Before, by class. These are what a
/// mission creates; none of them may be copied to the host as they are.
static function ReportNewObjects(const out CoopMissionSnapshot Before, out array<string> Report)
{
	local XComGameState_BaseObject Obj;
	local array<name> ClassNames;
	local array<int> Counts;
	local int i, Total;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_BaseObject', Obj,, true)
	{
		if (Before.ObjectIDs.Find(Obj.ObjectID) != INDEX_NONE)
		{
			continue;
		}
		Total++;
		i = ClassNames.Find(Obj.Class.Name);
		if (i == INDEX_NONE)
		{
			ClassNames.AddItem(Obj.Class.Name);
			Counts.AddItem(1);
		}
		else
		{
			Counts[i]++;
		}
	}

	Report.AddItem("new state objects since the snapshot: " $ Total);
	for (i = 0; i < ClassNames.Length; i++)
	{
		Report.AddItem("  " $ ClassNames[i] $ ": " $ Counts[i]);
	}
}

static function string Signed(int Value)
{
	return Value > 0 ? "+" $ Value : string(Value);
}

// --- Lookups ---------------------------------------------------------------------------------

static function int FindSoldier(const out CoopMissionSnapshot Snapshot, int ObjectID)
{
	local int i;

	for (i = 0; i < Snapshot.Soldiers.Length; i++)
	{
		if (Snapshot.Soldiers[i].ObjectID == ObjectID)
		{
			return i;
		}
	}
	return INDEX_NONE;
}

static function int FindItem(const out array<CoopItemCount> Items, name TemplateName)
{
	local int i;

	for (i = 0; i < Items.Length; i++)
	{
		if (Items[i].TemplateName == TemplateName)
		{
			return i;
		}
	}
	return INDEX_NONE;
}
