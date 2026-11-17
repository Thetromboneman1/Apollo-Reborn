// Host tests for src/ApolloOfflineLibrary.m and src/ApolloOfflineDownloader.m
// (tests/run_offline_library_tests.sh). All Reddit JSON here is synthetic,
// shaped like real listing/comments responses with made-up ids and URLs.
#import <Foundation/Foundation.h>
#import "ApolloOfflineLibrary.h"
#import "ApolloOfflineDownloader.h"

static int sFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSString *Key(NSString *url) {
    return ApolloOfflineKeyForURL([NSURL URLWithString:url]);
}

static void TestFeedKeys(void) {
    CHECK([ApolloOfflineFeedKeyForPath(@"") isEqualToString:@"home"], "empty path");
    CHECK([ApolloOfflineFeedKeyForPath(@"/") isEqualToString:@"home"], "root");
    CHECK([ApolloOfflineFeedKeyForPath(@"/best") isEqualToString:@"home"], "best");
    CHECK([ApolloOfflineFeedKeyForPath(@"/hot.json") isEqualToString:@"home"], "hot.json");
    CHECK([ApolloOfflineFeedKeyForPath(@"/r/Pics") isEqualToString:@"r/pics"], "sub lowercased");
    CHECK([ApolloOfflineFeedKeyForPath(@"/r/pics/top/") isEqualToString:@"r/pics"], "sub sort");
    CHECK([ApolloOfflineFeedKeyForPath(@"/r/popular/hot.json") isEqualToString:@"r/popular"], "popular");
    CHECK([ApolloOfflineFeedKeyForPath(@"/user/Bob/m/Cats/new") isEqualToString:@"m/bob/cats"], "multi");
    CHECK(ApolloOfflineFeedKeyForPath(@"/r/pics/about") == nil, "about isn't a feed");
    CHECK(ApolloOfflineFeedKeyForPath(@"/api/v1/me") == nil, "api isn't a feed");
    CHECK(ApolloOfflineFeedKeyForPath(@"/user/bob/submitted") == nil, "profile isn't a feed");
}

static void TestURLKeys(void) {
    // Apollo's own request and the downloader's land on the same key whatever
    // the host, sort, limit or raw_json.
    CHECK([Key(@"https://oauth.reddit.com/hot?limit=25&raw_json=1") isEqualToString:@"feed:home|"], "%s", Key(@"https://oauth.reddit.com/hot?limit=25").UTF8String);
    CHECK([Key(@"https://www.reddit.com/best.json?limit=50&raw_json=1") isEqualToString:@"feed:home|"], "www json");
    CHECK([Key(@"https://oauth.reddit.com/r/Pics/new?after=t3_ABC&count=25") isEqualToString:@"feed:r/pics|t3_abc"], "after");
    CHECK([Key(@"https://oauth.reddit.com/comments/abc12?sort=top&limit=200") isEqualToString:@"comments:abc12"], "comments");
    CHECK([Key(@"https://www.reddit.com/r/pics/comments/abc12/a_title/.json") isEqualToString:@"comments:abc12"], "sub comments");
    CHECK(Key(@"https://oauth.reddit.com/r/pics/comments") == nil, "comment stream isn't a post");
    CHECK(Key(@"https://oauth.reddit.com/api/v1/me") == nil, "api");
    CHECK([Key(@"https://preview.redd.it/xyz98.jpg?width=640&format=pjpg&s=1") isEqualToString:@"reddimg:xyz98"], "preview");
    CHECK([Key(@"https://i.redd.it/xyz98.jpeg") isEqualToString:@"reddimg:xyz98"], "same image direct");
    CHECK([Key(@"https://external-preview.redd.it/Ab-Cd.png?auto=webp&s=2") isEqualToString:@"extimg:Ab-Cd"], "external preview");
    CHECK([Key(@"https://i.imgur.com/qwe.jpg?1") isEqualToString:@"url:i.imgur.com/qwe.jpg"], "imgur");
    CHECK(Key(@"video-player://v.redd.it/x") == nil, "custom scheme");
}

static void TestPolicy(void) {
    CHECK(ApolloOfflineShouldServe(ApolloOfflineUseModeAutomatic, NO, YES, NO), "auto offline");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeAutomatic, YES, YES, NO), "auto online");
    CHECK(ApolloOfflineShouldServe(ApolloOfflineUseModeAlways, YES, YES, NO), "always");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeNever, NO, YES, NO), "never");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeAlways, NO, NO, NO), "no library");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeAlways, NO, YES, YES), "paused while downloading");
}

