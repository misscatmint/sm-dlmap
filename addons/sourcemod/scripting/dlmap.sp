#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <nextmap>
#include <SteamWorks>

#define HTTP_TIMEOUT 10
#define HTTP_TIMELIMIT 120
#define MAX_MAP_NAME 64
#define MAX_MAP_URL 256
#define MAX_MAP_SUBDIRS 16
#define MAX_MAP_SUBDIR 32

public Plugin myinfo = {
    name = "Map Downloader",
    author = "catmint",
    description = "Download a map and change to it",
    version = "0.3",
    url = "https://github.com/misscatmint/sm-dlmap/"
};

ConVar g_cvUrl = null;
ConVar g_cvSubdirs = null;
ConVar g_cvMaplistUrl = null;
ConVar g_cvWrapMapCmd = null;

public void OnPluginStart() {
    LoadTranslations("common.phrases");

    g_cvUrl = CreateConVar("sm_dlmap_url", "", "map download url");
    g_cvSubdirs = CreateConVar("sm_dlmap_subdirs", "",
        "extra subdirectories to check when downloading (space separated)");
    g_cvMaplistUrl = CreateConVar("sm_dlmap_maplist_url", "",
        "optional maplist.txt url (for fuzzy matching)");
    g_cvWrapMapCmd = CreateConVar("sm_dlmap_wrap_map_cmd", "1",
        "make sm_map also download missing maps");

    RegAdminCmd("sm_dlmap", Command_DownloadMap, ADMFLAG_ROOT,
                "sm_dlmap <map> - download and change to map");
    AddCommandListener(OnMapCommand, "sm_map");

    AutoExecConfig(true, "dlmap");
}

public void OnPluginEnd() {
    RemoveCommandListener(OnMapCommand, "sm_map");
}

public Action OnMapCommand(int client, const char[] command, int argc) {
    if (!g_cvWrapMapCmd.BoolValue || argc < 1) {
        return Plugin_Continue;
    }
    return Command_DownloadMap_Internal(client, argc, true);
}

public Action Command_DownloadMap(int client, int args) {
    return Command_DownloadMap_Internal(client, args, false);
}

static Action Command_DownloadMap_Internal(int client, int args,
                                           bool inMapWrapper) {
    if (args < 1) {
        ReplyToCommand(client, "[SM] Usage: sm_dlmap <map>");
        return Plugin_Handled;
    }

    char input[MAX_MAP_NAME];
    char displayName[MAX_MAP_NAME];
    GetCmdArg(1, input, sizeof(input));

    if (FindMap(input, displayName, sizeof(displayName)) !=
        FindMap_NotFound) {
        if (inMapWrapper) {
            return Plugin_Continue;
        }

        ReplyToCommand(client, "[SM] Map already downloaded");
        return Plugin_Handled;
    }

    if (!IsSafeName(input)) {
        ReplyToCommand(client, "[SM] Invalid map name");
        return Plugin_Handled;
    }

    char baseUrl[MAX_MAP_URL];
    g_cvUrl.GetString(baseUrl, sizeof(baseUrl));
    if (baseUrl[0] == '\0') {
        ReplyToCommand(client, "[SM] Map download URL not set");
        return Plugin_Handled;
    }

    if (!LibraryExists("SteamWorks")) {
        ReplyToCommand(client, "[SM] Missing SteamWorks library");
        return Plugin_Handled;
    }

    char maplistUrl[MAX_MAP_URL];
    g_cvMaplistUrl.GetString(maplistUrl, sizeof(maplistUrl));
    if (maplistUrl[0] == '\0') {
        StartMapDownload(client, input, baseUrl, inMapWrapper);
    } else {
        FindMapDownload(client, input, baseUrl, maplistUrl, inMapWrapper);
    }

    return Plugin_Handled;
}

static bool QueueDownload(
    const char[] url, SteamWorksHTTPRequestCompleted completedCallback,
    DataPack pack) {
    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(request, HTTP_TIMEOUT);
    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request,
                                               HTTP_TIMELIMIT * 1000);
    SteamWorks_SetHTTPRequestContextValue(request, pack);
    SteamWorks_SetHTTPCallbacks(request, completedCallback);
    if (!SteamWorks_SendHTTPRequest(request)) {
        LogError("Failed to initialize map download HTTP request");
        delete request;
        return false;
    }
    return true;
}

