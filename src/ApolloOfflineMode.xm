// ApolloOfflineMode.xm
//
// Offline Mode ("offline mode similar to TikTok", r/ApolloReborn): pick a data
// limit and some feeds, download a batch while you have a connection, then
// scroll it on a flight or underground, comments and images included.
//
// How Apollo ends up showing saved content with no changes to its UI:
//   • ApolloOfflineURLProtocol is added to every NSURLSession as it's created
//     (RedditKit's archived AFNetworking client, PINRemoteImage, the media
//     helpers) and registered globally for the shared session.
//   • While serving (ApolloOfflineShouldServe: Automatic + no connection, or
//     Always), the protocol claims a GET only when the library has an entry
//     for its key (ApolloOfflineKeyForURL) and answers it from disk with a
//     200. Everything else, including every write, goes to the network as
//     usual, so a miss behaves exactly as it does today.
//   • When not serving, +canInitWithRequest: returns NO after one atomic
//     load, so online behaviour and cost are unchanged.
//
// Not covered: video playback. AVFoundation fetches HLS variants and
// segments with its own HTTP stack, which URL protocols never see; offline a
// video post shows its saved poster and Apollo's normal playback error.

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <netinet/in.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloOfflineMode.h"
#import "ApolloOfflineDownloader.h"
#import "UserDefaultConstants.h"

NSNotificationName const ApolloOfflineModeDidChangeNotification = @"ApolloOfflineModeDidChangeNotification";

// Marks the downloader's own requests so the protocol never answers them.
static NSString *const kApolloOfflineBypassKey = @"ApolloOfflineBypass";

static atomic_bool sApolloOfflineServing = false;
#if APOLLO_SIM_BUILD
// Sim-only: APOLLO_OFFLINE_SIMULATE_NO_NETWORK=1 makes the app behave as if
// the device were in airplane mode (connectivity reads as down and every
// request the library can't answer fails with "not connected"), so the
// automatic path can be exercised on a Mac whose network stays up.
static BOOL sApolloOfflineSimulateNoNetwork = NO;
#endif

@interface ApolloOfflineModeController ()
- (void)recompute;
- (void)networkChanged:(BOOL)available;
- (void)startMonitoring;
@end

// MARK: - URL protocol

@interface ApolloOfflineURLProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@property (nonatomic, strong) NSThread *clientThread;
@property (nonatomic, copy) NSArray<NSString *> *clientModes;
@end

@implementation ApolloOfflineURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!atomic_load_explicit(&sApolloOfflineServing, memory_order_relaxed)) return NO;
    if (![request.HTTPMethod ?: @"GET" isEqualToString:@"GET"]) return NO;
    if ([NSURLProtocol propertyForKey:kApolloOfflineBypassKey inRequest:request]) return NO;
    NSString *key = ApolloOfflineKeyForURL(request.URL);
    if (key && [[ApolloOfflineLibrary sharedLibrary] hasEntryForKey:key]) return YES;
#if APOLLO_SIM_BUILD
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (sApolloOfflineSimulateNoNetwork && ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return YES;
#endif
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    self.clientThread = NSThread.currentThread;
    NSString *mode = NSRunLoop.currentRunLoop.currentMode;
    self.clientModes = mode ? @[ NSRunLoopCommonModes, mode ] : @[ NSRunLoopCommonModes ];
    NSURLRequest *request = self.request;
    NSString *key = ApolloOfflineKeyForURL(request.URL);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *type = nil;
        NSData *data = key ? [[ApolloOfflineLibrary sharedLibrary] dataForKey:key contentType:&type] : nil;
        if (!data) {
            // Only the first two path segments: later ones can be usernames.
            NSArray *segments = [request.URL.path componentsSeparatedByString:@"/"];
            NSString *shortPath = segments.count > 3 ? [[segments subarrayWithRange:NSMakeRange(0, 3)] componentsJoinedByString:@"/"] : request.URL.path;
            ApolloLog(@"[Offline] miss %@ (%@://%@%@)", key ?: @"(no key)", request.URL.scheme ?: @"?", request.URL.host ?: @"?",
                      ApolloOfflineURLIsRedditAPI(request.URL) ? (shortPath ?: @"") : @"");
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:@{
                NSURLErrorFailingURLErrorKey: request.URL,
                NSLocalizedDescriptionKey: @"This isn't in your offline library.",
            }];
            [self onClientThread:^{ [self.client URLProtocol:self didFailWithError:error]; }];
            return;
        }
        ApolloLog(@"[Offline] served %@ (%lu bytes)", key, (unsigned long)data.length);
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{
            @"Content-Type": type ?: @"application/octet-stream",
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
            @"Cache-Control": @"no-store",
            @"X-Apollo-Offline": @"1",
        }];
        [self onClientThread:^{
            [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self.client URLProtocol:self didLoadData:data];
            [self.client URLProtocolDidFinishLoading:self];
        }];
    });
}