static NSDictionary *PostData(NSString *postID) {
    return @{
        @"id": postID,
        @"name": [@"t3_" stringByAppendingString:postID],
        @"url": [NSString stringWithFormat:@"https://i.redd.it/%@.jpg", postID],
        @"thumbnail": [NSString stringWithFormat:@"https://b.thumbs.redditmedia.com/%@.jpg", postID],
        @"preview": @{ @"images": @[ @{
            @"source": @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=3000&amp;s=src", postID], @"width": @3000 },
            @"resolutions": @[
                @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=640&s=a", postID], @"width": @640 },
                @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=1080&s=b", postID], @"width": @1080 },
                @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=2160&s=c", postID], @"width": @2160 },
            ],
        } ] },
    };
}

static void TestImageURLs(void) {
    NSArray<NSURL *> *urls = ApolloOfflineImageURLsForPost(PostData(@"p1"), 1080);
    CHECK(urls.count == 2, "preview + thumbnail, direct link deduped: %lu", (unsigned long)urls.count);
    CHECK([urls.firstObject.absoluteString containsString:@"width=1080"], "largest within limit: %s", urls.firstObject.absoluteString.UTF8String);

    NSDictionary *small = PostData(@"p2");
    urls = ApolloOfflineImageURLsForPost(small, 320);
    CHECK([urls.firstObject.absoluteString containsString:@"width=3000"] && ![urls.firstObject.absoluteString containsString:@"&amp;"],
          "falls back to unescaped source: %s", urls.firstObject.absoluteString.UTF8String);

    NSDictionary *gallery = @{
        @"id": @"g1",
        @"thumbnail": @"self",
        @"gallery_data": @{ @"items": @[ @{ @"media_id": @"m2" }, @{ @"media_id": @"m1" } ] },
        @"media_metadata": @{
            @"m1": @{ @"status": @"valid", @"e": @"Image", @"s": @{ @"u": @"https://preview.redd.it/m1.jpg?width=2000" },
                      @"p": @[ @{ @"u": @"https://preview.redd.it/m1.jpg?width=960", @"x": @960 } ] },
            @"m2": @{ @"status": @"valid", @"e": @"Image", @"s": @{ @"u": @"https://preview.redd.it/m2.jpg?width=900" } },
            @"m3": @{ @"status": @"failed" },
        },
    };
    urls = ApolloOfflineImageURLsForPost(gallery, 1080);
    CHECK(urls.count == 2, "two valid gallery images, 'self' thumbnail skipped: %lu", (unsigned long)urls.count);
    CHECK([urls[0].absoluteString containsString:@"m2"] && [urls[1].absoluteString containsString:@"width=960"], "gallery order and resolution");

    NSDictionary *crosspost = @{ @"id": @"x1", @"crosspost_parent_list": @[ PostData(@"p9") ] };
    CHECK(ApolloOfflineImageURLsForPost(crosspost, 1080).count == 2, "crosspost parent images");
}

static NSData *JSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

static NSData *ListingData(NSArray<NSString *> *ids, NSString *after) {
    NSMutableArray *children = [NSMutableArray array];
    for (NSString *postID in ids) [children addObject:@{ @"kind": @"t3", @"data": PostData(postID) }];
    return JSON(@{ @"kind": @"Listing", @"data": @{ @"after": after ?: [NSNull null], @"dist": @(ids.count), @"children": children } });
}

static void TestTruncate(void) {
    NSData *truncated = ApolloOfflineTruncatedListing(ListingData(@[ @"a", @"b", @"c" ], @"t3_c"), 2, YES);
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:truncated options:0 error:nil];
    CHECK([root[@"data"][@"children"] count] == 2, "kept two");
    CHECK(root[@"data"][@"after"] == [NSNull null], "after cleared");
    CHECK(ApolloOfflineTruncatedListing(JSON(@[ @1 ]), 1, YES) == nil, "not a listing");
}

static NSURL *TempDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"apollo-offline-tests-%@", NSUUID.UUID.UUIDString]];
    return [[NSURL fileURLWithPath:path isDirectory:YES] URLByAppendingPathComponent:@"OfflineLibrary" isDirectory:YES];
}

