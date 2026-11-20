//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_UIShellListener.uc
//  PURPOSE: Adds a CO-OP button to the main menu (after MULTIPLAYER) and starts listening
//           for co-op invites as soon as the main menu is up.
//
//           UIFinalShell rebuilds its menu now and then (UpdateMenu, e.g. after reading
//           saves or a login change), which removes our button. A short repeating timer
//           puts it back. No class override, so other mods can change the menu as well.
//---------------------------------------------------------------------------------------
class XComCoop_UIShellListener extends UIScreenListener;

const BUTTON_NAME = 'XComCoopButton';

var UIFinalShell Shell;

var localized string strCoopButton;

event OnInit(UIScreen Screen)
{
	Shell = UIFinalShell(Screen);
	if (Shell == none)
	{
		return;
	}

	class'XComCoop_Session'.static.Get().Init();

	EnsureButton();
	Shell.SetTimer(class'XComCoop_Config'.default.MainMenuButtonCheckSeconds, true, nameof(EnsureButton), self);
}

event OnRemoved(UIScreen Screen)
{
	if (Screen == Shell)
	{
		Shell.ClearTimer(nameof(EnsureButton), self);
		Shell = none;
	}
}

function EnsureButton()
{
	local UIButton Button;
	local int i, MPIndex;

	if (Shell == none || Shell.MainMenuContainer == none)
	{
		return;
	}
	for (i = 0; i < Shell.MainMenu.Length; i++)
	{
		if (Shell.MainMenu[i].MCName == BUTTON_NAME)
		{
			return;
		}
	}

	Shell.CreateItem(BUTTON_NAME, strCoopButton);
	Button = Shell.MainMenu[Shell.MainMenu.Length - 1];
	Button.OnClickedDelegate = OnCoopClicked;
	Button.ProcessMouseEvents(Shell.OnChildMouseEvent);

	// Move it right after MULTIPLAYER. The shell lays the buttons out in array order once
	// the new button knows its size.
	MPIndex = INDEX_NONE;
	for (i = 0; i < Shell.MainMenu.Length; i++)
	{
		if (Shell.MainMenu[i].MCName == 'MP')
		{
			MPIndex = i;
		}
	}
	if (MPIndex != INDEX_NONE && MPIndex < Shell.MainMenu.Length - 2)
	{
		Shell.MainMenu.Remove(Shell.MainMenu.Length - 1, 1);
		Shell.MainMenu.InsertItem(MPIndex + 1, Button);
	}
}

function OnCoopClicked(UIButton Button)
{
	if (Shell != none && Shell.m_bDisableActions)
	{
		return;
	}
	class'XComCoop_UILobby'.static.Open();
	class'XComCoop_Session'.static.Get().Host();
}

defaultproperties
{
	ScreenClass = class'UIFinalShell';
}
