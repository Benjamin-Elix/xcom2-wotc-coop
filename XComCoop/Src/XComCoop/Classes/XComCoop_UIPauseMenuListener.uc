//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_UIPauseMenuListener.uc
//  PURPOSE: Adds a CO-OP button to the pause menu on the Avenger, so the host can open
//           the co-op screen with the campaign already loaded (phase 2).
//
//           The pause menu decides what its list items do by their position, so the button
//           is a separate UIButton on the screen instead of a new list item. The button's
//           delegate points from the screen to this listener, never the other way round:
//           the listener lives for the whole game and must not keep the screen.
//---------------------------------------------------------------------------------------
class XComCoop_UIPauseMenuListener extends UIScreenListener;

const BUTTON_NAME = 'XComCoopPauseButton';

// Layout in pixels from the bottom centre of the screen (screen layout, not gameplay).
const BUTTON_X = -80;
const BUTTON_Y = -140;

var localized string strCoopButton;

event OnInit(UIScreen Screen)
{
	local UIButton Button;

	// Only the strategy pause menu. Not in missions, not the dev strategy shell.
	if (UIPauseMenu(Screen) == none || UIShellStrategy(Screen) != none || !class'XComCoop_Util'.static.IsInStrategy())
	{
		return;
	}
	Button = Screen.Spawn(class'UIButton', Screen);
	Button.InitButton(BUTTON_NAME, strCoopButton, OnCoopClicked);
	Button.AnchorBottomCenter();
	Button.SetPosition(BUTTON_X, BUTTON_Y);
}

function OnCoopClicked(UIButton Button)
{
	local UIPauseMenu PauseMenu;

	// Close the pause menu first: it pauses the game, and the co-op screen's timers must run.
	PauseMenu = UIPauseMenu(Button.Screen);
	if (PauseMenu != none)
	{
		PauseMenu.OnUCancel();
	}
	class'XComCoop_UILobby'.static.Open();
	class'XComCoop_Session'.static.Get().Host();
}

defaultproperties
{
	ScreenClass = class'UIPauseMenu';
}