static void TestWriterAndLibrary(void) {
    NSURL *dir = TempDirectory();
    ApolloOfflineLibraryWriter *writer = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:dir error:nil];
    CHECK([writer storeData:[@"one" dataUsingEncoding:NSUTF8StringEncoding] contentType:@"text/plain" forKey:@"k1"], "store");
    CHECK([writer storeData:[@"twotwo" dataUsingEncoding:NSUTF8StringEncoding] contentType:@"text/plain" forKey:@"k1"], "replace");
    CHECK(writer.bytesWritten == 6, "replace doesn't double count: %llu", writer.bytesWritten);
    [writer noteFeedTitle:@"Home" posts:3];
    [writer noteFeedTitle:@"r/empty" posts:0];
    CHECK([writer commit:nil], "commit");

    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSString *type = nil;
    NSData *data = [library dataForKey:@"k1" contentType:&type];
    CHECK([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqualToString:@"twotwo"] && [type isEqualToString:@"text/plain"], "read back");
    CHECK(library.postCount == 3 && [library.feedTitles isEqualToArray:@[ @"Home" ]] && library.downloadedAt, "index metadata");

    // A second batch replaces the first atomically; a discarded one changes nothing.
    ApolloOfflineLibraryWriter *second = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:dir error:nil];
    [second storeData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] contentType:nil forKey:@"k2"];
    [second discard];
    [library reload];
    CHECK([library hasEntryForKey:@"k1"] && ![library hasEntryForKey:@"k2"], "discard keeps old batch");
    ApolloOfflineLibraryWriter *third = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:dir error:nil];
    [third storeData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] contentType:nil forKey:@"k2"];
    [third noteFeedTitle:@"Home" posts:1];
    CHECK([third commit:nil], "second commit");
    [library reload];
    CHECK(![library hasEntryForKey:@"k1"] && [library hasEntryForKey:@"k2"], "commit swaps batch");
    CHECK([library removeAll:nil] && !library.hasContent, "remove");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

// MARK: - Downloader against a fake Reddit

typedef struct {
    BOOL done;
    BOOL committed;
    NSUInteger posts;
} RunResult;

// Set by a test to give the downloader a (fake) remuxer.
static ApolloOfflineVideoMuxer sTestMuxer = nil;

