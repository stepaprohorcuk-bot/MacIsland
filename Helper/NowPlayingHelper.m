// Мост к системному «Сейчас играет» (MediaRemote) для MacIsland.
// С macOS 15.4 MediaRemote отвечает только системным программам, поэтому MacIsland
// загружает этот модуль внутрь /usr/bin/perl и общается с ним через трубы:
//   stdin  ← команды построчно: toggle / next / prev, можно с pid плеера: «toggle 9512»
//   stdout → JSON-строка при каждом изменении трека или состояния,
//            {"players": [...]} — все плееры сразу (для раздельной карточки),
//            либо {"direct": команда, "pid", "bid"} — команду нужно передать плееру в обход системы.
//
// Кого показываем (музыка важнее видео):
//   1) играющая музыкальная программа;
//   2) иначе — тот, кто последним начал играть (или кем последним управляли с острова);
//   3) при равенстве — музыкальная программа, затем «главный» плеер системы.
// Системные команды macOS всегда отдаёт «главному» плееру — тому, кто последним начал играть,
// даже если адресовать их другому. Поэтому, если выбран не главный плеер, команду
// отправляет сам MacIsland (горячая клавиша или AppleScript), а не MediaRemote.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendFn)(int, CFDictionaryRef);
typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef id (*GetOriginFn)(void);
typedef CFStringRef (*ClientBundleFn)(id);
typedef int (*ClientPIDFn)(id);
typedef void (*InfoForPlayerFn)(id, void *, dispatch_queue_t, void (^)(CFDictionaryRef));

static GetInfoFn getInfo;
static GetPIDFn getPID;
static SendFn sendCommand;
static GetClientsFn getClients;
static GetOriginFn localOrigin;
static ClientBundleFn clientBundle;
static ClientPIDFn clientPID;
static InfoForPlayerFn infoForPlayer;
static Class playerPathClass;

static dispatch_queue_t q;
static NSString *lastSig;
static NSString *lastArtKey;
static NSMutableDictionary<NSString *, NSDate *> *lastStart;     // когда плеер начал играть / им управляли
static NSMutableDictionary<NSString *, NSNumber *> *lastRate;
static NSString *curBid;                                         // выбранный плеер
static int curPid;
static int electedPidCache;
static BOOL curElected;
static BOOL busy;
static NSArray<NSDictionary *> *lastFound;                     // все плееры из последнего опроса
static NSString *lastPlayersSig;
static NSMutableDictionary<NSNumber *, NSString *> *playerArtKeys;
static NSUInteger generation;

static void emit(NSDictionary *d) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!j) return;
    fwrite(j.bytes, 1, j.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// Браузеры и видеоплееры: они уступают музыке.
static BOOL isVideoApp(NSString *b) {
    static NSArray *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[ @"com.google.Chrome", @"com.apple.Safari", @"com.apple.WebKit", @"ru.yandex.desktop.yandex-browser",
                      @"company.thebrowser.", @"com.microsoft.edgemac", @"org.mozilla.", @"com.operasoftware.",
                      @"com.brave.Browser", @"com.vivaldi.", @"org.chromium.", @"app.zen-browser.", @"com.kagi.kagimacOS",
                      @"com.colliderli.iina", @"org.videolan.vlc", @"com.apple.QuickTimePlayerX", @"com.apple.TV",
                      @"io.mpv", @"com.firecore.infuse", @"com.apple.podcasts" ];
    });
    for (NSString *p in prefixes) if ([b hasPrefix:p]) return YES;
    return NO;
}

static double rateOf(NSDictionary *info) { return [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue]; }

