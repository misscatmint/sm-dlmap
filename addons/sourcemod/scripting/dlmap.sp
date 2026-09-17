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
    version = "0.1",
    url = "https://github.com/misscatmint/sm-map-downloader/"
};

ConVar g_cvUrl = null;
ConVar g_cvSubdirs = null;

public void OnPluginStart() {
    LoadTranslations("common.phrases");

    g_cvUrl = CreateConVar("sm_dlmap_url", "", "map download url");
    g_cvSubdirs = CreateConVar("sm_dlmap_subdirs", "",
        "extra subdirectories to check when downloading (space separated)");

    RegAdminCmd("sm_dlmap", Command_DownloadMap, ADMFLAG_CHANGEMAP,
                "sm_dlmap <map> - download and change to map");

    AutoExecConfig(true, "dlmap");
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

static void CleanupTempFile(const char[] tempPath) {
    if (FileExists(tempPath) && !DeleteFile(tempPath)) {
        LogError("Failed to delete map download temp file %s", tempPath);
    }
}

static void BuildTempPath(const char[] map, char[] tempPath, int size) {
    BuildPath(Path_SM, tempPath, size, "../../maps/tmp_%s_%d.bsp", map,
              GetURandomInt());
}

static void BuildDestPath(const char[] map, char[] destDir, int destDirSize,
                          char[] destPath, int destPathSize) {
    int lastSlashIdx = FindCharInString(map, '/', true);
    if (lastSlashIdx != -1) {
        BuildPath(Path_SM, destDir, destDirSize, "../../maps/%s",
                  map[lastSlashIdx + 1]);
    } else {
        BuildPath(Path_SM, destDir, destDirSize, "../../maps");
    }
    BuildPath(Path_SM, destPath, destPathSize, "../../maps/%s.bsp", map);
}

static bool QueueMapDownload(const char[] mapUrl, any context) {
    LogMessage("Downloading map from %s", mapUrl);

    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, mapUrl);
    SteamWorks_SetHTTPRequestNetworkActivityTimeout(request, HTTP_TIMEOUT);
    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request,
                                               HTTP_TIMELIMIT * 1000);
    SteamWorks_SetHTTPRequestContextValue(request, context);
    SteamWorks_SetHTTPCallbacks(request, OnMapDownloaded);
    if (!SteamWorks_SendHTTPRequest(request)) {
        LogMessage("Failed to initialize map download HTTP request");
        delete request;
        return false;
    }
    return true;
}

public Action Command_DownloadMap(int client, int args) {
    if (args < 1) {
        ReplyToCommand(client, "[SM] Usage: sm_dlmap <map>");
        return Plugin_Handled;
    }

    char input[MAX_MAP_NAME];
    char displayName[MAX_MAP_NAME];
    GetCmdArg(1, input, sizeof(input));

    if (FindMap(input, displayName, sizeof(displayName)) !=
        FindMap_NotFound) {
        ChangeMap(client, displayName);
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
        return Plugin_Handled;
    }

    int mapIdx = 0;
    char map[MAX_MAP_NAME];
    maps.GetString(mapIdx, map, sizeof(map));
    char mapUrl[MAX_MAP_URL];
    mapUrls.GetString(mapIdx, mapUrl, sizeof(mapUrl));
    char tempPath[PLATFORM_MAX_PATH];
    BuildTempPath(map, tempPath, sizeof(tempPath));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetCmdReplySource());
    pack.WriteCell(maps);
    pack.WriteCell(mapUrls);
    pack.WriteCell(mapIdx);
    pack.WriteString(tempPath);

    if (!QueueMapDownload(mapUrl, pack)) {
        ReplyToCommand(client, "[SM] Map download failed");
        CleanupTempFile(tempPath);
        delete maps;
        delete mapUrls;
        delete pack;
        return Plugin_Handled;
    }

    return Plugin_Handled;
}

static void OnMapDownloaded(Handle request, bool failure,
                            bool requestSuccessful,
                            EHTTPStatusCode statusCode, DataPack pack) {
    pack.Reset();

    int client = GetClientOfUserId(pack.ReadCell());
    SetCmdReplySource(view_as<ReplySource>(pack.ReadCell()));
    ArrayList maps = view_as<ArrayList>(pack.ReadCell());
    ArrayList mapUrls = view_as<ArrayList>(pack.ReadCell());
    int mapIdx = pack.ReadCell();
    char tempPath[PLATFORM_MAX_PATH];
    pack.ReadString(tempPath, sizeof(tempPath));

    char map[MAX_MAP_NAME];
    maps.GetString(mapIdx, map, sizeof(map));
    char mapUrl[MAX_MAP_URL];
    mapUrls.GetString(mapIdx, mapUrl, sizeof(mapUrl));

    if (failure || !requestSuccessful ||
        statusCode != k_EHTTPStatusCode200OK) {
        delete pack;
        delete request;

        if (statusCode != k_EHTTPStatusCode404NotFound) {
            LogError("Failed to download map from %s (HTTP %d)", mapUrl,
                     statusCode);
            ReplyToCommand(client, "[SM] Map download failed");
            delete maps;
            delete mapUrls;
            return;
        }

        mapIdx += 1;
        if (mapIdx < maps.Length) {
            DataPack newPack = new DataPack();
            newPack.WriteCell(GetClientUserId(client));
            newPack.WriteCell(GetCmdReplySource());
            newPack.WriteCell(maps);
            newPack.WriteCell(mapUrls);
            newPack.WriteCell(mapIdx);
            newPack.WriteString(tempPath);

            mapUrls.GetString(mapIdx, mapUrl, sizeof(mapUrl));
            if (!QueueMapDownload(mapUrl, newPack)) {
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
        LogError("Failed to initialize map download HTTP response file at %s",
                 tempPath);
        ReplyToCommand(client, "[SM] Map download failed");
        delete request;
        return;
    }

    LogMessage("Map downloaded to %s", tempPath);

    char destDir[PLATFORM_MAX_PATH];
    char destPath[PLATFORM_MAX_PATH];
    BuildDestPath(map, destDir, sizeof(destDir), destPath,
                  sizeof(destPath));
    if (!DirExists(destDir)) {
        if (!CreateDirectory(destDir, 0777)) {
            LogError("Failed to create map directory %s", destDir);
            ReplyToCommand(client, "[SM] Map download failed");
            delete request;
            return;
        }
    }

    if (!RenameFile(destPath, tempPath)) {
        LogError("Failed to rename map to %s", destPath);
        ReplyToCommand(client, "[SM] Map download failed");
        delete request;
        return;
    } else {
        LogMessage("Map download renamed to %s", destPath);
    }

    LogAction(client, -1, "\"%L\" downloaded map \"%s\"",
              client, mapUrl);

    int lastSlashIdx = FindCharInString(map, '/', true);
    ChangeMap(client, map[lastSlashIdx + 1]);
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
