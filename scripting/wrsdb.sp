#include <sourcemod>
#include <convar_class>
#include <adt_trie>
#include <shavit>
#include <wrsdb>
#include <json> // https://github.com/clugg/sm-json
#include <SteamWorks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
	name = "StrafeDB World Record",
	author = "sjwr authors, kaldun, enimmy",
	description = "Grabs WRs from StrafeDB without API KEY",
	version = "1.2",
	url = ""
}

Convar gCV_StrafeDBAPIUrl;
Convar gCV_StrafeDBCacheTime;
Convar gCV_StrafeDBWRCount;
Convar gCV_ShowWRInTopleft;
Convar gCV_ShowPBInTopLeft;
Convar gCV_ShowForEveryStyle;
Convar gCV_ShowTierInTopleft;

StringMap gS_Maps;
StringMap gS_MapsCachedTime;

int gI_CurrentPagePosition[MAXPLAYERS + 1];
char gS_ClientMap[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char gS_CurrentMap[PLATFORM_MAX_PATH];
float g_fPlayerTimes[MAXPLAYERS + 1];
int g_iPlacement[MAXPLAYERS + 1];
bool g_bLate = false;

Handle gH_Forwards_OnQueryFinished = null;


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	gH_Forwards_OnQueryFinished = CreateGlobalForward("WRSDB_OnQueryFinished", ET_Ignore, Param_String, Param_Cell);

	CreateNative("WRSDB_QueryMap", Native_QueryMap);
	CreateNative("WRSDB_QueryMapWithFunc", Native_QueryMapWithFunc);

	RegPluginLibrary("wrsdb");

	g_bLate = late;

	return APLRes_Success;
}

public void OnPluginStart()
{
	gCV_StrafeDBAPIUrl = new Convar("sdb_api_url", "https://api.strafedb.net/maps/", "Can be changed for testing.", FCVAR_PROTECTED);
	gCV_StrafeDBCacheTime = new Convar("sdb_api_cache_time", "666.0", "How many seconds to cache a map from StrafeDB API.", 0, true, 5.0);
	gCV_StrafeDBWRCount = new Convar("sdb_api_wr_count", "50", "How many top times should be shown in the !wrsdb menu.", 0, true, 0.0);
	gCV_ShowWRInTopleft = new Convar("sdb_show_wr_topleft", "0", "Whether to show the SDB WR be shown in the top-left text.", 0, true, 0.0, true, 1.0);
	gCV_ShowPBInTopLeft = new Convar("sdb_show_pb_topleft", "1", "Whether to show the players current SDB PB in the top left text.", 0, true, 0.0, true, 1.0);
	gCV_ShowTierInTopleft = new Convar("sdb_show_tier_topleft", "0", "Show tier in top-left WR text.", 0, true, 0.0, true, 1.0);
	gCV_ShowForEveryStyle = new Convar("sdb_every_style", "1", "Should the top-left text be shown for every style that's not Normal also?", 0, true, 0.0, true, 1.0);

	RegConsoleCmd("sm_wrsdb", Command_WRSDB, "View global world records from StrafeDB's API.");
	RegConsoleCmd("sm_sdbwr", Command_WRSDB, "View global world records from StrafeDB's API.");

	gS_Maps = new StringMap();
	gS_MapsCachedTime = new StringMap();

	Convar.AutoExecConfig();

	if(!g_bLate)
	{
		return;
	}

	OnMapStart();

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientConnected(i) || !IsClientInGame(i) || IsFakeClient(i) || !IsClientAuthorized(i))
		{
			continue;
		}

		OnClientPostAdminCheck(i);
	}
}

public void OnMapStart()
{
	GetCurrentMap(gS_CurrentMap, sizeof(gS_CurrentMap));
	GetMapDisplayName(gS_CurrentMap, gS_CurrentMap, sizeof(gS_CurrentMap));
	RetrieveWRSDB(0, gS_CurrentMap);
}