static void publish(NSDictionary *x, int pid, NSString *bid, BOOL elected) {
    NSString *title  = [x[@"kMRMediaRemoteNowPlayingInfoTitle"] description] ?: @"";
    NSString *artist = [x[@"kMRMediaRemoteNowPlayingInfoArtist"] description] ?: @"";
    NSString *album  = [x[@"kMRMediaRemoteNowPlayingInfoAlbum"] description] ?: @"";
    double rate = rateOf(x);
    double dur  = [x[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
    double el   = [x[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
    NSDate *ts  = x[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    NSData *art = x[@"kMRMediaRemoteNowPlayingInfoArtworkData"];

    NSString *sig = [NSString stringWithFormat:@"%d|%d|%@|%@|%@|%.2f|%.1f|%.1f", pid, elected, title, artist, album, rate, dur, el];
    NSString *artKey = [NSString stringWithFormat:@"%d|%@|%lu", pid, title, (unsigned long)art.length];
    BOOL artChanged = ![artKey isEqualToString:lastArtKey];
    if ([sig isEqualToString:lastSig] && !artChanged) return;
    lastSig = sig;

    NSMutableDictionary *o = [@{ @"pid": @(pid), @"bid": bid ?: @"", @"elected": @(elected),
                                 @"title": title, @"artist": artist,
                                 @"album": album, @"rate": @(rate), @"dur": @(dur), @"el": @(el),
                                 @"ts": @([ts isKindOfClass:NSDate.class] ? ts.timeIntervalSince1970
                                                                          : NSDate.date.timeIntervalSince1970) } mutableCopy];
    if (artChanged) {
        lastArtKey = artKey;
        o[@"art"] = art ? [art base64EncodedStringWithOptions:0] : @"";
    }
    emit(o);
}

/// Все плееры — для раздельной карточки. Обложку шлём, только когда она поменялась.
static void publishPlayers(NSArray<NSDictionary *> *found, int electedPid) {
    NSMutableArray *list = [NSMutableArray array];
    NSMutableString *sig = [NSMutableString string];
    NSMutableDictionary *newArt = [NSMutableDictionary dictionary];
    BOOL artChanged = NO;
    found = [found sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"pid" ascending:YES] ]];
    for (NSDictionary *f in found) {
        NSDictionary *x = f[@"info"];
        int pid = [f[@"pid"] intValue];
        NSString *title = [x[@"kMRMediaRemoteNowPlayingInfoTitle"] description] ?: @"";
        NSString *artist = [x[@"kMRMediaRemoteNowPlayingInfoArtist"] description] ?: @"";
        double rate = rateOf(x), dur = [x[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
        double el = [x[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        NSDate *ts = x[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        NSData *art = x[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        BOOL elected = pid == electedPid;
        [sig appendFormat:@"%d|%d|%@|%@|%.2f|%.1f|%.1f;", pid, elected, title, artist, rate, dur, el];
        NSMutableDictionary *o = [@{ @"pid": @(pid), @"bid": f[@"bid"], @"elected": @(elected),
                                     @"video": @(isVideoApp(f[@"bid"])), @"title": title, @"artist": artist,
                                     @"rate": @(rate), @"dur": @(dur), @"el": @(el),
                                     @"ts": @([ts isKindOfClass:NSDate.class] ? ts.timeIntervalSince1970
                                                                              : NSDate.date.timeIntervalSince1970) } mutableCopy];
        NSString *artKey = [NSString stringWithFormat:@"%@|%lu", title, (unsigned long)art.length];
        newArt[@(pid)] = artKey;
        if (![playerArtKeys[@(pid)] isEqualToString:artKey]) {
            o[@"art"] = art ? [art base64EncodedStringWithOptions:0] : @"";
            artChanged = YES;
        }
        [list addObject:o];
    }
    if ([sig isEqualToString:lastPlayersSig] && !artChanged) return;
    lastPlayersSig = sig;
    playerArtKeys = newArt;
    emit(@{ @"players": list });
}

/// Запасной путь: только то, что выбрала система.
static void pollSystem(void) {
    getPID(q, ^(int pid) {
        getInfo(q, ^(CFDictionaryRef ref) {
            curBid = nil; curPid = pid; curElected = YES;
            publish((__bridge NSDictionary *)ref ?: @{}, pid, @"", YES);
            busy = NO;
        });
    });
}

static void poll(void) {
    if (busy) return;
    busy = YES;
    NSUInteger gen = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), q, ^{ if (generation == gen) busy = NO; });

    if (!getClients || !infoForPlayer || !playerPathClass) { pollSystem(); return; }

    getPID(q, ^(int electedPid) {
        electedPidCache = electedPid;
        getClients(q, ^(CFArrayRef ref) {
            NSArray *clients = [(__bridge NSArray *)ref copy] ?: @[];
            if (clients.count == 0) { pollSystem(); return; }
            id origin = localOrigin();
            SEL initSel = NSSelectorFromString(@"initWithOrigin:client:player:");
            NSMutableArray *found = [NSMutableArray array];
            dispatch_group_t g = dispatch_group_create();
            for (id c in clients) {
                NSString *bid = (__bridge NSString *)clientBundle(c) ?: @"";
                int pid = clientPID(c);
                id path = ((id (*)(id, SEL, id, id, id))objc_msgSend)([playerPathClass alloc], initSel, origin, c, nil);
                if (!path) continue;
                dispatch_group_enter(g);
                infoForPlayer(path, NULL, q, ^(CFDictionaryRef d) {
                    NSDictionary *x = (__bridge NSDictionary *)d;
                    if ([[x[@"kMRMediaRemoteNowPlayingInfoTitle"] description] length] > 0)
                        [found addObject:@{ @"bid": bid, @"pid": @(pid), @"info": [x copy] }];
                    dispatch_group_leave(g);
                });
            }
            dispatch_group_notify(g, q, ^{
                if (generation != gen) return;
                lastFound = [found copy];
                publishPlayers(found, electedPid);
                if (found.count == 0) {
                    curBid = nil; curPid = electedPid; curElected = YES;
                    publish(@{}, electedPid, @"", YES); busy = NO; return;
                }
                NSDate *now = NSDate.date;
                for (NSDictionary *f in found) {
                    double r = rateOf(f[@"info"]);
                    if (r > 0 && [lastRate[f[@"bid"]] doubleValue] <= 0) lastStart[f[@"bid"]] = now;   // начал играть
                    lastRate[f[@"bid"]] = @(r);
                }
                NSDictionary *best = nil;
                // 1) играющая музыка — всегда первая
                for (NSDictionary *f in found)
                    if (!isVideoApp(f[@"bid"]) && rateOf(f[@"info"]) > 0 &&
                        (!best || [lastStart[f[@"bid"]] ?: NSDate.distantPast compare:lastStart[best[@"bid"]] ?: NSDate.distantPast] == NSOrderedDescending))
                        best = f;
                // 2) иначе — кто последним начал играть или кем последним управляли с острова
                if (!best) {
                    NSArray *sorted = [found sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                        NSDate *la = lastStart[a[@"bid"]] ?: NSDate.distantPast, *lb = lastStart[b[@"bid"]] ?: NSDate.distantPast;
                        NSComparisonResult r = [lb compare:la];
                        if (r != NSOrderedSame) return r;
                        BOOL pa = rateOf(a[@"info"]) > 0, pb = rateOf(b[@"info"]) > 0;
                        if (pa != pb) return pa ? NSOrderedAscending : NSOrderedDescending;
                        BOOL ma = !isVideoApp(a[@"bid"]), mb = !isVideoApp(b[@"bid"]);
                        if (ma != mb) return ma ? NSOrderedAscending : NSOrderedDescending;
                        BOOL ea = [a[@"pid"] intValue] == electedPid, eb = [b[@"pid"] intValue] == electedPid;
                        if (ea != eb) return ea ? NSOrderedAscending : NSOrderedDescending;
                        return NSOrderedSame;
                    }];
                    best = sorted.firstObject;
                }
                curBid = best[@"bid"];
                curPid = [best[@"pid"] intValue];
                curElected = curPid == electedPid;
                publish(best[@"info"], curPid, curBid, curElected);
                busy = NO;
            });
        });
    });
}

static void command(int c, NSString *name, int pid) {
    NSString *bid = curBid; int target = curPid; BOOL elected = curElected;
    if (pid > 0 && pid != curPid) {                           // команда конкретному плееру из раздельной карточки
        bid = nil;
        for (NSDictionary *f in lastFound) if ([f[@"pid"] intValue] == pid) bid = f[@"bid"];
        if (!bid) return;
        target = pid;
        elected = target == electedPidCache;
    }
    if (bid.length) lastStart[bid] = NSDate.date;            // управляли с острова — этот плеер остаётся выбранным
    if (elected || !bid.length) sendCommand(c, NULL);
    else emit(@{ @"direct": name, @"pid": @(target), @"bid": bid });
}

void island_run(void *perl, void *cv) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPID = (GetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (SendFn)dlsym(h, "MRMediaRemoteSendCommand");
    if (!getInfo || !getPID || !sendCommand) { emit(@{ @"error": @"MediaRemote недоступен" }); return; }
    // Список всех плееров — необязательно: нет его — работаем через выбор системы.
    getClients = (GetClientsFn)dlsym(h, "MRMediaRemoteGetNowPlayingClients");
    localOrigin = (GetOriginFn)dlsym(h, "MRMediaRemoteGetLocalOrigin");
    clientBundle = (ClientBundleFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    clientPID = (ClientPIDFn)dlsym(h, "MRNowPlayingClientGetProcessIdentifier");
    infoForPlayer = (InfoForPlayerFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    playerPathClass = NSClassFromString(@"MRPlayerPath");
    if (!localOrigin || !clientBundle || !clientPID ||
        ![playerPathClass instancesRespondToSelector:NSSelectorFromString(@"initWithOrigin:client:player:")])
        playerPathClass = nil;
    lastStart = [NSMutableDictionary dictionary];
    lastRate = [NSMutableDictionary dictionary];

    q = dispatch_queue_create("macisland.nowplaying", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 700 * NSEC_PER_MSEC, 150 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ poll(); });
    dispatch_resume(t);

    char line[64];
    while (fgets(line, sizeof line, stdin)) {
        int c = -1; NSString *name = nil;
        if (!strncmp(line, "toggle", 6)) { c = 2; name = @"toggle"; }      // kMRTogglePlayPause
        else if (!strncmp(line, "next", 4)) { c = 4; name = @"next"; }     // kMRNextTrack
        else if (!strncmp(line, "prev", 4)) { c = 5; name = @"prev"; }     // kMRPreviousTrack
        int pid = 0;
        const char *sp = strchr(line, ' ');
        if (sp) pid = atoi(sp + 1);
        if (c >= 0) {
            dispatch_async(q, ^{ command(c, name, pid); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), q, ^{ poll(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), q, ^{ poll(); });
        }
    }
    exit(0);   // MacIsland закрылся — труба оборвалась
}
