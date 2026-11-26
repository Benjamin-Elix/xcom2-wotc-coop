//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_UIShellListener.uc
//  PURPOSE: Adds a CO-OP button to the main menu (after MULTIPLAYER) and starts listening
//           for co-op invites as soon as the main menu is up.
//
//           UIFinalShell rebuilds its menu now and then (UpdateMenu, e.g. after reading
//           saves or a login change), which removes our button. A short repeating timer
//           on the shell puts it back. No class override, so other mods can change the
//           menu as well.
//
//           Screen listeners live for the whole game. Never keep a reference to a screen
//           or any other actor here: the old map could then not be garbage collected and
//           the game crashes when a save is loaded ("World ... not cleaned up by garbage
//           collection"). The shell is looked up each time instead.
//---------------------------------------------------------------------------------------
class XComCoop_UIShellListener extends UIScreenListener;

const BUTTON_NAME = 'XComCoopButton';

var localized string strCoopButton;

event OnInit(UIScreen Screen)
{
	local UIFinalShell Shell;

	Shell = UIFinalShell(Screen);
	if (Shell == none)
	{
		return;
	}

	class'XComCoop_Session'.static.Get().Init();

	AddButton(Shell);
	// The timer belongs to the shell, so it goes away with it.
	Shell.SetTimer(class'XComCoop_Config'.default.MainMenuButtonCheckSeconds, true, nameof(EnsureButton), self);
}

static function UIFinalShell FindShell()
{
	local XComPresentationLayerBase Pres;

	Pres = class'XComCoop_Util'.static.GetPres();
	if (Pres == none || Pres.ScreenStack == none)
	{
		return none;
	}
	return UIFinalShell(Pres.ScreenStack.GetFirstInstanceOf(class'UIFinalShell'));
}

function EnsureButton()
{
	AddButton(FindShell());
}

function AddButton(UIFinalShell Shell)
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
	local UIFinalShell Shell;

	Shell = FindShell();
	if (Shell != none && Shell.m_bDisableActions)
	{
		return;
	}
	// The main menu is for joining: the screen lists friends to join. The host opens CO-OP
	// from the pause menu on the Avenger, where the campaign is.
	class'XComCoop_UILobby'.static.Open();
}

defaultproperties
{
	ScreenClass = class'UIFinalShell';
}