static RunResult RunDownload(NSURL *dir, ApolloOfflineDownloadOptions *options, NSDictionary<NSString *, NSData *> *responses,
                             NSMutableArray<NSString *> *requested) {
    ApolloOfflineFetcher fetcher = ^(NSURLRequest *request, ApolloOfflineFetchCompletion completion) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        NSString *after = nil;
        for (NSURLQueryItem *item in c.queryItems) if ([item.name isEqualToString:@"after"]) after = item.value;
        NSString *lookup = after ? [NSString stringWithFormat:@"%@?after=%@", c.path, after] : (c.path ?: @"");
        if ([request.URL.host isEqualToString:@"v.redd.it"]) lookup = [request.URL.host stringByAppendingString:request.URL.path];
        else if ([request.URL.host hasSuffix:@"redd.it"] || [request.URL.host hasSuffix:@"redditmedia.com"]) lookup = request.URL.host;
        @synchronized (requested) { [requested addObject:lookup]; }
        NSData *body = responses[lookup];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:body ? 200 : 404 HTTPVersion:@"HTTP/1.1"
            headerFields:@{ @"Content-Type": [lookup hasPrefix:@"/"] ? @"application/json" : @"image/jpeg" }];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ completion(body, response, nil); });
    };
    ApolloOfflineRequestBuilder builder = ^NSURLRequest *(NSString *path, NSArray<NSURLQueryItem *> *query) {
        NSURLComponents *c = [NSURLComponents componentsWithString:[@"https://oauth.reddit.com" stringByAppendingString:path]];
        c.queryItems = query;
        return [NSURLRequest requestWithURL:c.URL];
    };
    ApolloOfflineDownloader *downloader = [[ApolloOfflineDownloader alloc] initWithLibraryDirectory:dir fetcher:fetcher requestBuilder:builder];
    downloader.videoMuxer = sTestMuxer;
    __block RunResult result = { NO, NO, 0 };
    [downloader startWithOptions:options progress:nil completion:^(BOOL committed, NSUInteger posts, __unused unsigned long long bytes, __unused NSError *error) {
        result.done = YES;
        result.committed = committed;
        result.posts = posts;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!result.done && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    CHECK(result.done, "download finished");
    return result;
}

static NSDictionary *ResponsesForTwoPages(void) {
    NSMutableDictionary *responses = [NSMutableDictionary dictionary];
    responses[@"/best"] = ListingData(@[ @"a1", @"a2", @"a3" ], @"t3_a3");
    responses[@"/best?after=t3_a3"] = ListingData(@[ @"b1", @"b2", @"b3" ], nil);
    for (NSString *postID in @[ @"a1", @"a2", @"a3", @"b1", @"b2", @"b3" ]) {
        responses[[@"/comments/" stringByAppendingString:postID]] = JSON(@[ @{ @"kind": @"Listing" }, @{ @"kind": @"Listing" } ]);
    }
    responses[@"preview.redd.it"] = [NSMutableData dataWithLength:1000];
    responses[@"b.thumbs.redditmedia.com"] = [NSMutableData dataWithLength:100];
    return responses;
}

static ApolloOfflineDownloadOptions *Options(unsigned long long budget) {
    ApolloOfflineDownloadOptions *options = [ApolloOfflineDownloadOptions new];
    options.sources = @[ [ApolloOfflineFeedSource sourceWithPath:@"/best" title:@"Home"] ];
    options.byteBudget = budget;
    options.apiSpacing = 0;
    return options;
}

static void TestDownloaderWholeFeed(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunResult result = RunDownload(dir, Options(100ull * 1024 * 1024), ResponsesForTwoPages(), requested);
    CHECK(result.committed && result.posts == 6, "all six posts: committed=%d posts=%lu", result.committed, (unsigned long)result.posts);

    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    // Apollo's own requests (other host, sort and params) resolve to what was saved.
    CHECK([library hasEntryForKey:Key(@"https://oauth.reddit.com/hot?limit=25&raw_json=1")], "page one");
    CHECK([library hasEntryForKey:Key(@"https://www.reddit.com/new.json?after=t3_a3")], "page two via after");
    CHECK([library hasEntryForKey:Key(@"https://oauth.reddit.com/r/x/comments/b3/slug")], "comments");
    CHECK([library hasEntryForKey:Key(@"https://i.redd.it/b2.jpg")], "image by stem");
    NSArray *saved = [library.savedPostIDs sortedArrayUsingSelector:@selector(compare:)];
    CHECK([saved isEqualToArray:(@[ @"a1", @"a2", @"a3", @"b1", @"b2", @"b3" ])], "saved post ids: %s", saved.description.UTF8String);
    NSDictionary *last = [NSJSONSerialization JSONObjectWithData:[library dataForKey:@"feed:home|t3_a3" contentType:nil] options:0 error:nil];
    CHECK(last[@"data"][@"after"] == [NSNull null] && [last[@"data"][@"children"] count] == 3, "last page ends the feed");

    // Apollo loaded page one online with a smaller page size, so its cursor is
    // a post in the middle of a saved page: serve the rest of that page.
    NSString *midKey = Key(@"https://oauth.reddit.com/best?after=t3_a1&count=1");
    CHECK([library hasEntryForKey:midKey], "mid-page cursor resolves");
    NSDictionary *rest = [NSJSONSerialization JSONObjectWithData:[library dataForKey:midKey contentType:nil] options:0 error:nil];
    NSArray *restNames = [rest[@"data"][@"children"] valueForKeyPath:@"data.name"];
    CHECK([restNames isEqualToArray:(@[ @"t3_a2", @"t3_a3" ])] && [rest[@"data"][@"after"] isEqual:@"t3_a3"],
          "rest of page keeps the chain: %s", restNames.description.UTF8String);
    // The cursor is the last post of the final page: an empty, final page.
    NSDictionary *end = [NSJSONSerialization JSONObjectWithData:[library dataForKey:@"feed:home|t3_b3" contentType:nil] options:0 error:nil];
    CHECK([end[@"data"][@"children"] count] == 0 && end[@"data"][@"after"] == [NSNull null], "end of feed");
    CHECK(![library hasEntryForKey:@"feed:r/pics|t3_a1"], "cursors are per feed");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderBudget(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    // Each post costs ~1.1 KB of images plus its comments; the post that
    // crosses 2.5 KB is still kept, then the feed stops.
    RunResult result = RunDownload(dir, Options(2500), ResponsesForTwoPages(), requested);
    CHECK(result.committed && result.posts == 3, "budget stops after crossing: posts=%lu", (unsigned long)result.posts);
    CHECK(![requested containsObject:@"/best?after=t3_a3"], "no second page fetched");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSDictionary *page = [NSJSONSerialization JSONObjectWithData:[library dataForKey:@"feed:home|" contentType:nil] options:0 error:nil];
    CHECK([page[@"data"][@"children"] count] == result.posts && page[@"data"][@"after"] == [NSNull null], "page cut to saved posts");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderFailureKeepsOldLibrary(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunDownload(dir, Options(100ull * 1024 * 1024), ResponsesForTwoPages(), requested);
    RunResult failed = RunDownload(dir, Options(100ull * 1024 * 1024), @{}, requested);
    CHECK(!failed.committed, "nothing downloaded isn't committed");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK(library.postCount == 6, "old library survives a failed refresh: %lu", (unsigned long)library.postCount);
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestRemovingReadPosts(void) {
    NSUInteger removed = 0;
    NSData *filtered = ApolloOfflineListingRemovingPosts(ListingData(@[ @"a", @"b", @"c" ], @"t3_c"), [NSSet setWithArray:@[ @"b", @"zz" ]], &removed);
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:filtered options:0 error:nil];
    CHECK(removed == 1, "one removed: %lu", (unsigned long)removed);
    CHECK([[root[@"data"][@"children"] valueForKeyPath:@"data.id"] isEqualToArray:(@[ @"a", @"c" ])], "kept order");
    CHECK([root[@"data"][@"after"] isEqual:@"t3_c"] && [root[@"data"][@"dist"] integerValue] == 2, "after kept, dist updated");
    CHECK(ApolloOfflineListingRemovingPosts(JSON(@[ @1 ]), [NSSet setWithObject:@"a"], NULL) == nil, "not a listing");
}

static void TestAutoRefreshPolicy(void) {
    ApolloOfflineAutoRefreshState s = {
        .enabled = YES, .hasLibrary = YES, .libraryAge = 61 * 60, .readFraction = 0, .networkAvailable = YES, .onWiFi = YES,
        .lowPowerMode = NO, .serving = NO, .downloading = NO, .sinceLastAttempt = 3600,
    };
    CHECK(ApolloOfflineShouldAutoRefresh(s), "stale batch on Wi-Fi refreshes");
    ApolloOfflineAutoRefreshState t = s; t.enabled = NO;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "setting off");
    t = s; t.hasLibrary = NO;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "never before a first manual download");
    t = s; t.onWiFi = NO;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "never on cellular");
    t = s; t.lowPowerMode = YES;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "never in Low Power Mode");
    t = s; t.serving = YES;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "not while the batch is being browsed");
    t = s; t.libraryAge = 30 * 60;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "half-hour-old, mostly unread batch kept");
    t.readFraction = 0.6;
    CHECK(ApolloOfflineShouldAutoRefresh(t), "mostly read batch topped up before the hour");
    t.libraryAge = 5 * 60;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "but not one that was just downloaded");
    t = s; t.sinceLastAttempt = 10 * 60;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "a failed try waits 15 minutes");
}

