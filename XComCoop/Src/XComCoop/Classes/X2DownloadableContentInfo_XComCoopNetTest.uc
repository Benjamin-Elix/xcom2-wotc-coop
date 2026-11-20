//---------------------------------------------------------------------------------------
//  FILE:    X2DownloadableContentInfo_XComCoopNetTest.uc
//  PURPOSE: Phase 0 test 2 console commands: connect two PCs through the game's network
//           manager over Steam and send a whole campaign history between them.
//           The logic lives in XComCoop_NetTest. Requires -allowconsole.
//           Remove this class once phase 0 is done.
//
//  Host (in a campaign):      CoopNetHost, then CoopNetSendHistory once connected
//  Other PC (main menu):      CoopNetJoin <host's hex ID from CoopMyId>
//  Both:                      CoopNetStatus, CoopNetDisconnect
//  Alone:                     CoopHistoryInfo, CoopHistoryToFile
//---------------------------------------------------------------------------------------
class X2DownloadableContentInfo_XComCoopNetTest extends X2DownloadableContentInfo;

exec function CoopNetHost()
{
	class'XComCoop_NetTest'.static.Get().Host();
}

exec function CoopNetJoin(string HostId)
{
	class'XComCoop_NetTest'.static.Get().Join(HostId);
}

exec function CoopNetRetry()
{
	class'XComCoop_NetTest'.static.Get().Retry();
}

exec function CoopNetStatus()
{
	class'XComCoop_NetTest'.static.Get().Status();
}

exec function CoopNetSendHistory()
{
	class'XComCoop_NetTest'.static.Get().SendHistory();
}

exec function CoopNetDisconnect()
{
	class'XComCoop_NetTest'.static.Get().Disconnect();
}

exec function CoopHistoryInfo()
{
	class'XComCoop_NetTest'.static.Get().HistoryInfo();
}

exec function CoopHistoryToFile()
{
	class'XComCoop_NetTest'.static.Get().HistoryToFile();
}
