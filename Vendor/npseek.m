#import <Foundation/Foundation.h>
#import <dlfcn.h>

// Loaded by /usr/bin/perl (an Apple-signed process allowed to talk to MediaRemote).
// The target position, in seconds, comes from the environment variable NP_SEEK_SECONDS.

typedef void (^MRReplyBlock)(Boolean);
typedef void (*SendCommandFn)(int command, NSDictionary *options, dispatch_queue_t queue, void (^reply)(NSArray *));
typedef void (*SetElapsedFn)(double seconds);

static void *handle(void) {
    static void *h;
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    return h;
}

static double target(void) {
    const char *s = getenv("NP_SEEK_SECONDS");
    return s ? atof(s) : 0;
}

// kMRMediaRemoteCommandChangePlaybackPosition = 24, with the position as an option
void np_seek_command(void) {
    SendCommandFn f = (SendCommandFn)dlsym(handle(), "MRMediaRemoteSendCommand");
    if (!f) { fprintf(stderr, "no MRMediaRemoteSendCommand\n"); exit(2); }
    __block BOOL done = NO;
    NSDictionary *opts = @{ @"kMRMediaRemoteOptionPlaybackPosition": @(target()) };
    f(24, opts, dispatch_get_main_queue(), ^(NSArray *errors) { fprintf(stderr, "reply: %s\n", errors.count ? errors.description.UTF8String : "ok"); done = YES; });
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:1.5];
    while (!done && [end timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

void np_seek_set(void) {
    SetElapsedFn f = (SetElapsedFn)dlsym(handle(), "MRMediaRemoteSetElapsedTime");
    if (!f) { fprintf(stderr, "no MRMediaRemoteSetElapsedTime\n"); exit(2); }
    f(target());
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
}