static void TestDownloaderSkipsReadPosts(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    // Page one is entirely read: its saved stand-in is page two, under page one's key.
    ApolloOfflineDownloadOptions *options = Options(100ull * 1024 * 1024);
    options.skipPostIDs = [NSSet setWithArray:@[ @"a1", @"a2", @"a3", @"b2" ]];
    RunResult result = RunDownload(dir, options, ResponsesForTwoPages(), requested);
    CHECK(result.committed && result.posts == 2, "two unread posts: %lu", (unsigned long)result.posts);
    CHECK(![requested containsObject:@"/comments/a1"] && ![requested containsObject:@"/comments/b2"], "read posts not downloaded");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSDictionary *first = [NSJSONSerialization JSONObjectWithData:[library dataForKey:Key(@"https://oauth.reddit.com/hot") contentType:nil] options:0 error:nil];
    CHECK([[first[@"data"][@"children"] valueForKeyPath:@"data.id"] isEqualToArray:(@[ @"b1", @"b3" ])], "page one shows the next unread posts");
    CHECK(first[@"data"][@"after"] == [NSNull null], "and ends the feed");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

// MARK: - Video and Saved

static NSData *Manifest(void) {
    NSString *mpd = @"<?xml version=\"1.0\"?><MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\"><Period>"
        "<AdaptationSet contentType=\"video\">"
        "<Representation id=\"1\" bandwidth=\"300000\" height=\"240\"><BaseURL>CMAF_240.mp4</BaseURL><SegmentBase indexRange=\"0-9\"/></Representation>"
        "<Representation id=\"2\" bandwidth=\"900000\" height=\"480\"><BaseURL>CMAF_480.mp4</BaseURL></Representation>"
        "<Representation id=\"3\" bandwidth=\"1800000\" height=\"720\"><BaseURL>CMAF_720.mp4</BaseURL></Representation>"
        "<Representation id=\"4\" bandwidth=\"4000000\" height=\"1080\"><BaseURL>CMAF_1080.mp4</BaseURL></Representation>"
        "<Representation id=\"5\" bandwidth=\"9000000\" height=\"1440\"><SegmentTemplate media=\"seg_$Number$.m4s\"/></Representation>"
        "</AdaptationSet>"
        "<AdaptationSet mimeType=\"audio/mp4\">"
        "<Representation id=\"6\" bandwidth=\"64000\"><BaseURL>CMAF_AUDIO_64.mp4</BaseURL></Representation>"
        "<Representation id=\"7\" bandwidth=\"128000\"><BaseURL>CMAF_AUDIO_128.mp4</BaseURL></Representation>"
        "</AdaptationSet></Period></MPD>";
    return [mpd dataUsingEncoding:NSUTF8StringEncoding];
}

static NSDictionary *VideoPost(NSString *postID, NSString *videoID, BOOL hasAudio) {
    NSMutableDictionary *post = [PostData(postID) mutableCopy];
    post[@"is_video"] = @YES;
    post[@"secure_media"] = @{ @"reddit_video": @{
        @"fallback_url": [NSString stringWithFormat:@"https://v.redd.it/%@/CMAF_720.mp4?source=fallback", videoID],
        @"dash_url": [NSString stringWithFormat:@"https://v.redd.it/%@/DASHPlaylist.mpd?a=1&amp;v=1&amp;f=sd", videoID],
        @"hls_url": [NSString stringWithFormat:@"https://v.redd.it/%@/HLSPlaylist.m3u8?a=1&amp;v=1&amp;f=sd", videoID],
        @"duration": @12,
        @"has_audio": @(hasAudio),
    } };
    return post;
}

static void TestVideoKeys(void) {
    CHECK([ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"https://v.redd.it/AbC123xy/HLSPlaylist.m3u8?a=1"]) isEqualToString:@"abc123xy"], "master");
    CHECK([ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"video-player://v.redd.it/abc123xy/HLSPlaylist.m3u8"]) isEqualToString:@"abc123xy"], "player scheme");
    CHECK([ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"https://v.redd.it/abc123xy/CMAF_720.mp4"]) isEqualToString:@"abc123xy"], "media file");
    CHECK(ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"https://i.redd.it/abc123xy.gif"]) == nil, "image host");
    CHECK(ApolloOfflineRedditVideoIDForURL(nil) == nil, "nil");
    CHECK([ApolloOfflineVideoKey(@"ABC123xy") isEqualToString:@"video:abc123xy"], "video key");
    CHECK([Key(@"https://v.redd.it/abc123xy/HLSPlaylist.m3u8?a=9&f=sd") isEqualToString:@"url:v.redd.it/abc123xy/HLSPlaylist.m3u8"], "master key drops query");

    CHECK([ApolloOfflineFeedKeyForPath(@"/user/Bob/saved") isEqualToString:@"saved/bob"], "saved feed");
    CHECK([Key(@"https://oauth.reddit.com/user/bob/saved?type=links&after=t3_X1") isEqualToString:@"feed:saved/bob|t3_x1"], "saved page key");
    CHECK(ApolloOfflineFeedKeyForPath(@"/user/bob/saved/extra") == nil, "not the saved list");
}

