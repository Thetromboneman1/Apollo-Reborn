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

static RunResult RunDownload(NSURL *dir, ApolloOfflineDownloadOptions *options, NSDictionary<NSString *, NSData *> *responses,
                             NSMutableArray<NSString *> *requested) {
    ApolloOfflineFetcher fetcher = ^(NSURLRequest *request, ApolloOfflineFetchCompletion completion) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        NSString *after = nil;
        for (NSURLQueryItem *item in c.queryItems) if ([item.name isEqualToString:@"after"]) after = item.value;
        NSString *lookup = after ? [NSString stringWithFormat:@"%@?after=%@", c.path, after] : (c.path ?: @"");
        if ([request.URL.host hasSuffix:@"redd.it"] || [request.URL.host hasSuffix:@"redditmedia.com"]) lookup = request.URL.host;
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
        .enabled = YES, .hasLibrary = YES, .libraryAge = 7 * 3600, .networkAvailable = YES, .onWiFi = YES,
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
    t = s; t.libraryAge = 3 * 3600;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "fresh batch kept");
    t = s; t.sinceLastAttempt = 60;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "a failed try isn't retried right away");
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
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("offline library tests passed\n");
    return 0;
}
