//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_UILobby.uc
//  PURPOSE: The co-op screen. Shows the session state, the two players, the result of the
//           compatibility check, online friends (the host invites one; in the main menu
//           the other player clicks the friend who hosts), and on the Avenger the button
//           that sends the campaign to the other player.
//           All logic lives in XComCoop_Session; this screen only draws it.
//
//           Closing the screen (CLOSE, Esc) keeps the session; LEAVE ends it. The CO-OP
//           buttons in the main menu and the pause menu open the screen again.
//---------------------------------------------------------------------------------------
class XComCoop_UILobby extends UIScreen dependson(XComCoop_Session);

// Layout in pixels (screen layout, not gameplay settings).
const PANEL_WIDTH = 760;
const PANEL_HEIGHT = 620;
const PADDING = 20;
const STATUS_Y = 80;
const STATUS_HEIGHT = 230;
const INVITE_LABEL_Y = 320;
const LIST_Y = 355;
const LIST_HEIGHT = 190;
const BUTTON_Y = 565;
const BUTTON_SLOT_WIDTH = 185;

var UIPanel Container;
var UIBGBox BG;
var UIX2PanelHeader Header;
var UIText StatusText;
var UIText InviteLabel;
var UIList FriendsList;
var UIButton LeaveButton;
var UIButton RetryButton;
var UIButton RefreshButton;
var UIButton StartButton;
var UIButton CloseButton;

// Friends currently in the list, in the same order as the list items.
var array<OnlineFriend> ShownFriends;
var array<UniqueNetId> InvitedFriends;

// Session.ChangeCount when the screen was last drawn. The screen polls the session with
// its own timer instead of registering delegates on objects that outlive the map.
var int LastChangeCount;

var localized string strTitle;
var localized string strHostSubtitle;
var localized string strClientSubtitle;
var localized string strStateIdle;
var localized string strStateWaitingForPlayer;
var localized string strStateConnecting;
var localized string strStateChecking;
var localized string strStateReady;
var localized string strStateFailed;
var localized string strReadyHostInMenu;
var localized string strReadyHostStart;
var localized string strReadyClient;
var localized string strStateSendingCampaign;
var localized string strStateLoadingCampaign;
var localized string strStateInCampaignHost;
var localized string strStateInCampaignClient;
var localized string strMirrorNoteHost;
var localized string strMirrorNoteClient;
var localized string strMirrorStatsHost;
var localized string strMirrorStatsClient;
var localized string strConnectionOpen;
var localized string strConnectionClosed;
var localized string strHost;
var localized string strPlayer2;
var localized string strYou;
var localized string strNobodyYet;
var localized string strInviteHeader;
var localized string strJoinHeader;
var localized string strNoFriendsOnline;
var localized string strPlayingXCOM;
var localized string strInvited;
var localized string strLeave;
var localized string strRetry;
var localized string strRefresh;
var localized string strStart;
var localized string strClose;

/// Opens the lobby screen, or returns it if it is already open.
static function XComCoop_UILobby Open()
{
	local XComPresentationLayerBase Pres;
	local XComCoop_UILobby LobbyScreen;

	Pres = class'XComCoop_Util'.static.GetPres();
	if (Pres == none)
	{
		return none;
	}
	LobbyScreen = XComCoop_UILobby(Pres.ScreenStack.GetFirstInstanceOf(class'XComCoop_UILobby'));
	if (LobbyScreen == none)
	{
		LobbyScreen = Pres.Spawn(class'XComCoop_UILobby', Pres);
		Pres.ScreenStack.Push(LobbyScreen);
	}
	return LobbyScreen;
}