static void TestVideoForPost(void) {
    NSDictionary *video = ApolloOfflineRedditVideoForPost(VideoPost(@"p1", @"vid111", YES));
    CHECK([video[@"id"] isEqualToString:@"vid111"] && [video[@"duration"] doubleValue] == 12 && [video[@"hasAudio"] boolValue], "own video");
    CHECK([[video[@"dash"] absoluteString] isEqualToString:@"https://v.redd.it/vid111/DASHPlaylist.mpd?a=1&v=1&f=sd"], "dash unescaped: %s", [[video[@"dash"] absoluteString] UTF8String]);
    NSDictionary *crosspost = @{ @"id": @"p2", @"crosspost_parent_list": @[ VideoPost(@"p0", @"vid222", NO) ] };
    NSDictionary *parent = ApolloOfflineRedditVideoForPost(crosspost);
    CHECK([parent[@"id"] isEqualToString:@"vid222"] && ![parent[@"hasAudio"] boolValue], "crosspost parent's video");
    CHECK(ApolloOfflineRedditVideoForPost(PostData(@"p3")) == nil, "image post has none");
}

static void TestRenditions(void) {
    NSURL *manifestURL = [NSURL URLWithString:@"https://v.redd.it/vid111/DASHPlaylist.mpd?a=1&f=sd"];
    NSDictionary *r = ApolloOfflineRedditVideoRenditions(Manifest(), manifestURL, 720);
    CHECK([[r[@"video"] absoluteString] isEqualToString:@"https://v.redd.it/vid111/CMAF_720.mp4"], "720 cap: %s", [[r[@"video"] absoluteString] UTF8String]);
    CHECK([[r[@"audio"] absoluteString] isEqualToString:@"https://v.redd.it/vid111/CMAF_AUDIO_128.mp4"], "best audio");
    CHECK([r[@"videoBandwidth"] longLongValue] == 1800000 && [r[@"audioBandwidth"] longLongValue] == 128000, "bandwidths");
    NSDictionary *tiny = ApolloOfflineRedditVideoRenditions(Manifest(), manifestURL, 100);
    CHECK([[tiny[@"video"] lastPathComponent] isEqualToString:@"CMAF_240.mp4"], "nothing fits: shortest");
    NSDictionary *huge = ApolloOfflineRedditVideoRenditions(Manifest(), manifestURL, 4000);
    CHECK([[huge[@"video"] lastPathComponent] isEqualToString:@"CMAF_1080.mp4"], "segmented 1440 skipped");
    CHECK(ApolloOfflineRedditVideoRenditions([@"not xml" dataUsingEncoding:NSUTF8StringEncoding], manifestURL, 720) == nil, "garbage");
    CHECK(ApolloOfflineEstimatedBrowseTime(10, 30) == 150, "browse time");
}

