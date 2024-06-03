#if defined _wrsdb_included
	#endinput
#endif
#define _wrsdb_included

enum struct WRSDB_RecordInfo {
	int id;
	char name[32+1];
	//char mapname[90]; // longest map name I've seen is bhop_pneumonoultramicroscopicsilicovolcanoconiosis_v3_001.bsp
	char hostname[128];
	char time[32];
	char wrDif[16];
	char steamid[24];
	int accountid;
	int tier;
	char date[32];
	char sync[8];
	int strafes;
	int jumps;
	int tickrate;
	//char country[33];
}

typeset WRSDB_QueryFinishedFunc
{
	function void (const char map[PLATFORM_MAX_PATH], ArrayList records, any callerdata);
};

/**
 * asdf
 *
 * @param map                       Map name you want to query results for.
 * @param cached_results_okay       Whether returning already-cached results is okay.
 * @return                          Returns true if the http-request library "sent" the request. false if not...
 */
native bool WRSDB_QueryMap(const char[] map, bool cached_results_okay=true);

/*
void QueryFinished(const char map[PLATFORM_MAX_PATH], ArrayList records, any callerdata)
{
	PrintToServer("%s %d %xh", map, records, records?records.Length:-1, callerdata);
	// example output: bhop_badges 42 0x69
}

Action Command_ASDF(int client, int args)
{
	PrintToServer("res = %d", WRSDB_QueryMapWithFunc("bhop_badges", false, QueryFinished, 0x69));
	return Plugin_Handled;
}
*/
native bool WRSDB_QueryMapWithFunc(const char[] map, bool cached_results_okay, WRSDB_QueryFinishedFunc func, any callerdata);

/**
 * Called when WRSDB has some results for the map.
 *
 * @param map                       Map name...
 * @param success                   If results could not be retrieved, this is `null`. On success it will be an ArrayList of WRSDB_RecordInfo's.
 * @noreturn
 */
forward void WRSDB_OnQueryFinished(const char map[PLATFORM_MAX_PATH], ArrayList records);


public SharedPlugin __pl_wrsdb =
{
	name = "wrsdb",
	file = "wrsdb.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_wrsdb_SetNTVOptional()
{
	MarkNativeAsOptional("WRSDB_QueryMap");
	MarkNativeAsOptional("WRSDB_QueryMapWithFunc");
}
#endif