- (void)stopLoading {
    self.stopped = YES;
}

// Client callbacks must run on the thread that called -startLoading.
- (void)onClientThread:(dispatch_block_t)block {
    [self performSelector:@selector(apollo_runClientBlock:) onThread:self.clientThread
               withObject:[block copy] waitUntilDone:NO modes:self.clientModes];
}

- (void)apollo_runClientBlock:(dispatch_block_t)block {
    if (!self.stopped) block();
}

@end

// A copy of `configuration` with the offline protocol first, or the original
// when it already has it or is a background configuration (those can't run
// custom protocols).
static NSURLSessionConfiguration *ApolloOfflineConfigurationWithProtocol(NSURLSessionConfiguration *configuration) {
    if (!configuration || configuration.identifier.length > 0) return configuration;
    NSArray *existing = configuration.protocolClasses ?: @[];
    if ([existing containsObject:[ApolloOfflineURLProtocol class]]) return configuration;
    NSURLSessionConfiguration *copy = [configuration copy];
    NSMutableArray *protocols = [NSMutableArray arrayWithArray:existing];
    [protocols insertObject:[ApolloOfflineURLProtocol class] atIndex:0];
    copy.protocolClasses = protocols;
    return copy;
}

// Hooked at session creation, not at +defaultSessionConfiguration: Apollo's
// RedditKit client is an AFHTTPSessionManager restored from the account
// archive, whose configuration is decoded rather than built from
// +defaultSessionConfiguration (verified in the sim: its comment and listing
// reads never reached a config-hooked protocol). Every session is created
// here, so this covers the archived client, PINRemoteImage and the rest.
%hook NSURLSession

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    return %orig(ApolloOfflineConfigurationWithProtocol(configuration));
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    return %orig(ApolloOfflineConfigurationWithProtocol(configuration), delegate, queue);
}

%end

// MARK: - Connectivity

static BOOL ApolloOfflineFlagsMeanOnline(SCNetworkReachabilityFlags flags) {
    if (!(flags & kSCNetworkReachabilityFlagsReachable)) return NO;
    // "Connection required" without on-demand/on-traffic means nothing is up yet.
    if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) &&
        !(flags & (kSCNetworkReachabilityFlagsConnectionOnDemand | kSCNetworkReachabilityFlagsConnectionOnTraffic))) {
        return NO;
    }
    return YES;
}

static void ApolloOfflineReachabilityChanged(__unused SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    ApolloOfflineModeController *controller = (__bridge ApolloOfflineModeController *)info;
    [controller networkChanged:ApolloOfflineFlagsMeanOnline(flags)];
}

// MARK: - Controller

@implementation ApolloOfflineModeController {
    SCNetworkReachabilityRef _reachability;
    ApolloOfflineDownloader *_downloader;
    UIBackgroundTaskIdentifier _backgroundTask;
    BOOL _restoreIdleTimer;
}

+ (instancetype)sharedController {
    static ApolloOfflineModeController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [ApolloOfflineModeController new]; });
    return controller;
}

- (instancetype)init {
    if ((self = [super init])) {
        _networkAvailable = YES;
        _progressText = @"";
        _backgroundTask = UIBackgroundTaskInvalid;
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            UDKeyOfflineUseMode: @(ApolloOfflineUseModeAutomatic),
            UDKeyOfflineIncludeHome: @YES,
            UDKeyOfflineIncludePopular: @NO,
            UDKeyOfflineIncludeComments: @YES,
            UDKeyOfflineIncludeImages: @YES,
            UDKeyOfflineBudgetMB: @100,
        }];
    }
    return self;
}

- (void)startMonitoring {
    if (_reachability) return;
    struct sockaddr_in zero;
    memset(&zero, 0, sizeof(zero));
    zero.sin_len = sizeof(zero);
    zero.sin_family = AF_INET;
    _reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zero);
    if (_reachability) {
        SCNetworkReachabilityContext context = { 0, (__bridge void *)self, NULL, NULL, NULL };
        SCNetworkReachabilitySetCallback(_reachability, ApolloOfflineReachabilityChanged, &context);
        SCNetworkReachabilitySetDispatchQueue(_reachability, dispatch_get_main_queue());
        SCNetworkReachabilityFlags flags = 0;
        if (SCNetworkReachabilityGetFlags(_reachability, &flags)) {
            _networkAvailable = ApolloOfflineFlagsMeanOnline(flags);
        }
    }
#if APOLLO_SIM_BUILD
    if (sApolloOfflineSimulateNoNetwork) _networkAvailable = NO;
#endif
    [self recompute];
}