static NSMutableDictionary *VideoResponses(void) {
    NSMutableDictionary *responses = [NSMutableDictionary dictionary];
    NSDictionary *listing = @{ @"kind": @"Listing", @"data": @{ @"after": [NSNull null], @"children": @[
        @{ @"kind": @"t3", @"data": VideoPost(@"v1", @"vid111", YES) },
        @{ @"kind": @"t3", @"data": PostData(@"i1") },
    ] } };
    responses[@"/best"] = JSON(listing);
    for (NSString *postID in @[ @"v1", @"i1" ]) {
        responses[[@"/comments/" stringByAppendingString:postID]] = JSON(@[ @{ @"kind": @"Listing" }, @{ @"kind": @"Listing" } ]);
    }
    responses[@"preview.redd.it"] = [NSMutableData dataWithLength:1000];
    responses[@"b.thumbs.redditmedia.com"] = [NSMutableData dataWithLength:100];
    responses[@"v.redd.it/vid111/DASHPlaylist.mpd"] = Manifest();
    responses[@"v.redd.it/vid111/CMAF_720.mp4"] = [NSMutableData dataWithLength:5000];
    responses[@"v.redd.it/vid111/CMAF_AUDIO_128.mp4"] = [NSMutableData dataWithLength:700];
    responses[@"v.redd.it/vid111/HLSPlaylist.m3u8"] = [@"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO\n" dataUsingEncoding:NSUTF8StringEncoding];
    return responses;
}