static void FindMapDownload(int client, const char[] input,
                            const char[] baseUrl, const char[] maplistUrl,
                            bool changeMap) {
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserIdOrConsole(client));
    pack.WriteCell(GetCmdReplySource());
    pack.WriteString(input);
    pack.WriteString(baseUrl);
    pack.WriteString(maplistUrl);
    pack.WriteCell(changeMap);

    LogMessage("Downloading map list from \"%s\"", maplistUrl);
    if (!QueueDownload(maplistUrl, OnMaplistDownloaded, pack)) {
        LogError("Map list download failed");
        StartMapDownload(client, input, baseUrl, changeMap);
        delete pack;
    }
}

static void OnMaplistDownloaded(Handle request, bool failure,
                                bool requestSuccessful,
                                EHTTPStatusCode statusCode, DataPack pack) {
    pack.Reset();
    int client = GetClientOfUserIdOrConsole(pack.ReadCell());
    SetCmdReplySource(view_as<ReplySource>(pack.ReadCell()));
    char input[MAX_MAP_NAME];
    pack.ReadString(input, sizeof(input));
    char baseUrl[MAX_MAP_URL];
    pack.ReadString(baseUrl, sizeof(baseUrl));
    char maplistUrl[MAX_MAP_URL];
    pack.ReadString(maplistUrl, sizeof(maplistUrl));
    bool changeMap = pack.ReadCell();
    delete pack;

    if (failure || !requestSuccessful ||
        statusCode != k_EHTTPStatusCode200OK) {
        LogError("Failed to download map list from \"%s\" (HTTP %d)",
                 maplistUrl, statusCode);
        StartMapDownload(client, input, baseUrl, changeMap);
        return;
    }

    char tempPath[PLATFORM_MAX_PATH];
    BuildTempPath("maplist", "txt", tempPath, sizeof(tempPath));
    bool success = SteamWorks_WriteHTTPResponseBodyToFile(request, tempPath);
    delete request;
    if (!success) {
        LogError("Failed to create map download HTTP response file at \"%s\"",
                 tempPath);
        StartMapDownload(client, input, baseUrl, changeMap);
        return;
    }

    File file = OpenFile(tempPath, "r");
    if (!file) {
        CleanupTempFile(tempPath);
        StartMapDownload(client, input, baseUrl, changeMap);
        return;
    }

    char maplistName[MAX_MAP_NAME];
    while (file.ReadLine(maplistName, sizeof(maplistName))) {
        TrimString(maplistName);
        if (StrContains(maplistName, input, false) != -1) {
            delete file;
            CleanupTempFile(tempPath);
            StartMapDownload(client, maplistName, baseUrl, changeMap);
            return;
        }
    }

    delete file;
    CleanupTempFile(tempPath);
    StartMapDownload(client, input, baseUrl, changeMap);
}

static void StartMapDownload(int client, const char[] input,
                             const char[] baseUrl, bool changeMap) {
    char subdirs[MAX_MAP_URL];
    g_cvSubdirs.GetString(subdirs, sizeof(subdirs));
    ArrayList maps = new ArrayList(ByteCountToCells(MAX_MAP_NAME));
    BuildMapNames(input, subdirs, maps);
    ArrayList mapUrls = new ArrayList(ByteCountToCells(MAX_MAP_URL));
    BuildDownloadUrls(baseUrl, maps, mapUrls);
    if (maps.Length == 0 || mapUrls.Length == 0) {
        ReplyToCommand(client, "[SM] Map download URL not set");
        delete maps;
        delete mapUrls;
        return;
    }

    int mapIdx = 0;
    char map[MAX_MAP_NAME];
    maps.GetString(mapIdx, map, sizeof(map));
    char mapUrl[MAX_MAP_URL];
    mapUrls.GetString(mapIdx, mapUrl, sizeof(mapUrl));
    char tempPath[PLATFORM_MAX_PATH];
    BuildTempPath(map, "bsp", tempPath, sizeof(tempPath));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserIdOrConsole(client));
    pack.WriteCell(GetCmdReplySource());
    pack.WriteCell(maps);
    pack.WriteCell(mapUrls);
    pack.WriteCell(mapIdx);
    pack.WriteString(tempPath);
    pack.WriteCell(changeMap);

    ShowActivity2(client, "[SM] ", "Downloading map %s...", input);
    LogMessage("Downloading map from \"%s\"", mapUrl);
    if (!QueueDownload(mapUrl, OnMapDownloaded, pack)) {
        ReplyToCommand(client, "[SM] Map download failed");
        CleanupTempFile(tempPath);
        delete maps;
        delete mapUrls;
        delete pack;
    }
}