public void OnClientPostAdminCheck(int client)
{
	g_fPlayerTimes[client] = -1.0;

	char url[512];
	Format(url, sizeof(url), "https://api.strafedb.net/players/");

	char auth[100];
	GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
	Format(url, sizeof(url), "%s%s/maps", url, auth);

	DataPack pack = new DataPack();
	pack.WriteCell(client);

	Handle request;
	if (!(request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url))
	  || !SteamWorks_SetHTTPRequestHeaderValue(request, "accept", "application/json")
	  || !SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, 4000)
	  || !SteamWorks_SetHTTPRequestContextValue(request, pack)
	  || !SteamWorks_SetHTTPCallbacks(request, RequestCompletedCallbackPB)
	  || !SteamWorks_SendHTTPRequest(request)
	)
	{
		CloseHandle(request);
		LogError("WRSDB: failed to setup & send HTTP PB request");
	}
}
public void RequestCompletedCallbackPB(Handle request, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, DataPack pack)
{
	if (bFailure || !bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
	{
		LogError("WRSDB: StrafeDB API request for PB failed");
		return;
	}

	SteamWorks_GetHTTPResponseBodyCallback(request, ResponseBodyCallbackPB, pack);
}

void ResponseBodyCallbackPB(const char[] data, DataPack pack)
{
	pack.Reset();

	int client = pack.ReadCell();
	CloseHandle(pack);

	JSON_Array maps = view_as<JSON_Array>(json_decode(data));
	if (maps == null)
	{
		LogError("WRSDB: player maps couldnt be retreived");
		return;
	}

	JSON_Object map;
	char mapname[256];
	bool found = false;

	for (int i = 0; i < maps.Length; i++)
	{
		map = maps.GetObject(i);
		map.GetString("map", mapname, sizeof(mapname));

		if(strcmp(mapname, gS_CurrentMap, false) == 0)
		{
			found = true;
			break;
		}
		delete map;
	}

	delete maps;

	if(found)
	{
		char respString[512];
		if(map.GetString("time", respString, sizeof(respString)))
		{
			g_fPlayerTimes[client] = StringToFloat(respString);
		}
		else
		{
			g_fPlayerTimes[client] = -1.0;
		}

		if(map.GetString("placement", respString, sizeof(respString)))
		{
			g_iPlacement[client] = StringToInt(respString);
		}
		else
		{
			g_iPlacement[client] = -1;
		}

	}
	else
	{
		g_fPlayerTimes[client] = -1.0;
		g_iPlacement[client] = -1;
	}

	delete map;

}

public Action Shavit_PreOnTopLeftHUD(int client, int target, char[] topleft, int topleftlength)
{
	if(!IsClientConnected(client) || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	if (!gCV_ShowWRInTopleft.BoolValue)
	{
		return Plugin_Continue;
	}

	ArrayList records;

	if (!gS_Maps.GetValue(gS_CurrentMap, records) || !records || !records.Length)
		return Plugin_Continue;

	int style = Shavit_GetBhopStyle(target);
	int track = Shavit_GetClientTrack(target);

	if ((!gCV_ShowForEveryStyle.BoolValue && style != 0) || track != 0)
		return Plugin_Continue;

	WRSDB_RecordInfo info;
	records.GetArray(0, info);

	char sjtext[80];
	FormatEx(sjtext, sizeof(sjtext), "SDB: %s (%s)", info.time, info.name);

	if (gCV_ShowTierInTopleft.BoolValue)
		Format(sjtext, sizeof(sjtext), "%s (T%d)", sjtext, info.tier);

	Format(topleft, topleftlength, "%s%s\n", topleft, sjtext);

	return Plugin_Changed;
}

public Action Shavit_OnTopLeftHUD(int client, int target, char[] topleft, int topleftlength)
{
	if(!IsClientConnected(client) || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	if(!gCV_ShowPBInTopLeft.BoolValue || g_fPlayerTimes[target] == -1.0)
	{
		return Plugin_Continue;
	}

	Format(topleft, topleftlength, "%s\nSDB PB: %.3f (#%i)", topleft, g_fPlayerTimes[target], g_iPlacement[target]);
	return Plugin_Changed;
}

Action Timer_Refresh(Handle timer, any data)
{
	RetrieveWRSDB(0, gS_CurrentMap);
	return Plugin_Stop;
}

public void Shavit_OnWorldRecord(int client, int style, float time, int jumps, int strafes, float sync, int track)
{
	if (style != 0 || track != 0)
		return;

	ArrayList records;

	if (!gS_Maps.GetValue(gS_CurrentMap, records) || !records || !records.Length)
		return;

	WRSDB_RecordInfo info;
	records.GetArray(0, info);

	if (time < StringToFloat(info.time))
		CreateTimer(5.0, Timer_Refresh, 0, TIMER_FLAG_NO_MAPCHANGE);
}

void BuildWRSDBMenu(int client, char[] mapname, int first_item=0)
{
	ArrayList records;
	gS_Maps.GetValue(mapname, records);

	int maxrecords = gCV_StrafeDBWRCount.IntValue;
	maxrecords = (maxrecords < records.Length) ? maxrecords : records.Length;

	Menu menu = new Menu(Handler_WRSDBMenu, MENU_ACTIONS_ALL);
	menu.SetTitle("Strafe DB WR\n%s - Showing %i best", mapname, maxrecords);

	for (int i = 0; i < maxrecords; i++)
	{
		WRSDB_RecordInfo record;
		records.GetArray(i, record, sizeof(record));

		char line[128];
		// FormatEx(line, sizeof(line), "#%d - %s - %s (%d Jumps)", i+1, record.name, record.time, record.jumps);
		FormatEx(line, sizeof(line), "#%d - %s - %s", i+1, record.name, record.time);

		char info[PLATFORM_MAX_PATH*2];
		FormatEx(info, sizeof(info), "%d;%s", record.id, mapname);
		menu.AddItem(info, line);
	}

	if(menu.ItemCount == 0)
	{
		char sMenuItem[64];

		FormatEx(sMenuItem, 64, "No records");
		menu.AddItem("-1", sMenuItem);
	}

	menu.ExitButton = true;
	menu.DisplayAt(client, first_item, MENU_TIME_FOREVER);

	gI_CurrentPagePosition[client] = 0;
}

int Handler_WRSDBMenu(Menu menu, MenuAction action, int client, int choice)
{
	if (action == MenuAction_Select)
	{
		int id;
		char info[PLATFORM_MAX_PATH*2];
		menu.GetItem(choice, info, sizeof(info));

		if (StringToInt(info) == -1)
		{
			return 0;
		}

		char exploded[2][PLATFORM_MAX_PATH];
		ExplodeString(info, ";", exploded, 2, PLATFORM_MAX_PATH, true);

		id = StringToInt(exploded[0]);
		gS_ClientMap[client] = exploded[1];

		WRSDB_RecordInfo record;
		ArrayList records;
		gS_Maps.GetValue(gS_ClientMap[client], records);

		for (int i = 0; i < records.Length; i++)
		{
			records.GetArray(i, record, sizeof(record));
			if (record.id == id)
				break;
		}

		if (record.id != id)
		{
			return 0;
		}

		Menu submenu = new Menu(SubMenu_Handler);

		char display[234];

		FormatEx(display, sizeof(display),
			"%s %s\n \n\
			Time: %s (%s)\n\
			Jumps: %d\n\
			Strafes: %d (%s％)\n\
			Server: %s\n\
			Date: %s\n",
			record.name, record.steamid,
			record.time, record.wrDif,
			record.jumps,
			record.strafes, record.sync,
			record.hostname,
			record.date
		);

		submenu.SetTitle(display);

		FormatEx(display, sizeof(display), "%sA", record.steamid);
		submenu.AddItem(display, "Open Steam profile", ITEMDRAW_DEFAULT);
		FormatEx(display, sizeof(display), "%sB", record.steamid);
		submenu.AddItem(display, "Open StrafeDB profile", ITEMDRAW_DEFAULT);

		submenu.ExitBackButton = true;
		submenu.ExitButton = true;
		submenu.Display(client, MENU_TIME_FOREVER);

		gI_CurrentPagePosition[client] = GetMenuSelectionPosition();
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

int SubMenu_Handler(Menu menu, MenuAction action, int client, int choice)
{
	static bool DONT_CLOSE_MENU = false;

	if (action == MenuAction_Select)
	{
		char info[69];
		menu.GetItem(choice, info, sizeof(info));

		if (!info[0] || info[0] != '[')
		{
			return 0;
		}

		int len = strlen(info);
		int type = info[len-1];
		info[len-1] = 0;

		if (type == 'A')
		{
			char url[192+1];
			FormatEx(url, sizeof(url), "https://steamcommunity.com/profiles/%s", info);
			ShowMOTDPanel(client, "you just lost The Game", url, MOTDPANEL_TYPE_URL);
		}
		else if (type == 'B')
		{
			char url[192+1];
			FormatEx(url, sizeof(url), "https://strafedb.net/players/%s", info);
			ShowMOTDPanel(client, "you just lost The Game", url, MOTDPANEL_TYPE_URL);
		}

		DONT_CLOSE_MENU = true;
		menu.Display(client, MENU_TIME_FOREVER);
	}
	else if (action == MenuAction_Cancel && choice == MenuCancel_ExitBack)
	{
		BuildWRSDBMenu(client, gS_ClientMap[client], gI_CurrentPagePosition[client]);
	}
	else if (action == MenuAction_End)
	{
		if (!DONT_CLOSE_MENU)
			delete menu;
		DONT_CLOSE_MENU = false;
	}

	return 0;
}

ArrayList CacheMap(char mapname[PLATFORM_MAX_PATH], JSON_Array json)
{
	ArrayList records;

	if (gS_Maps.GetValue(mapname, records))
		delete records;

	records = new ArrayList(sizeof(WRSDB_RecordInfo));

	gS_MapsCachedTime.SetValue(mapname, GetEngineTime(), true);
	gS_Maps.SetValue(mapname, records, true);

	for (int i = 0; i < json.Length; i++)
	{
		JSON_Object record = json.GetObject(i);

		WRSDB_RecordInfo info;
		info.id = record.GetInt("id");
		record.GetString("player", info.name, sizeof(info.name));
		record.GetString("server", info.hostname, sizeof(info.hostname));
		record.GetString("time", info.time, sizeof(info.time));
		record.GetString("steamid", info.steamid, sizeof(info.steamid));
		info.accountid = SteamIDToAccountID_no_64(info.steamid);
		record.GetString("date", info.date, sizeof(info.date));
		record.GetString("timediff", info.wrDif, sizeof(info.wrDif));
		record.GetString("sync", info.sync, sizeof(info.sync));
		info.strafes = record.GetInt("strafes");
		info.jumps = record.GetInt("jumps");
		info.tier = record.GetInt("tier");
		//record.GetString("country", info.country, sizeof(info.country));
		//UppercaseString(info.country);
		records.PushArray(info, sizeof(info));
	}

	CallOnQueryFinishedCallback(mapname, records);
	return records;
}


void ResponseBodyCallback(const char[] data, DataPack pack)
{
	pack.Reset();

	int client = GetClientFromSerial(pack.ReadCell());
	char mapname[PLATFORM_MAX_PATH];
	pack.ReadString(mapname, sizeof(mapname));

	DataPack AAAAA = pack.ReadCell();

	CloseHandle(pack);
	JSON_Array records = view_as<JSON_Array>(json_decode(data));
	if (records == null)
	{
		CallOnQueryFinishedCallback(mapname, null);
		if (AAAAA)
			CallOnQueryFinishedWithFunctionCallback(mapname, null, AAAAA);

		if (client != 0)
			ReplyToCommand(client, "WRSDB: bbb");
		LogError("WRSDB: bbb");
		return;
	}

	ArrayList records2 = CacheMap(mapname, records);

	json_cleanup(records);

	if (AAAAA)
		CallOnQueryFinishedWithFunctionCallback(mapname, records2, AAAAA);

	if (client != 0)
		BuildWRSDBMenu(client, mapname);
}

public void RequestCompletedCallback(Handle request, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, DataPack pack)
{
	pack.Reset();
	int client = GetClientFromSerial(pack.ReadCell());

	//ReplyToCommand(client, "bFailure = %d, bRequestSuccessful = %d, eStatusCode = %d", bFailure, bRequestSuccessful, eStatusCode);

	if (bFailure || !bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
	{
		char map[PLATFORM_MAX_PATH];
		pack.ReadString(map, sizeof(map));
		CallOnQueryFinishedCallback(map, null);
		DataPack AAAAA = pack.ReadCell();
		if (AAAAA)
			CallOnQueryFinishedWithFunctionCallback(map, null, AAAAA);
		delete pack;

		if (client != 0)
			ReplyToCommand(client, "WRSDB: StrafeDB API request failed");
		LogError("WRSDB: StrafeDB API request failed");
		return;
	}

	SteamWorks_GetHTTPResponseBodyCallback(request, ResponseBodyCallback, pack);
}

bool RetrieveWRSDB(int client, char[] mapname, DataPack MOREPACKS=null)
{
	int serial = client ? GetClientSerial(client) : 0;
	char apiurl[230];

	gCV_StrafeDBAPIUrl.GetString(apiurl, sizeof(apiurl));

	if (apiurl[0] == 0)
	{
		ReplyToCommand(client, "WRSDB: StrafeDB API URL is not set.");
		LogError("WRSDB: StrafeDB API URL is not set.");
		return false;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(serial);
	pack.WriteString(mapname);
	pack.WriteCell(MOREPACKS);

	StrCat(apiurl, sizeof(apiurl), mapname);
	StrCat(apiurl, sizeof(apiurl), "/records");
	//ReplyToCommand(client, "url = %s", apiurl);

	Handle request;
	if (!(request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, apiurl))
	  || !SteamWorks_SetHTTPRequestHeaderValue(request, "accept", "application/json")
	  || !SteamWorks_SetHTTPRequestContextValue(request, pack)
	  || !SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, 4000)
	  || !SteamWorks_SetHTTPCallbacks(request, RequestCompletedCallback)
	  || !SteamWorks_SendHTTPRequest(request)
	)
	{
		CloseHandle(pack);
		CloseHandle(request);
		ReplyToCommand(client, "WRSDB: failed to setup & send HTTP request");
		LogError("WRSDB: failed to setup & send HTTP request");
		return false;
	}

	return true;
}

Action Command_WRSDB(int client, int args)
{
	if (client == 0 || IsFakeClient(client))// || !IsClientAuthorized(client))
		return Plugin_Handled;

	char mapname[PLATFORM_MAX_PATH];

	if (args < 1)
		mapname = gS_CurrentMap;
	else
		GetCmdArg(1, mapname, sizeof(mapname));

	float cached_time;
	if (gS_MapsCachedTime.GetValue(mapname, cached_time))
	{
		if (cached_time > (GetEngineTime() - gCV_StrafeDBCacheTime.FloatValue))
		{
			BuildWRSDBMenu(client, mapname);
			return Plugin_Handled;
		}
	}

	RetrieveWRSDB(client, mapname);
	return Plugin_Handled;
}


stock void LowercaseStringxx(char[] str)
{
	for (int i = 0; str[i] != 0; i++)
	{
		str[i] = CharToLower(str[i]);
	}
}

public any Native_QueryMap(Handle plugin, int numParams)
{
	char map[PLATFORM_MAX_PATH];
	GetNativeString(1, map, sizeof(map));
	LowercaseStringxx(map);

	bool cache_okay = GetNativeCell(2);

	if (cache_okay)
	{
		ArrayList records;

		if (gS_Maps.GetValue(map, records) && records && records.Length)
		{
			CallOnQueryFinishedCallback(map, records);
			return true;
		}
	}

	return RetrieveWRSDB(0, map);
}

public any Native_QueryMapWithFunc(Handle plugin, int numParams)
{
	char map[PLATFORM_MAX_PATH];
	GetNativeString(1, map, sizeof(map));
	LowercaseStringxx(map);

	bool cache_okay = GetNativeCell(2);

	DataPack data = new DataPack();
	data.WriteFunction(GetNativeFunction(3));
	data.WriteCell(plugin);
	data.WriteCell(GetNativeCell(4));

	if (cache_okay)
	{
		ArrayList records;

		if (gS_Maps.GetValue(map, records) && records && records.Length)
		{
			CallOnQueryFinishedWithFunctionCallback(map, records, data);
			return true;
		}
	}

	bool res = RetrieveWRSDB(0, map, data);

	if (!res)
		delete data;

	return res;
}

void CallOnQueryFinishedCallback(const char map[PLATFORM_MAX_PATH], ArrayList records)
{
	Call_StartForward(gH_Forwards_OnQueryFinished);
	Call_PushString(map);
	Call_PushCell(records);
	Call_Finish();
}

void CallOnQueryFinishedWithFunctionCallback(const char map[PLATFORM_MAX_PATH], ArrayList records, DataPack callerinfo)
{
	callerinfo.Reset();
	Function func = callerinfo.ReadFunction();
	Handle plugin = callerinfo.ReadCell();
	int callerdata = callerinfo.ReadCell();
	delete callerinfo;

	Call_StartFunction(plugin, func);
	Call_PushString(map);
	Call_PushCell(records);
	Call_PushCell(callerdata);
	Call_Finish();
}

stock int SteamIDToAccountID_no_64(const char[] sInput)
{
	char sSteamID[32];
	strcopy(sSteamID, sizeof(sSteamID), sInput);
	ReplaceString(sSteamID, 32, "\"", "");
	TrimString(sSteamID);

	if (StrContains(sSteamID, "STEAM_") != -1)
	{
		ReplaceString(sSteamID, 32, "STEAM_", "");

		char parts[3][11];
		ExplodeString(sSteamID, ":", parts, 3, 11);

		// Let X, Y and Z constants be defined by the SteamID: STEAM_X:Y:Z.
		// Using the formula W=Z*2+Y, a SteamID can be converted:
		return StringToInt(parts[2]) * 2 + StringToInt(parts[1]);
	}
	else if (StrContains(sSteamID, "U:1:") != -1)
	{
		ReplaceString(sSteamID, 32, "[", "");
		ReplaceString(sSteamID, 32, "U:1:", "");
		ReplaceString(sSteamID, 32, "]", "");

		return StringToInt(sSteamID);
	}

	return 0;
}
