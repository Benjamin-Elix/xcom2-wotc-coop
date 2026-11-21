//---------------------------------------------------------------------------------------
//  FILE:    XComCoop_PopupCallbacks.uc
//  PURPOSE: Phase 2: gives a popup the host sent the same button handler it has on the
//           host. A popup's handler (DynamicPropertySet.CallbackFunction) is a delegate
//           and cannot be sent, so the client looks it up by the alert name.
//
//           The table is generated from XComHQPresentationLayer.uc in the Community
//           Highlander (every BuildUIAlert call with a handler on that class). Popups
//           without a handler only close, the same on both PCs. Not covered: region
//           contact/outpost (decisions, phase 3), eAlert_AlienVictoryImminent (private
//           handler) and eAlert_SuperSoldier / eAlert_Objective (handler passed in).
//
//           On the client a handler that only shows something (jump to a room, open a
//           report) works; one that changes the campaign is undone like everything else
//           the client does until phase 3.
//---------------------------------------------------------------------------------------
class XComCoop_PopupCallbacks extends Object;

/// Sets PropertySet.CallbackFunction for a 'UIAlert' popup. False if there is none.
static function bool SetCallback(XComHQPresentationLayer HQPres, out X2StrategyGameRulesetDataStructures.DynamicPropertySet PropertySet)
{
	local name EventToTrigger;

	if (HQPres == none || PropertySet.PrimaryRoutingKey != 'UIAlert')
	{
		return false;
	}
	EventToTrigger = class'X2StrategyGameRulesetDataStructures'.static.GetDynamicNameProperty(PropertySet, 'EventToTrigger');

	switch (PropertySet.SecondaryRoutingKey)
	{
	// Two handlers each; the event the popup triggers tells them apart.
	case 'eAlert_CouncilComm':
		if (EventToTrigger == 'OnFortressRevealAlert')
		{
			PropertySet.CallbackFunction = HQPres.FortressRevealAlertCB;
		}
		else
		{
			PropertySet.CallbackFunction = HQPres.CouncilReportAlertCB;
		}
		return true;
	case 'eAlert_LowEngineers':
		if (EventToTrigger == 'WarningNeedMoreEngineers')
		{
			PropertySet.CallbackFunction = HQPres.LowEngineersSmallCB;
		}
		else
		{
			PropertySet.CallbackFunction = HQPres.LowWarningCB;
		}
		return true;
	// Built by XComGameState_AlienNetworkComponent, XComGameState_MissionSite, XComGameState_WorldRegion.
	case 'eAlert_Doom':
	case 'eAlert_AlienFacility':
		PropertySet.CallbackFunction = class'XComHQPresentationLayer'.static.DoomAlertCB;
		return true;
	// Generated from XComHQPresentationLayer.uc:
	case 'eAlert_BlackMarket':
		PropertySet.CallbackFunction = HQPres.BMAlertCB;
		return true;
	case 'eAlert_BlackMarketAvailable':
		PropertySet.CallbackFunction = HQPres.BMAppearedCB;
		return true;
	case 'eAlert_BuildSlotOpen':
		PropertySet.CallbackFunction = HQPres.AssignBuildStaffCB;
		return true;
	case 'eAlert_BuildTheRing':
		PropertySet.CallbackFunction = HQPres.LowWarningCB;
		return true;
	case 'eAlert_ChosenAmbush':
		PropertySet.CallbackFunction = HQPres.ChosenAmbushAlertCB;
		return true;
	case 'eAlert_ChosenSabotage':
		PropertySet.CallbackFunction = HQPres.ChosenSabotageCB;
		return true;
	case 'eAlert_ChosenStronghold':
		PropertySet.CallbackFunction = HQPres.ChosenStrongholdAlertCB;
		return true;
	case 'eAlert_ClassEarned':
		PropertySet.CallbackFunction = HQPres.TrainingCompleteCB;
		return true;
	case 'eAlert_ClearRoomComplete':
		PropertySet.CallbackFunction = HQPres.ClearRoomCompleteCB;
		return true;
	case 'eAlert_ClearRoomSlotOpen':
		PropertySet.CallbackFunction = HQPres.AssignBuildStaffCB;
		return true;
	case 'eAlert_ConfirmCovertAction':
		PropertySet.CallbackFunction = HQPres.ConfirmCovertActionCB;
		return true;
	case 'eAlert_CouncilMission':
		PropertySet.CallbackFunction = HQPres.CouncilMissionAlertCB;
		return true;
	case 'eAlert_DarkEvent':
		PropertySet.CallbackFunction = HQPres.DarkEventActivatedCB;
		return true;
	case 'eAlert_FacilityComplete':
		PropertySet.CallbackFunction = HQPres.FacilityCompleteCB;
		return true;
	case 'eAlert_GOps':
		PropertySet.CallbackFunction = HQPres.GOpsAlertCB;
		return true;
	case 'eAlert_HelpResHQGoods':
		PropertySet.CallbackFunction = HQPres.NewResHQGoodsAvailableCB;
		return true;
	case 'eAlert_InstantResourceCache':
		PropertySet.CallbackFunction = HQPres.InstantResourceCacheCB;
		return true;
	case 'eAlert_ItemComplete':
		PropertySet.CallbackFunction = HQPres.ItemCompleteCB;
		return true;
	case 'eAlert_LandedUFO':
		PropertySet.CallbackFunction = HQPres.LandedUFOAlertCB;
		return true;
	case 'eAlert_LostAndAbandoned':
		PropertySet.CallbackFunction = HQPres.LostAndAbandonedAlertCB;
		return true;
	case 'eAlert_LowIntel':
		PropertySet.CallbackFunction = HQPres.LowWarningCB;
		return true;
	case 'eAlert_LowScientists':
		PropertySet.CallbackFunction = HQPres.LowWarningCB;
		return true;
	case 'eAlert_LowScientistsSmall':
		PropertySet.CallbackFunction = HQPres.LowScientistsSmallCB;
		return true;
	case 'eAlert_LowSupplies':
		PropertySet.CallbackFunction = HQPres.LowWarningCB;
		return true;
	case 'eAlert_NewScanningSite':
		PropertySet.CallbackFunction = HQPres.POIAlertCB;
		return true;
	case 'eAlert_NextCovertAction':
		PropertySet.CallbackFunction = HQPres.NextCovertActionPopupCB;
		return true;
	case 'eAlert_ProvingGroundProjectComplete':
		PropertySet.CallbackFunction = HQPres.ProvingGroundProjectCompleteCB;
		return true;
	case 'eAlert_PsiOperativeIntro':
		PropertySet.CallbackFunction = HQPres.PsiTrainingCompleteCB;
		return true;
	case 'eAlert_PsiTrainingComplete':
		PropertySet.CallbackFunction = HQPres.PsiTrainingCompleteCB;
		return true;
	case 'eAlert_RescueSoldier':
		PropertySet.CallbackFunction = HQPres.RescueSoldierAlertCB;
		return true;
	case 'eAlert_ResearchComplete':
		PropertySet.CallbackFunction = HQPres.ResearchCompletePopupCB;
		return true;
	case 'eAlert_ResistanceOp':
		PropertySet.CallbackFunction = HQPres.ResistanceOpsAlertCB;
		return true;
	case 'eAlert_ResourceCacheAvailable':
		PropertySet.CallbackFunction = HQPres.ResourceCacheAlertCB;
		return true;
	case 'eAlert_ResourceCacheComplete':
		PropertySet.CallbackFunction = HQPres.ResourceCacheCompleteCB;
		return true;
	case 'eAlert_Retaliation':
		PropertySet.CallbackFunction = HQPres.RetaliationAlertCB;
		return true;
	case 'eAlert_ScanComplete':
		PropertySet.CallbackFunction = HQPres.POICompleteCB;
		return true;
	case 'eAlert_StaffSlotOpen':
		PropertySet.CallbackFunction = HQPres.AssignFacilityStaffCB;
		return true;
	case 'eAlert_SupplyRaid':
		PropertySet.CallbackFunction = HQPres.SupplyRaidAlertCB;
		return true;
	case 'eAlert_TimeSensitiveMission':
		PropertySet.CallbackFunction = HQPres.TimeSensitiveMissionCB;
		return true;
	case 'eAlert_TrainingComplete':
		PropertySet.CallbackFunction = HQPres.TrainingCompleteCB;
		return true;
	case 'eAlert_UFOEvaded':
		PropertySet.CallbackFunction = HQPres.ReturnToPreviousLocationCB;
		return true;
	case 'eAlert_UFOInbound':
		PropertySet.CallbackFunction = HQPres.UFOInboundCB;
		return true;
	case 'eAlert_UpgradeComplete':
		PropertySet.CallbackFunction = HQPres.UpgradeCompleteCB;
		return true;
	case 'eAlert_XPACK_Retribution':
		PropertySet.CallbackFunction = HQPres.ChosenRetributionCB;
		return true;
	}
	return false;
}