static void TestDownloaderVideo(void) {
    __block NSUInteger muxCalls = 0;
    __block BOOL sawAudio = NO;
    sTestMuxer = ^(NSURL *video, NSURL *audio, NSURL *output, void (^done)(BOOL, NSTimeInterval)) {
        muxCalls++;
        sawAudio = audio != nil;
        NSMutableData *joined = [NSMutableData dataWithContentsOfURL:video];
        if (audio) [joined appendData:[NSData dataWithContentsOfURL:audio]];
        BOOL ok = [joined writeToURL:output atomically:NO];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ done(ok, 11.5); });
    };
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunResult result = RunDownload(dir, Options(100ull * 1000 * 1000), VideoResponses(), requested);
    CHECK(result.committed && result.posts == 2, "both posts: %lu", (unsigned long)result.posts);
    CHECK(muxCalls == 1 && sawAudio, "one remux with audio (%lu)", (unsigned long)muxCalls);
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSURL *file = [library fileURLForKey:@"video:vid111"];
    NSDictionary *attributes = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    CHECK([file.pathExtension isEqualToString:@"mp4"] && attributes.fileSize == 5700, "saved mp4 with sound: %s %llu",
          file.path.UTF8String, attributes.fileSize);
    CHECK(library.videoCount == 1 && library.videoSeconds == 11.5, "video stats %lu %.1f", (unsigned long)library.videoCount, library.videoSeconds);
    CHECK([library hasEntryForKey:Key(@"https://v.redd.it/vid111/HLSPlaylist.m3u8?a=2")], "master saved for Apollo's sound check");
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:[dir.path stringByAppendingPathComponent:@"scratch"]], "no scratch left behind");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];

    // Without a remuxer, or with Videos off, the post still saves; the video doesn't.
    dir = TempDirectory();
    ApolloOfflineDownloadOptions *options = Options(100ull * 1000 * 1000);
    options.includeVideos = NO;
    muxCalls = 0;
    result = RunDownload(dir, options, VideoResponses(), requested);
    library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK(result.posts == 2 && muxCalls == 0 && ![library hasEntryForKey:@"video:vid111"], "videos off");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];

    // A video bigger than what's left of the limit is skipped, the post kept.
    dir = TempDirectory();
    [requested removeAllObjects];
    result = RunDownload(dir, Options(20000), VideoResponses(), requested);
    library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK(result.posts >= 1 && ![library hasEntryForKey:@"video:vid111"] && ![requested containsObject:@"v.redd.it/vid111/CMAF_720.mp4"],
          "over the limit: skipped before downloading");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
    sTestMuxer = nil;
}

static void TestSavedSourceKeepsReadPosts(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    NSMutableDictionary *responses = [ResponsesForTwoPages() mutableCopy];
    responses[@"/user/bob/saved"] = responses[@"/best"];
    responses[@"/user/bob/saved?after=t3_a3"] = responses[@"/best?after=t3_a3"];
    ApolloOfflineDownloadOptions *options = Options(100ull * 1024 * 1024);
    ApolloOfflineFeedSource *saved = [ApolloOfflineFeedSource sourceWithPath:@"/user/bob/saved" title:@"Saved"];
    saved.keepsReadPosts = YES;
    saved.queryItems = @[ [NSURLQueryItem queryItemWithName:@"type" value:@"links"] ];
    options.sources = @[ saved ];
    options.skipPostIDs = [NSSet setWithArray:@[ @"a1", @"a2" ]];
    RunResult result = RunDownload(dir, options, responses, requested);
    CHECK(result.committed && result.posts == 6, "saved keeps read posts: %lu", (unsigned long)result.posts);
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK([library hasEntryForKey:Key(@"https://oauth.reddit.com/user/bob/saved?raw_json=1")], "Apollo's Saved list resolves");
    CHECK([library.feedTitles isEqualToArray:@[ @"Saved" ]], "titled Saved");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

int main(void) {
    @autoreleasepool {
        TestFeedKeys();
        TestURLKeys();
        TestPolicy();
        TestImageURLs();
        TestTruncate();
        TestWriterAndLibrary();
        TestDownloaderWholeFeed();
        TestDownloaderBudget();
        TestDownloaderFailureKeepsOldLibrary();
        TestRemovingReadPosts();
        TestAutoRefreshPolicy();
        TestDownloaderSkipsReadPosts();
        TestVideoKeys();
        TestVideoForPost();
        TestRenditions();
        TestDownloaderVideo();
        TestSavedSourceKeepsReadPosts();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("offline library tests passed\n");
    return 0;
}
