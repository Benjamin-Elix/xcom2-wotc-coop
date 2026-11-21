//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_UIPauseMenuListener.uc
//  PURPOSE: Adds CO-OP to the pause menu on the Avenger, right before EXIT GAME, so the
//           host can open the co-op screen with the campaign already loaded (phase 2).
//
//           UIPauseMenu decides what a list item does from its position: BuildMenu stores
//           the position of each option in public m_opt* variables and OnChildClicked
//           switches on them. After the menu is built we insert our item, move every
//           option at or after it one step down, and route list clicks through
//           OnListClicked, which handles our item and passes all others on unchanged.
//
//           Listeners run after the screen's own OnInit, so the menu is already built.
//           BuildMenu only runs once per pause menu.
//
//           The list's delegates point from the screen to this listener, never the other
//           way round: the listener lives for the whole game and must not keep the screen.
//---------------------------------------------------------------------------------------
class XComCoop_UIPauseMenuListener extends UIScreenListener;

const ITEM_NAME = 'XComCoopPauseItem';

var localized string strCoopButton;

event OnInit(UIScreen Screen)
{
	local UIPauseMenu PauseMenu;

	PauseMenu = UIPauseMenu(Screen);
	// Only the strategy pause menu. Not in missions, not the dev strategy shell.
	if (PauseMenu == none || UIShellStrategy(Screen) != none || !class'XComCoop_Util'.static.IsInStrategy())
	{
		return;
	}
	AddItem(PauseMenu);
}

function AddItem(UIPauseMenu PauseMenu)
{
	local UIList List;
	local UIListItemString Item;
	local int Index, i;

	List = PauseMenu.List;
	if (List == none || FindItem(List) != INDEX_NONE)
	{
		return;
	}

	// Before EXIT GAME, or last if the menu has no EXIT GAME.
	Index = PauseMenu.m_optExitGame >= 0 ? PauseMenu.m_optExitGame : List.ItemCount;

	Item = UIListItemString(List.CreateItem());
	Item.InitPanel(ITEM_NAME);
	Item.SetText(strCoopButton);

	// CreateItem appends; move it up to Index the same way UIList.MoveItemToTop does.
	for (i = List.GetItemIndex(Item); i > Index; i--)
	{
		List.ItemContainer.SwapChildren(i, i - 1);
	}
	List.RealizeItems();

	ShiftOptions(PauseMenu, Index);
	PauseMenu.MAX_OPTIONS++;

	List.OnItemClicked = OnListClicked;
	List.OnItemDoubleClicked = OnListClicked;
}

/// Every pause menu option at or after Index moves one step down. Unused options are -1.
function ShiftOptions(UIPauseMenu PauseMenu, int Index)
{
	if (PauseMenu.m_optReturnToGame >= Index)     PauseMenu.m_optReturnToGame++;
	if (PauseMenu.m_optSave >= Index)             PauseMenu.m_optSave++;
	if (PauseMenu.m_optLoad >= Index)             PauseMenu.m_optLoad++;
	if (PauseMenu.m_optRestart >= Index)          PauseMenu.m_optRestart++;
	if (PauseMenu.m_optChangeDifficulty >= Index) PauseMenu.m_optChangeDifficulty++;
	if (PauseMenu.m_optViewSecondWave >= Index)   PauseMenu.m_optViewSecondWave++;
	if (PauseMenu.m_optControllerMap >= Index)    PauseMenu.m_optControllerMap++;
	if (PauseMenu.m_optOptions >= Index)          PauseMenu.m_optOptions++;
	if (PauseMenu.m_optExitGame >= Index)         PauseMenu.m_optExitGame++;
	if (PauseMenu.m_optQuitGame >= Index)         PauseMenu.m_optQuitGame++;
}

static function int FindItem(UIList List)
{
	local int i;

	for (i = 0; i < List.ItemCount; i++)
	{
		if (List.GetItem(i) != none && List.GetItem(i).MCName == ITEM_NAME)
		{
			return i;
		}
	}
	return INDEX_NONE;
}

function OnListClicked(UIList ContainerList, int ItemIndex)
{
	local UIPauseMenu PauseMenu;

	PauseMenu = UIPauseMenu(ContainerList.Screen);
	if (PauseMenu == none)
	{
		return;
	}
	if (ItemIndex != FindItem(ContainerList))
	{
		// Everything else works exactly as before.
		PauseMenu.OnChildClicked(ContainerList, ItemIndex);
		return;
	}

	// Close the pause menu first: it pauses the game, and the co-op screen's timers must run.
	PauseMenu.OnUCancel();
	class'XComCoop_UILobby'.static.Open();
	class'XComCoop_Session'.static.Get().Host();
}

defaultproperties
{
	ScreenClass = class'UIPauseMenu';
}
