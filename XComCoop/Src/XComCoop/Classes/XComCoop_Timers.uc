//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_Timers.uc
//  PURPOSE: Runs the timers of objects that are not actors (XComCoop_Session and the test
//           classes, which keep their state in their class default objects).
//
//           Timers set on WorldInfo never fire in XCOM 2: WorldInfo has bTickIsDisabled=true
//           (Engine\Classes\WorldInfo.uc, defaultproperties), and an actor that does not
//           tick does not run its timers. This actor ticks like any other. One is spawned in
//           the current map the first time a timer is needed, so its timers end when the map
//           is unloaded, the same as timers on any other actor of that map.
//
//           Timers point from this actor to the durable object, never the other way: nothing
//           that lives for the whole game may keep a reference to an actor (the old map could
//           then not be garbage collected, and loading a save crashes). So the actor is looked
//           up again on every call.
//
//           Locals are named TimerActor, not Timers: Actor already has a field called Timers.
//---------------------------------------------------------------------------------------
class XComCoop_Timers extends Info;

/// Calls Target.FuncName after Rate seconds, and then every Rate seconds if bLoop.
/// Starts the timer over if it already runs. Same as Actor.SetTimer.
static function Schedule(float Rate, bool bLoop, name FuncName, Object Target)
{
	local XComCoop_Timers TimerActor;

	TimerActor = Find(true);
	if (TimerActor == none)
	{
		`log("XComCoop_Timers: no map to run " $ FuncName $ " in",, 'XComCoop');
		return;
	}
	TimerActor.SetTimer(Rate, bLoop, FuncName, Target);
}

/// Stops a timer started with Schedule. Same as Actor.ClearTimer.
static function Cancel(name FuncName, Object Target)
{
	local XComCoop_Timers TimerActor;

	TimerActor = Find(false);
	if (TimerActor != none)
	{
		TimerActor.ClearTimer(FuncName, Target);
	}
}

/// Whether a timer started with Schedule is still running. Same as Actor.IsTimerActive.
static function bool IsScheduled(name FuncName, Object Target)
{
	local XComCoop_Timers TimerActor;

	TimerActor = Find(false);
	return TimerActor != none && TimerActor.IsTimerActive(FuncName, Target);
}

/// The timer actor of the current map. With bCreate it is spawned if there is none yet.
static function XComCoop_Timers Find(bool bCreate)
{
	local WorldInfo WI;
	local XComCoop_Timers TimerActor;

	WI = class'WorldInfo'.static.GetWorldInfo();
	if (WI == none)
	{
		return none;
	}
	foreach WI.DynamicActors(class'XComCoop_Timers', TimerActor)
	{
		return TimerActor;
	}
	if (!bCreate)
	{
		return none;
	}
	return WI.Spawn(class'XComCoop_Timers');
}

defaultproperties
{
}