- (void)networkChanged:(BOOL)available {
#if APOLLO_SIM_BUILD
    if (sApolloOfflineSimulateNoNetwork) available = NO;
#endif
    if (available == _networkAvailable) return;
    _networkAvailable = available;
    ApolloLog(@"[Offline] connectivity: %@", available ? @"online" : @"offline");
    [self recompute];
}

- (ApolloOfflineUseMode)useMode {
    NSInteger raw = [NSUserDefaults.standardUserDefaults integerForKey:UDKeyOfflineUseMode];
    return (raw >= ApolloOfflineUseModeAutomatic && raw <= ApolloOfflineUseModeNever) ? (ApolloOfflineUseMode)raw : ApolloOfflineUseModeAutomatic;
}

- (void)setUseMode:(ApolloOfflineUseMode)useMode {
    [NSUserDefaults.standardUserDefaults setInteger:useMode forKey:UDKeyOfflineUseMode];
    [self recompute];
}

- (void)recompute {
    BOOL serve = ApolloOfflineShouldServe(self.useMode, _networkAvailable,
                                          [ApolloOfflineLibrary sharedLibrary].hasContent, _downloading);
    BOOL was = atomic_exchange(&sApolloOfflineServing, serve);
    _serving = serve;
    if (was != serve) {
        ApolloLog(@"[Offline] %@ the offline library (mode=%ld, network=%d)", serve ? @"serving" : @"stopped serving",
                  (long)self.useMode, _networkAvailable);
    }
    [self postChange];
}

- (void)postChange {
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:ApolloOfflineModeDidChangeNotification object:self];
    };
    if (NSThread.isMainThread) post(); else dispatch_async(dispatch_get_main_queue(), post);
}

// MARK: Download

- (NSArray<ApolloOfflineFeedSource *> *)plannedSources {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<ApolloOfflineFeedSource *> *sources = [NSMutableArray array];
    if ([defaults boolForKey:UDKeyOfflineIncludeHome]) {
        [sources addObject:[ApolloOfflineFeedSource sourceWithPath:@"/best" title:@"Home"]];
    }
    if ([defaults boolForKey:UDKeyOfflineIncludePopular]) {
        [sources addObject:[ApolloOfflineFeedSource sourceWithPath:@"/r/popular/hot" title:@"r/popular"]];
    }
    id subs = [defaults objectForKey:UDKeyOfflineSubreddits];
    for (id sub in ([subs isKindOfClass:[NSArray class]] ? subs : @[])) {
        if (![sub isKindOfClass:[NSString class]] || [sub length] == 0) continue;
        [sources addObject:[ApolloOfflineFeedSource sourceWithPath:[NSString stringWithFormat:@"/r/%@/hot", sub]
                                                             title:[@"r/" stringByAppendingString:sub]]];
    }
    return sources;
}

- (NSArray<NSString *> *)plannedFeedTitles {
    return [[self plannedSources] valueForKey:@"title"];
}

- (unsigned long long)budgetBytes {
    // Decimal megabytes, matching how NSByteCountFormatter shows the result.
    NSInteger mb = MAX(10, [NSUserDefaults.standardUserDefaults integerForKey:UDKeyOfflineBudgetMB]);
    return (unsigned long long)mb * 1000 * 1000;
}

static NSURLSession *ApolloOfflineDownloadSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // From the hooked default configuration on purpose: the request
        // chokepoint (Tweak.xm) still stamps the User-Agent and applies the
        // Web JSON / API-key-free routing to these reads.
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30;
        configuration.HTTPMaximumConnectionsPerHost = 4;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

