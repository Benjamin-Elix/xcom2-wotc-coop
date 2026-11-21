//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_UISquadSelectListener.uc
//  PURPOSE: Phase 2: the client only watches the host's campaign. Launching a mission
//           would load a new map on the client and leave the mirrored campaign, and that
//           cannot be undone like other changes. So the client cannot open squad select.
//           Missions come in phase 4 (alone) and phase 5 (together).
//
//           Keeps no reference to the screen (the listener lives for the whole game).
//---------------------------------------------------------------------------------------
class XComCoop_UISquadSelectListener extends UIScreenListener dependson(XComCoop_Session);

var localized string strTitle;
var localized string strText;

event OnInit(UIScreen Screen)
{
	local XComCoop_Session Session;

	Session = class'XComCoop_Session'.static.Get();
	if (Session.bIsHost || Session.SessionState != eCoopState_InCampaign)
	{
		return;
	}
	Screen.CloseScreen();
	Session.ShowMessage(strTitle, Repl(strText, "%PLAYER", Session.OtherName()));
}

defaultproperties
{
	ScreenClass = class'UISquadSelect';
}
