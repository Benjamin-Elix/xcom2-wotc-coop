//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_ChangeWatch.uc
//  PURPOSE: Phase 2 mapping on one PC: logs every new game state while you play, to see
//           how often the host's campaign changes and what kind of changes they are.
//           That decides how often the host must send and what the client will create
//           by itself.
//
//           CoopWatchStart -> play on the Avenger -> CoopWatchReport -> CoopWatchStop
//
//           Uses XComGameStateHistory.RegisterOnNewGameStateDelegate. The history drops
//           its delegates on map changes, so run CoopWatchStart again after a load.
//           State is kept on the class default object. Remove once phase 2 is designed.
//---------------------------------------------------------------------------------------
class XComCoop_ChangeWatch extends Object;

// How many kinds and example lines are kept and printed (test output, not gameplay).
const MAX_KINDS = 200;
const MAX_LINES = 40;
const REPORT_KINDS = 20;
const REPORT_LINES = 15;

struct CoopChangeKind
{
	var string Summary;
	var int Count;
	var int Objects;
};

var bool bWatching;
var int StartSeconds;           // seconds since midnight, survives map changes
var string StartMap;
var int StartIndex;
var int NumStates;
var int NumObjects;
var int MaxObjects;
var array<CoopChangeKind> Kinds;
var array<string> Lines;

static function XComCoop_ChangeWatch Get()
{
	return XComCoop_ChangeWatch(class'XComEngine'.static.GetClassDefaultObject(class'XComCoop_ChangeWatch'));
}

function Start()
{
	local XComGameStateHistory History;

	History = `XCOMHISTORY;
	History.UnRegisterOnNewGameStateDelegate(OnNewGameState);
	History.RegisterOnNewGameStateDelegate(OnNewGameState);

	bWatching = true;
	StartSeconds = SecondsOfDay();
	StartMap = class'WorldInfo'.static.GetWorldInfo().GetMapName();
	StartIndex = History.GetCurrentHistoryIndex();
	NumStates = 0;
	NumObjects = 0;
	MaxObjects = 0;
	Kinds.Length = 0;
	Lines.Length = 0;
	Say("CoopWatchStart: watching from history index " $ StartIndex $ " on " $ StartMap
		$ ". Play normally, then run CoopWatchReport.");
}

function Stop()
{
	`XCOMHISTORY.UnRegisterOnNewGameStateDelegate(OnNewGameState);
	bWatching = false;
	Say("CoopWatchStop: stopped after " $ NumStates $ " new game states");
}

function OnNewGameState(XComGameState NewGameState)
{
	local XComGameStateContext Context;
	local string Summary;
	local int Objects, i;

	if (!bWatching || NewGameState == none)
	{
		return;
	}
	Context = NewGameState.GetContext();
	Summary = Context != none ? Context.SummaryString() : "(no context)";
	Objects = NewGameState.GetNumGameStateObjects();

	NumStates++;
	NumObjects += Objects;
	MaxObjects = Max(MaxObjects, Objects);

	for (i = 0; i < Kinds.Length; i++)
	{
		if (Kinds[i].Summary == Summary)
		{
			break;
		}
	}
	if (i == Kinds.Length && Kinds.Length < MAX_KINDS)
	{
		Kinds.Add(1);
		Kinds[i].Summary = Summary;
	}
	if (i < Kinds.Length)
	{
		Kinds[i].Count++;
		Kinds[i].Objects += Objects;
	}

	if (Lines.Length < MAX_LINES)
	{
		Lines.AddItem("+" $ (SecondsOfDay() - StartSeconds) $ "s  " $ Objects $ " obj  " $ Summary);
	}
	`log("CoopWatch: " $ Objects $ " obj  " $ Summary,, 'XComCoop');
}

function Report()
{
	local int Seconds, i, Best, Shown;
	local array<CoopChangeKind> Sorted;
	local CoopChangeKind Kind;

	if (!bWatching && NumStates == 0)
	{
		Say("CoopWatchReport: nothing recorded. Run CoopWatchStart first.");
		return;
	}
	Seconds = Max(1, SecondsOfDay() - StartSeconds);
	Say("CoopWatchReport: " $ NumStates $ " new game states in " $ Seconds $ " s ("
		$ class'XComCoop_Util'.static.FormatSeconds(NumStates * 60.0 / Seconds) $ " per minute), "
		$ NumObjects $ " changed objects in total, at most " $ MaxObjects $ " in one state");
	if (class'WorldInfo'.static.GetWorldInfo().GetMapName() != StartMap)
	{
		Say("CoopWatchReport: the map changed since CoopWatchStart, so states after the load are missing. Run CoopWatchStart again.");
	}

	// Most frequent kinds first (simple selection; the list is short).
	Sorted = Kinds;
	for (Shown = 0; Shown < REPORT_KINDS && Sorted.Length > 0; Shown++)
	{
		Best = 0;
		for (i = 1; i < Sorted.Length; i++)
		{
			if (Sorted[i].Count > Sorted[Best].Count)
			{
				Best = i;
			}
		}
		Kind = Sorted[Best];
		Say("  " $ Kind.Count $ "x  " $ Kind.Objects $ " obj  " $ Kind.Summary);
		Sorted.Remove(Best, 1);
	}
	if (Sorted.Length > 0)
	{
		Say("  ... and " $ Sorted.Length $ " more kinds (all of them are in Launch.log as CoopWatch lines)");
	}

	Say("CoopWatchReport: the first states in order:");
	for (i = 0; i < Min(REPORT_LINES, Lines.Length); i++)
	{
		Say("  " $ Lines[i]);
	}
}

function int SecondsOfDay()
{
	local int Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec;

	GetSystemTime(Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec);
	return Hour * 3600 + Min * 60 + Sec;
}

static function Say(string Msg)
{
	class'XComCoop_Util'.static.Say(Msg);
}