simulated function InitScreen(XComPlayerController InitController, UIMovie InitMovie, optional name InitName)
{
	local OnlinePlayerInterface PlayerInterface;

	super.InitScreen(InitController, InitMovie, InitName);

	Container = Spawn(class'UIPanel', self).InitPanel('XComCoopLobby');
	Container.AnchorCenter();
	Container.SetSize(PANEL_WIDTH, PANEL_HEIGHT);
	Container.SetPosition(-PANEL_WIDTH / 2, -PANEL_HEIGHT / 2);

	BG = Spawn(class'UIBGBox', Container).InitBG('BG', 0, 0, PANEL_WIDTH, PANEL_HEIGHT);

	Header = Spawn(class'UIX2PanelHeader', Container).InitPanelHeader('Header', strTitle, "");
	Header.SetPosition(PADDING, PADDING);
	Header.SetHeaderWidth(PANEL_WIDTH - 2 * PADDING);

	StatusText = Spawn(class'UIText', Container).InitText('Status');
	StatusText.SetPosition(PADDING, STATUS_Y);
	StatusText.SetSize(PANEL_WIDTH - 2 * PADDING, STATUS_HEIGHT);

	InviteLabel = Spawn(class'UIText', Container).InitText('InviteLabel', strInviteHeader);
	InviteLabel.SetPosition(PADDING, INVITE_LABEL_Y);
	InviteLabel.SetSize(PANEL_WIDTH - 2 * PADDING, 30);

	FriendsList = Spawn(class'UIList', Container).InitList('Friends', PADDING, LIST_Y, PANEL_WIDTH - 2 * PADDING, LIST_HEIGHT);
	FriendsList.OnItemClicked = OnFriendClicked;

	// Four slots. RETRY and START never show at the same time, so they share one.
	RefreshButton = Spawn(class'UIButton', Container).InitButton('Refresh', strRefresh, OnRefreshClicked);
	RefreshButton.SetPosition(PADDING, BUTTON_Y);

	RetryButton = Spawn(class'UIButton', Container).InitButton('Retry', strRetry, OnRetryClicked);
	RetryButton.SetPosition(PADDING + BUTTON_SLOT_WIDTH, BUTTON_Y);

	StartButton = Spawn(class'UIButton', Container).InitButton('Start', strStart, OnStartClicked);
	StartButton.SetPosition(PADDING + BUTTON_SLOT_WIDTH, BUTTON_Y);

	LeaveButton = Spawn(class'UIButton', Container).InitButton('Leave', strLeave, OnLeaveClicked);
	LeaveButton.SetPosition(PADDING + 2 * BUTTON_SLOT_WIDTH, BUTTON_Y);

	CloseButton = Spawn(class'UIButton', Container).InitButton('Close', strClose, OnCloseClicked);
	CloseButton.SetPosition(PADDING + 3 * BUTTON_SLOT_WIDTH, BUTTON_Y);

	PlayerInterface = class'XComCoop_Util'.static.GetPlayerInterface();
	if (PlayerInterface != none)
	{
		PlayerInterface.ReadFriendsList(0);
	}

	Refresh();
	RefreshFriends();
	SetTimer(class'XComCoop_Config'.default.LobbyRefreshSeconds, true, nameof(Poll));
}

// --- Drawing ---------------------------------------------------------------------------------

simulated function Refresh()
{
	local XComCoop_Session Session;
	local string Text, MyName, OtherName;
	local int i;
	local bool bShowFriends;

	Session = class'XComCoop_Session'.static.Get();
	LastChangeCount = Session.ChangeCount;

	Header.SetText(strTitle, Session.bIsHost ? strHostSubtitle : strClientSubtitle);

	Text = StateText(Session);

	// Players
	MyName = class'XComCoop_Util'.static.GetMyName() $ " (" $ strYou $ ")";
	OtherName = Session.OtherPlayerName != "" ? Session.OtherPlayerName : strNobodyYet;
	if (Session.bIsHost)
	{
		Text $= "<br><br>" $ strHost $ ": " $ MyName $ "<br>" $ strPlayer2 $ ": " $ OtherName;
	}
	else if (Session.SessionState != eCoopState_Idle)
	{
		Text $= "<br><br>" $ strHost $ ": " $ OtherName $ "<br>" $ strPlayer2 $ ": " $ MyName;
	}
	if (ShowsConnection(Session))
	{
		Text $= "<br>" $ (class'XComCoop_Util'.static.IsConnected()
			? class'UIUtilities_Text'.static.GetColoredText(strConnectionOpen, eUIState_Good)
			: class'UIUtilities_Text'.static.GetColoredText(strConnectionClosed, eUIState_Bad));
	}

	for (i = 0; i < Session.Problems.Length; i++)
	{
		Text $= "<br>" $ class'UIUtilities_Text'.static.GetColoredText(Session.Problems[i], eUIState_Bad);
	}
	for (i = 0; i < Session.Warnings.Length; i++)
	{
		Text $= "<br>" $ class'UIUtilities_Text'.static.GetColoredText(Session.Warnings[i], eUIState_Warning);
	}
	// Only the latest few notices, so the box does not overflow.
	for (i = Max(0, Session.Notices.Length - 3); i < Session.Notices.Length; i++)
	{
		Text $= "<br>" $ Session.Notices[i];
	}

	StatusText.SetHtmlText(Text);

	bShowFriends = ShowsInviteList(Session) || ShowsJoinList(Session);
	InviteLabel.SetText(ShowsJoinList(Session) ? strJoinHeader : strInviteHeader);
	InviteLabel.SetVisible(bShowFriends);
	FriendsList.SetVisible(bShowFriends);
	RefreshButton.SetVisible(bShowFriends);
	RetryButton.SetVisible(Session.bIsHost && Session.bHosting && Session.SessionState == eCoopState_Failed);
	StartButton.SetVisible(Session.bIsHost && Session.SessionState == eCoopState_Ready && class'XComCoop_Util'.static.IsInStrategy());
}