static void OnMapDownloaded(Handle request, bool failure,
                            bool requestSuccessful,
                            EHTTPStatusCode statusCode, DataPack pack) {
    pack.Reset();

    int client = GetClientOfUserIdOrConsole(pack.ReadCell());
    SetCmdReplySource(view_as<ReplySource>(pack.ReadCell()));
    ArrayList maps = view_as<ArrayList>(pack.ReadCell());
    ArrayList mapUrls = view_as<ArrayList>(pack.ReadCell());
    int mapIdx = pack.ReadCell();
    char tempPath[PLATFORM_MAX_PATH];
    pack.ReadString(tempPath, sizeof(tempPath));
    bool changeMap = pack.ReadCell();

    char map[MAX_MAP_NAME];
    maps.GetString(mapIdx, map, sizeof(map));
    char mapUrl[MAX_MAP_URL];
    mapUrls.GetString(mapIdx, mapUrl, sizeof(mapUrl));

    if (failure || !requestSuccessful ||
        statusCode != k_EHTTPStatusCode200OK) {
        delete pack;
        delete request;

        if (statusCode != k_EHTTPStatusCode404NotFound) {
            LogError("Failed to download map from \"%s\" (HTTP %d)", mapUrl,
                     statusCode);
            ReplyToCommand(client, "[SM] Map download failed");
            delete maps;
            delete mapUrls;
            return;
        }

        mapIdx += 1;
        if (mapIdx < maps.Length) {
            DataPack newPack = new DataPack();
            newPack.WriteCell(GetClientUserIdOrConsole(client));
            newPack.WriteCell(GetCmdReplySource());
            newPack.WriteCell(maps);
            newPack.WriteCell(mapUrls);
            newPack.WriteCell(mapIdx);
            newPack.WriteString(tempPath);
            newPack.WriteCell(changeMap);

            mapUrls.GetString(mapIdx, mapUrl, sizeof(mapUrl));
            LogMessage("Downloading map from \"%s\"", mapUrl);
            if (!QueueDownload(mapUrl, OnMapDownloaded, newPack)) {
                ReplyToCommand(client, "[SM] Map download failed");
                CleanupTempFile(tempPath);
                delete maps;
                delete mapUrls;
                delete newPack;
            }

            return;
        } else if (statusCode == k_EHTTPStatusCode404NotFound) {
            int lastSlashIdx = FindCharInString(map, '/', true);
            ReplyToCommand(client, "[SM] %t", "Map was not found",
                           map[lastSlashIdx + 1]);
        }

        delete maps;
        delete mapUrls;
        return;
    }

    delete maps;
    delete mapUrls;
    delete pack;

    if (!SteamWorks_WriteHTTPResponseBodyToFile(request, tempPath)) {
        LogError("Failed to create map download HTTP response file at \"%s\"",
                 tempPath);
        ReplyToCommand(client, "[SM] Map download failed");
        delete request;
        return;
    }

    char destDir[PLATFORM_MAX_PATH];
    char destPath[PLATFORM_MAX_PATH];
    BuildDestPath(map, destDir, sizeof(destDir), destPath,
                  sizeof(destPath));
    if (!DirExists(destDir)) {
        if (!CreateDirectory(destDir, 0o755)) {
            LogError("Failed to create map directory \"%s\"", destDir);
            ReplyToCommand(client, "[SM] Map download failed");
            delete request;
            return;
        }
    }

    if (!RenameFile(destPath, tempPath)) {
        LogError("Failed to rename map from \"%s\" to \"%s\"", tempPath,
                 destPath);
        ReplyToCommand(client, "[SM] Map download failed");
        CleanupTempFile(tempPath);
        delete request;
        return;
    }

    LogAction(client, -1, "\"%L\" downloaded map \"%s\"",
              client, mapUrl);

    int lastSlashIdx = FindCharInString(map, '/', true);
    if (changeMap) {
        ChangeMap(client, map[lastSlashIdx + 1]);
    } else {
        ShowActivity2(client, "[SM] ", "Downloaded map %s", map[lastSlashIdx + 1]);
    }
    delete request;
}