- (void)endDownloadSideEffects {
    if (_restoreIdleTimer) UIApplication.sharedApplication.idleTimerDisabled = NO;
    _restoreIdleTimer = NO;
    if (_backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:_backgroundTask];
        _backgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)startDownloadWithCompletion:(void (^)(BOOL, NSString *))completion {
    if (_downloading) return;
    NSArray<ApolloOfflineFeedSource *> *sources = [self plannedSources];
    if (sources.count == 0) {
        if (completion) completion(NO, @"Choose at least one feed to download.");
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    ApolloOfflineDownloadOptions *options = [ApolloOfflineDownloadOptions new];
    options.sources = sources;
    options.byteBudget = self.budgetBytes;
    options.includeComments = [defaults boolForKey:UDKeyOfflineIncludeComments];
    options.includeImages = [defaults boolForKey:UDKeyOfflineIncludeImages];
    CGFloat screenPixels = UIScreen.mainScreen.nativeBounds.size.width;
    options.maxImageWidth = (NSInteger)MIN(1440, MAX(640, screenPixels));

    ApolloOfflineFetcher fetcher = ^(NSURLRequest *request, ApolloOfflineFetchCompletion done) {
        NSMutableURLRequest *marked = [request mutableCopy];
        [NSURLProtocol setProperty:@YES forKey:kApolloOfflineBypassKey inRequest:marked];
        [[ApolloOfflineDownloadSession() dataTaskWithRequest:marked completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            done(data, [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil, error);
        }] resume];
    };
    ApolloOfflineRequestBuilder builder = ^NSURLRequest *(NSString *path, NSArray<NSURLQueryItem *> *query) {
        // Same auth rule as the other tweak-authored reads: the active
        // account's bearer on oauth.reddit.com, else bearer-less to
        // www.reddit.com, where the chokepoint signs it with the web session.
        NSString *bearer = ApolloActiveAccountRedditBearerToken();
        NSString *base = bearer.length > 0 ? @"https://oauth.reddit.com" : @"https://www.reddit.com";
        NSString *suffix = bearer.length > 0 ? @"" : @".json";
        NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"%@%@%@", base, path, suffix]];
        components.queryItems = query;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
        if (bearer.length > 0) [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
        return request;
    };

    _downloader = [[ApolloOfflineDownloader alloc] initWithLibraryDirectory:[ApolloOfflineLibrary defaultDirectory]
                                                                    fetcher:fetcher requestBuilder:builder];
    _downloading = YES;
    _progressBytes = 0;
    _progressText = @"Starting…";
    // Downloads only run while Apollo is open: keep the screen on and ask for
    // a little background time if the user switches away.
    _restoreIdleTimer = !UIApplication.sharedApplication.idleTimerDisabled;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    __weak typeof(self) weakSelf = self;
    _backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ApolloOfflineDownload" expirationHandler:^{
        ApolloLog(@"[Offline] background time ran out; cancelling download");
        [weakSelf cancelDownload];
    }];
    ApolloLog(@"[Offline] download start: %@, budget %llu MB, comments=%d images=%d",
              [[sources valueForKey:@"title"] componentsJoinedByString:@", "], options.byteBudget / (1000 * 1000),
              options.includeComments, options.includeImages);
    [self recompute];

    [_downloader startWithOptions:options progress:^(unsigned long long bytes, __unused NSUInteger posts, NSString *status) {
        ApolloOfflineModeController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_progressBytes = bytes;
        strongSelf->_progressText = [NSString stringWithFormat:@"%@ · %@", status,
                                     [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile]];
        [strongSelf postChange];
    } completion:^(BOOL committed, NSUInteger posts, unsigned long long bytes, NSError *error) {
        ApolloOfflineModeController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_downloading = NO;
        strongSelf->_downloader = nil;
        strongSelf->_progressText = @"";
        [strongSelf endDownloadSideEffects];
        [[ApolloOfflineLibrary sharedLibrary] reload];
        NSString *message;
        if (committed) {
            message = [NSString stringWithFormat:@"Saved %lu posts (%@) for offline reading.", (unsigned long)posts,
                       [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile]];
            ApolloLog(@"[Offline] download done: %lu posts, %llu bytes", (unsigned long)posts, bytes);
        } else {
            message = error.localizedDescription ?: @"The download didn't finish.";
            ApolloLog(@"[Offline] download ended without saving: %@ (%@ %ld)", message, error.domain, (long)error.code);
        }
        [strongSelf recompute];
        if (completion) completion(committed, message);
    }];
}

- (void)cancelDownload {
    [_downloader cancel];
}

- (void)deleteLibrary {
    if (_downloading) return;
    NSError *error = nil;
    if (![[ApolloOfflineLibrary sharedLibrary] removeAll:&error]) {
        ApolloLogError(@"[Offline] couldn't delete the library: %@", error);
    }
    [self recompute];
}

- (NSString *)librarySummary {
    ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
    if (!library.hasContent) return @"Not downloaded";
    NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)library.totalBytes countStyle:NSByteCountFormatterCountStyleFile];
    NSString *when = @"";
    if (library.downloadedAt) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.doesRelativeDateFormatting = YES;
        when = [@" · " stringByAppendingString:[formatter stringFromDate:library.downloadedAt]];
    }
    return [NSString stringWithFormat:@"%lu posts · %@%@", (unsigned long)library.postCount, size, when];
}

@end

%ctor {
    %init;
#if APOLLO_SIM_BUILD
    sApolloOfflineSimulateNoNetwork = [NSProcessInfo.processInfo.environment[@"APOLLO_OFFLINE_SIMULATE_NO_NETWORK"] isEqualToString:@"1"];
#endif
    [NSURLProtocol registerClass:[ApolloOfflineURLProtocol class]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ApolloOfflineModeController sharedController] startMonitoring];
        ApolloOfflineLibrary *library = [ApolloOfflineLibrary sharedLibrary];
        ApolloLog(@"[Offline] ready: library %@, mode %ld",
                  library.hasContent ? [NSString stringWithFormat:@"%lu posts", (unsigned long)library.postCount] : @"empty",
                  (long)[ApolloOfflineModeController sharedController].useMode);
    });
}