simulated function string StateText(XComCoop_Session Session)
{
	local string Ready;

	switch (Session.SessionState)
	{
	case eCoopState_Idle:              return strStateIdle;
	case eCoopState_WaitingForPlayer:  return strStateWaitingForPlayer;
	case eCoopState_Connecting:        return strStateConnecting;
	case eCoopState_Checking:          return strStateChecking;
	case eCoopState_Ready:
		Ready = class'UIUtilities_Text'.static.GetColoredText(strStateReady, eUIState_Good) $ "<br>";
		if (!Session.bIsHost)
		{
			return Ready $ strReadyClient;
		}
		return Ready $ Repl(class'XComCoop_Util'.static.IsInStrategy() ? strReadyHostStart : strReadyHostInMenu, "%PLAYER", Session.OtherName());
	case eCoopState_SendingCampaign:
		return Repl(strStateSendingCampaign, "%PLAYER", Session.OtherName());
	case eCoopState_LoadingCampaign:
		return strStateLoadingCampaign;
	case eCoopState_InCampaign:
		return class'UIUtilities_Text'.static.GetColoredText(
			Repl(Session.bIsHost ? strStateInCampaignHost : strStateInCampaignClient, "%PLAYER", Session.OtherName()), eUIState_Good)
			$ "<br>" $ Repl(Session.bIsHost ? strMirrorNoteHost : strMirrorNoteClient, "%PLAYER", Session.OtherName())
			$ "<br>" $ (Session.bIsHost
				? Repl(strMirrorStatsHost, "%COUNT", string(Session.MirrorSent))
				: Repl(Repl(strMirrorStatsClient, "%COUNT", string(Session.MirrorReceived)), "%DROPPED", string(Session.MirrorRolledBack)));
	case eCoopState_Failed:
		return class'UIUtilities_Text'.static.GetColoredText(strStateFailed, eUIState_Bad);
	}
	return "";
}

/// The host waits for a player: clicking a friend sends an invite.
simulated function bool ShowsInviteList(XComCoop_Session Session)
{
	return Session.bIsHost && Session.SessionState == eCoopState_WaitingForPlayer;
}

/// Not in a session, in the main menu: clicking a friend joins that friend, who must be hosting.
simulated function bool ShowsJoinList(XComCoop_Session Session)
{
	return !Session.bIsHost && !Session.IsActive() && class'XComCoop_Util'.static.IsInShell();
}

/// The connection line only makes sense once the two players have found each other.
simulated function bool ShowsConnection(XComCoop_Session Session)
{
	switch (Session.SessionState)
	{
	case eCoopState_Checking:
	case eCoopState_Ready:
	case eCoopState_SendingCampaign:
	case eCoopState_LoadingCampaign:
	case eCoopState_InCampaign:
		return true;
	}
	return false;
}

