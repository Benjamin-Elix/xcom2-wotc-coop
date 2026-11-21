//---------------------------------------------------------------------------------------
//  FILE:    X2DownloadableContentInfo_XComCoopMergeTest.uc
//  PURPOSE: Phase 0 test 3 console commands (merge a mission result into another copy
//           of the campaign). The logic lives in XComCoop_MergeTest. Requires
//           -allowconsole. Remove this class once phase 0 is done.
//---------------------------------------------------------------------------------------
class X2DownloadableContentInfo_XComCoopMergeTest extends X2DownloadableContentInfo;

exec function CoopMissionBegin()
{
	class'XComCoop_MergeTest'.static.Get().Begin();
}

exec function CoopMissionSummary()
{
	class'XComCoop_MergeTest'.static.Get().MakeSummary();
}

exec function CoopMissionShow()
{
	class'XComCoop_MergeTest'.static.Get().ShowSummary();
}

exec function CoopMissionApply()
{
	class'XComCoop_MergeTest'.static.Get().Apply();
}