static void ChangeMap(int client, const char[] map) {
    char displayName[PLATFORM_MAX_PATH];
    GetMapDisplayName(map, displayName, sizeof(displayName));

    ShowActivity2(client, "[SM] ", "%t", "Changing map", displayName);
    LogAction(client, -1, "\"%L\" changed map to \"%s\" (input \"%s\")",
              client, displayName, map);

    DataPack pack = new DataPack();
    CreateDataTimer(3.0, Timer_ChangeMap, pack);
    pack.WriteString(map);
}

static Action Timer_ChangeMap(Handle timer, DataPack pack) {
    pack.Reset();
    char map[MAX_MAP_NAME];
    pack.ReadString(map, sizeof(map));
    ForceChangeLevel(map, "sm_dlmap Command");
    return Plugin_Stop;
}

int GetClientUserIdOrConsole(int client) {
    if (client == 0) {
        return client;
    }
    return GetClientUserId(client);
}

int GetClientOfUserIdOrConsole(int userid) {
    if (userid == 0) {
        return userid;
    }
    return GetClientOfUserId(userid);
}

static bool IsSafeName(const char[] str) {
    if (str[0] == '\0') {
        return false;
    }
    for (int i = 0; str[i] != '\0'; ++i) {
        if (!IsCharAlpha(str[i]) && !IsCharNumeric(str[i]) && str[i] != '_') {
            return false;
        }
    }
    return true;
}

static void BuildMapNames(const char[] map, const char[] subdirs,
                          ArrayList maps) {
    maps.PushString(map);

    if (subdirs[0] != '\0') {
        char buffers[MAX_MAP_SUBDIRS][MAX_MAP_SUBDIR];
        int count = ExplodeString(subdirs, " ", buffers, sizeof(buffers),
                                  sizeof(buffers[]));
        for (int i = 0; i < count; ++i) {
            if (!IsSafeName(buffers[i])) {
                LogError("Bad map subdir \"%s\" (skipping)", buffers[i]);
                continue;
            }
            char subdirMap[MAX_MAP_NAME];
            Format(subdirMap, sizeof(subdirMap), "%s/%s", buffers[i], map);
            maps.PushString(subdirMap);
        }
    }
}

static void BuildDownloadUrls(const char[] baseUrl, ArrayList maps,
                              ArrayList mapUrls) {
    for (int i = 0; i < maps.Length; ++i) {
        char map[MAX_MAP_NAME];
        maps.GetString(i, map, sizeof(map));
        char mapUrl[MAX_MAP_URL];
        Format(mapUrl, sizeof(mapUrl), "%s/%s.bsp", baseUrl, map);
        mapUrls.PushString(mapUrl);
    }
}

static void BuildTempPath(const char[] name, const char[] ext,
                          char[] tempPath, int size) {
    BuildPath(Path_SM, tempPath, size, "../../maps/tmp_%s_%d.%s", name,
              GetURandomInt(), ext);
}

static void CleanupTempFile(const char[] tempPath) {
    if (FileExists(tempPath) && !DeleteFile(tempPath)) {
        LogError("Failed to delete map download temp file %s", tempPath);
    }
}

static void BuildDestPath(const char[] map, char[] destDir, int destDirSize,
                          char[] destPath, int destPathSize) {
    int lastSlashIdx = FindCharInString(map, '/', true);
    if (lastSlashIdx != -1) {
        char subdir[MAX_MAP_SUBDIR];
        strcopy(
            subdir,
            ((lastSlashIdx + 1 < sizeof(subdir)) ? lastSlashIdx + 1 :
             sizeof(subdir)),
            map);
        BuildPath(Path_SM, destDir, destDirSize, "../../maps/%s", subdir);
    } else {
        BuildPath(Path_SM, destDir, destDirSize, "../../maps");
    }
    BuildPath(Path_SM, destPath, destPathSize, "../../maps/%s.bsp", map);
}