/// Online friends, the ones playing XCOM 2 first.
simulated function RefreshFriends()
{
	local OnlinePlayerInterface PlayerInterface;
	local array<OnlineFriend> Friends;
	local UIListItemString Item;
	local int Pass, i;

	FriendsList.ClearItems();
	ShownFriends.Length = 0;

	PlayerInterface = class'XComCoop_Util'.static.GetPlayerInterface();
	if (PlayerInterface != none)
	{
		PlayerInterface.GetFriendsList(0, Friends);
	}

	for (Pass = 0; Pass < 2; Pass++)
	{
		for (i = 0; i < Friends.Length; i++)
		{
			if (!Friends[i].bIsOnline || Friends[i].bIsPlayingThisGame != (Pass == 0))
			{
				continue;
			}
			ShownFriends.AddItem(Friends[i]);
			Spawn(class'UIListItemString', FriendsList.ItemContainer).InitListItem(FriendLabel(Friends[i]));
		}
	}

	if (ShownFriends.Length == 0)
	{
		Item = Spawn(class'UIListItemString', FriendsList.ItemContainer).InitListItem(strNoFriendsOnline);
		Item.SetDisabled(true);
	}
}

simulated function string FriendLabel(OnlineFriend Friend)
{
	local string Label;

	Label = Friend.NickName;
	if (Friend.bIsPlayingThisGame)
	{
		Label $= "  -  " $ strPlayingXCOM;
	}
	if (IsInvited(Friend.UniqueId))
	{
		Label $= "  -  " $ strInvited;
	}
	return Label;
}

simulated function bool IsInvited(UniqueNetId Id)
{
	local int i;

	for (i = 0; i < InvitedFriends.Length; i++)
	{
		if (InvitedFriends[i] == Id)
		{
			return true;
		}
	}
	return false;
}

// --- Input -----------------------------------------------------------------------------------

simulated function OnFriendClicked(UIList ContainerList, int ItemIndex)
{
	local XComCoop_Session Session;

	if (ItemIndex < 0 || ItemIndex >= ShownFriends.Length)
	{
		return;
	}
	Session = class'XComCoop_Session'.static.Get();
	if (ShowsJoinList(Session))
	{
		Session.Join(ShownFriends[ItemIndex].UniqueId);
		return;
	}
	if (!ShowsInviteList(Session))
	{
		return;
	}
	if (Session.Invite(ShownFriends[ItemIndex].UniqueId, ShownFriends[ItemIndex].NickName))
	{
		if (!IsInvited(ShownFriends[ItemIndex].UniqueId))
		{
			InvitedFriends.AddItem(ShownFriends[ItemIndex].UniqueId);
		}
		UIListItemString(FriendsList.GetItem(ItemIndex)).SetText(FriendLabel(ShownFriends[ItemIndex]));
	}
}

/// Redraws when the session changed, and fills the friends list once Steam has it.
simulated function Poll()
{
	if (class'XComCoop_Session'.static.Get().ChangeCount != LastChangeCount)
	{
		Refresh();
	}
	if (ShownFriends.Length == 0 && FriendsList.bIsVisible)
	{
		RefreshFriends();
	}
}

simulated function OnRefreshClicked(UIButton Button)
{
	local OnlinePlayerInterface PlayerInterface;

	PlayerInterface = class'XComCoop_Util'.static.GetPlayerInterface();
	if (PlayerInterface != none)
	{
		PlayerInterface.ReadFriendsList(0);
	}
	RefreshFriends();
}

simulated function OnRetryClicked(UIButton Button)
{
	class'XComCoop_Session'.static.Get().ResumeHosting();
}

simulated function OnStartClicked(UIButton Button)
{
	class'XComCoop_Session'.static.Get().StartCampaign();
}

simulated function OnLeaveClicked(UIButton Button)
{
	class'XComCoop_Session'.static.Get().Leave();
	CloseScreen();
}

/// Closes the screen but keeps the session.
simulated function OnCloseClicked(UIButton Button)
{
	CloseScreen();
}

simulated function bool OnUnrealCommand(int cmd, int arg)
{
	if (!CheckInputIsReleaseOrDirectionRepeat(cmd, arg))
	{
		return false;
	}
	switch (cmd)
	{
	case class'UIUtilities_Input'.const.FXS_BUTTON_B:
	case class'UIUtilities_Input'.const.FXS_KEY_ESCAPE:
	case class'UIUtilities_Input'.const.FXS_R_MOUSE_DOWN:
		OnCloseClicked(none);
		return true;
	}
	return super.OnUnrealCommand(cmd, arg);
}

simulated function OnRemoved()
{
	ClearTimer(nameof(Poll));
	super.OnRemoved();
}

defaultproperties
{
	InputState = eInputState_Consume;
}
