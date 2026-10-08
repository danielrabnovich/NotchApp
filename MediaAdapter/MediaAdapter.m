// Tiny bridge to the private MediaRemote framework.
// Loaded into /usr/bin/perl (which Apple still entitles for MediaRemote on macOS 15.4+).
// Streams now-playing state as JSON lines on stdout, or sends a single command.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));

static void *MR(void) {
    static void *h;
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return h;
}

static NSString *lastArtworkHash;

static void emit(NSDictionary *obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return;
    fwrite(d.bytes, 1, d.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void) {
    GetInfoFn getInfo = (GetInfoFn)dlsym(MR(), "MRMediaRemoteGetNowPlayingInfo");
    GetClientFn getClient = (GetClientFn)dlsym(MR(), "MRMediaRemoteGetNowPlayingClient");
    GetIsPlayingFn getPlaying = (GetIsPlayingFn)dlsym(MR(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    dispatch_queue_t q = dispatch_get_main_queue();

    getClient(q, ^(id client) {
        NSString *bundle = nil, *appName = nil;
        if (client) {
            if ([client respondsToSelector:@selector(bundleIdentifier)]) bundle = [client performSelector:@selector(bundleIdentifier)];
            if ([client respondsToSelector:@selector(parentApplicationBundleIdentifier)]) {
                NSString *parent = [client performSelector:@selector(parentApplicationBundleIdentifier)];
                if (parent.length) bundle = parent;
            }
            if ([client respondsToSelector:@selector(displayName)]) appName = [client performSelector:@selector(displayName)];
        }
        getPlaying(q, ^(Boolean playing) {
            getInfo(q, ^(CFDictionaryRef ref) {
                NSDictionary *info = (__bridge NSDictionary *)ref;
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing);
                if (bundle) out[@"bundle"] = bundle;
                if (appName) out[@"app"] = appName;
                if (info) {
                    id v;
                    if ((v = info[@"kMRMediaRemoteNowPlayingInfoTitle"])) out[@"title"] = v;
                    if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"])) out[@"artist"] = v;
                    if ((v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"])) out[@"album"] = v;
                    if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"])) out[@"duration"] = v;
                    if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) out[@"elapsed"] = v;
                    if ((v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) out[@"rate"] = v;
                    NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([ts isKindOfClass:NSDate.class]) out[@"timestamp"] = @(ts.timeIntervalSince1970);
                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([art isKindOfClass:NSData.class] && art.length) {
                        NSString *hash = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash];
                        out[@"artworkId"] = hash;
                        if (![hash isEqualToString:lastArtworkHash]) {
                            lastArtworkHash = hash;
                            out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                        }
                    } else {
                        // Players drop the artwork while paused; send it again when it comes back.
                        lastArtworkHash = nil;
                    }
                }
                emit(out);
            });
        });
    });
}

void adapter_stream(void) {
    @autoreleasepool {
        RegisterFn reg = (RegisterFn)dlsym(MR(), "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!reg) { emit(@{@"error": @"MediaRemote unavailable"}); return; }
        reg(dispatch_get_main_queue());
        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
                           @"kMRMediaRemotePlayerPlaybackStateDidChangeNotification"];
        __block BOOL pending = NO;
        for (NSString *n in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (pending) return;               // coalesce bursts
                pending = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    pending = NO;
                    refresh();
                });
            }];
        }
        refresh();
        CFRunLoopRun();
    }
}

// Command from env: NOTCH_MR_CMD = integer MRCommand, or NOTCH_MR_SEEK = seconds.
void adapter_send(void) {
    @autoreleasepool {
        const char *seek = getenv("NOTCH_MR_SEEK");
        if (seek) {
            SetElapsedFn setElapsed = (SetElapsedFn)dlsym(MR(), "MRMediaRemoteSetElapsedTime");
            if (setElapsed) setElapsed(atof(seek));
        }
        const char *cmd = getenv("NOTCH_MR_CMD");
        if (cmd) {
            SendCommandFn send = (SendCommandFn)dlsym(MR(), "MRMediaRemoteSendCommand");
            if (send) send(atoi(cmd), nil);
        }
        // Let the XPC message flush before perl exits.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.15, false);
    }
}
