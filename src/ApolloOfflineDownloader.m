#import "ApolloOfflineDownloader.h"
#import "ApolloOfflineLibrary.h"

// Foundation-only (host-tested). Every piece of run state lives on _queue;
// fetch completions hop back onto it before touching anything.

NSErrorDomain const ApolloOfflineErrorDomain = @"ApolloOfflineErrorDomain";

@implementation ApolloOfflineFeedSource
+ (instancetype)sourceWithPath:(NSString *)path title:(NSString *)title {
    ApolloOfflineFeedSource *source = [self new];
    source->_path = [path copy];
    source->_title = [title copy];
    return source;
}
@end

@implementation ApolloOfflineDownloadOptions
- (instancetype)init {
    if ((self = [super init])) {
        _sources = @[];
        _byteBudget = 100ull * 1024 * 1024;
        _includeComments = YES;
        _includeImages = YES;
        _pageSize = 50;
        _maxPostsPerFeed = 300;
        _maxImageWidth = 1080;
        _maxImageBytes = 12ull * 1024 * 1024;
        _apiSpacing = 0.75;
        _includeVideos = YES;
        _maxVideoHeight = 720;
        _maxVideoBytes = 60ull * 1000 * 1000;
        _maxVideoDuration = 5 * 60;
    }
    return self;
}
@end

// A fetched listing page waiting for the next page to decide whether it ends the feed.
@interface ApolloOfflinePendingPage : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSData *data;
@property (nonatomic) NSUInteger childCount;
@property (nonatomic) NSUInteger kept;
@property (nonatomic, copy) NSArray<NSString *> *keptNames;
@end
@implementation ApolloOfflinePendingPage
@end

static NSDictionary *ApolloOfflineDictValue(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static BOOL ApolloOfflineIsSuccess(NSHTTPURLResponse *response, NSData *data, NSError *error) {
    if (error || data.length == 0) return NO;
    return response == nil || (response.statusCode >= 200 && response.statusCode < 300);
}

@implementation ApolloOfflineDownloader {
    NSURL *_directory;
    ApolloOfflineFetcher _fetcher;
    ApolloOfflineRequestBuilder _requestBuilder;
    dispatch_queue_t _queue;

    // Run state (on _queue).
    ApolloOfflineDownloadOptions *_options;
    ApolloOfflineProgress _progress;
    ApolloOfflineCompletion _completion;
    ApolloOfflineLibraryWriter *_writer;
    BOOL _cancelled;
    NSError *_lastError;
    CFAbsoluteTime _lastAPICall;

    NSUInteger _feedIndex;
    unsigned long long _feedBudgetEnd;
    NSUInteger _keptInFeed;
    NSString *_after;
    ApolloOfflinePendingPage *_pending;
    NSArray<NSDictionary *> *_pagePosts;
    NSString *_pageKey;
    NSData *_pageData;
    NSString *_nextAfter;
    NSString *_pageKeyOverride;
    NSUInteger _emptyPagesSkipped;
    NSUInteger _skippedRead;
}

- (instancetype)initWithLibraryDirectory:(NSURL *)directory fetcher:(ApolloOfflineFetcher)fetcher requestBuilder:(ApolloOfflineRequestBuilder)requestBuilder {
    if ((self = [super init])) {
        _directory = directory;
        _fetcher = [fetcher copy];
        _requestBuilder = [requestBuilder copy];
        _queue = dispatch_queue_create("app.apolloreborn.offline-download", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startWithOptions:(ApolloOfflineDownloadOptions *)options progress:(ApolloOfflineProgress)progress completion:(ApolloOfflineCompletion)completion {
    dispatch_async(_queue, ^{
        if (self->_running) return;
        NSError *error = nil;
        ApolloOfflineLibraryWriter *writer = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:self->_directory error:&error];
        if (!writer) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, 0, 0, error); });
            return;
        }
        self->_running = YES;
        self->_options = options;
        self->_progress = [progress copy];
        self->_completion = [completion copy];
        self->_writer = writer;
        self->_cancelled = NO;
        self->_lastError = nil;
        self->_lastAPICall = 0;
        self->_skippedRead = 0;
        self->_feedIndex = 0;
        [self startFeed];
    });
}

- (NSUInteger)skippedPostCount {
    __block NSUInteger count = 0;
    dispatch_sync(_queue, ^{ count = self->_skippedRead; });
    return count;
}

- (void)cancel {
    dispatch_async(_queue, ^{ self->_cancelled = YES; });
}

// MARK: - Reporting

- (void)report:(NSString *)status {
    ApolloOfflineProgress progress = _progress;
    if (!progress) return;
    unsigned long long bytes = _writer.bytesWritten;
    NSUInteger posts = _writer.postCount + _keptInFeed;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(bytes, posts, status); });
}

- (void)finishWithCommit:(BOOL)commit error:(NSError *)error {
    ApolloOfflineCompletion completion = _completion;
    NSUInteger posts = _writer.postCount;
    unsigned long long bytes = _writer.bytesWritten;
    BOOL committed = NO;
    NSError *finalError = error;
    if (commit) {
        NSError *commitError = nil;
        committed = [_writer commit:&commitError];
        if (!committed) {
            NSMutableDictionary *info = [@{ NSLocalizedDescriptionKey: @"Couldn't save the offline library." } mutableCopy];
            if (commitError) info[NSUnderlyingErrorKey] = commitError;
            finalError = [NSError errorWithDomain:ApolloOfflineErrorDomain code:ApolloOfflineErrorStorage userInfo:info];
        }
    } else {
        [_writer discard];
    }
    _writer = nil;
    _progress = nil;
    _completion = nil;
    _pending = nil;
    _pagePosts = nil;
    _pageData = nil;
    _running = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(committed, committed ? posts : 0, committed ? bytes : 0, finalError);
    });
}

- (BOOL)stopIfCancelled {
    if (!_cancelled) return NO;
    [self finishWithCommit:NO error:[NSError errorWithDomain:ApolloOfflineErrorDomain code:ApolloOfflineErrorCancelled
                                                    userInfo:@{ NSLocalizedDescriptionKey: @"Download cancelled." }]];
    return YES;
}

// MARK: - Transport

// Reddit API reads are spaced out; CDN image fetches are not.
- (void)fetchAPI:(NSString *)path query:(NSArray<NSURLQueryItem *> *)query completion:(void (^)(NSURLRequest *request, NSData *data, NSHTTPURLResponse *response, NSError *error))completion {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval wait = MAX(0, _options.apiSpacing - (now - _lastAPICall));
    _lastAPICall = now + wait;
    NSURLRequest *request = _requestBuilder(path, query);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), _queue, ^{
        self->_fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            dispatch_async(self->_queue, ^{ completion(request, data, response, error); });
        });
    });
}

// MARK: - Feeds

- (void)startFeed {
    if ([self stopIfCancelled]) return;
    NSArray<ApolloOfflineFeedSource *> *sources = _options.sources;
    if (_feedIndex >= sources.count) {
        if (_writer.postCount == 0) {
            NSMutableDictionary *info = [@{
                NSLocalizedDescriptionKey: @"Nothing could be downloaded. Check your connection and that you're signed in, then try again.",
            } mutableCopy];
            if (_lastError) info[NSUnderlyingErrorKey] = _lastError;
            [self finishWithCommit:NO error:[NSError errorWithDomain:ApolloOfflineErrorDomain code:ApolloOfflineErrorNothingDownloaded userInfo:info]];
        } else {
            [self finishWithCommit:YES error:nil];
        }
        return;
    }
    // Each feed gets an equal share of what's left, so a later feed still
    // gets its turn when an earlier one runs out of posts early.
    unsigned long long used = _writer.bytesWritten;
    unsigned long long left = _options.byteBudget > used ? _options.byteBudget - used : 0;
    _feedBudgetEnd = used + left / (sources.count - _feedIndex);
    _keptInFeed = 0;
    _after = nil;
    _pending = nil;
    _pageKeyOverride = nil;
    _emptyPagesSkipped = 0;
    [self fetchPage];
}

- (void)finishFeed {
    ApolloOfflineFeedSource *source = _options.sources[_feedIndex];
    [_writer noteFeedTitle:source.title posts:_keptInFeed];
    _keptInFeed = 0;
    _feedIndex++;
    [self startFeed];
}

- (void)fetchPage {
    if ([self stopIfCancelled]) return;
    ApolloOfflineFeedSource *source = _options.sources[_feedIndex];
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%lu", (unsigned long)_options.pageSize]],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"], nil];
    if (_after.length > 0) [query addObject:[NSURLQueryItem queryItemWithName:@"after" value:_after]];
    if (source.queryItems.count > 0) [query addObjectsFromArray:source.queryItems];
    [self report:[NSString stringWithFormat:@"Loading %@…", source.title]];

    [self fetchAPI:source.path query:query completion:^(NSURLRequest *request, NSData *fetched, NSHTTPURLResponse *response, NSError *error) {
        if ([self stopIfCancelled]) return;
        // Leave out posts the user has already read before anything else sees the page.
        NSData *data = fetched;
        if (ApolloOfflineIsSuccess(response, fetched, error) && self->_options.skipPostIDs.count > 0 && !source.keepsReadPosts) {
            NSUInteger removed = 0;
            data = ApolloOfflineListingRemovingPosts(fetched, self->_options.skipPostIDs, &removed) ?: fetched;
            self->_skippedRead += removed;
        }
        NSDictionary *root = ApolloOfflineIsSuccess(response, data, error)
            ? ApolloOfflineDictValue([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSDictionary *listing = ApolloOfflineDictValue(root[@"data"]);
        NSArray *children = [listing[@"children"] isKindOfClass:[NSArray class]] ? listing[@"children"] : nil;
        // A page that came back all-read is stood in for by the next one under
        // the key Apollo will ask for (see skipPostIDs).
        NSString *key = self->_pageKeyOverride ?: ApolloOfflineKeyForURL(request.URL);
        id nextAfterValue = listing[@"after"];
        NSString *nextAfter = [nextAfterValue isKindOfClass:[NSString class]] ? nextAfterValue : nil;
        if (children && key && children.count == 0 && nextAfter.length > 0 && self->_emptyPagesSkipped < 10) {
            self->_pageKeyOverride = key;
            self->_emptyPagesSkipped++;
            self->_after = nextAfter;
            [self fetchPage];
            return;
        }
        self->_pageKeyOverride = nil;
        self->_emptyPagesSkipped = 0;
        if (!children || !key) {
            self->_lastError = error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Reddit answered %ld for %@.", (long)response.statusCode, source.title],
            }];
            self->_pagePosts = @[];
            [self completePageKeeping:0 endFeed:YES];
            return;
        }
        NSMutableArray<NSDictionary *> *posts = [NSMutableArray array];
        for (id child in children) {
            NSDictionary *post = ApolloOfflineDictValue(ApolloOfflineDictValue(child)[@"data"]);
            if ([ApolloOfflineDictValue(child)[@"kind"] isEqual:@"t3"] && post) [posts addObject:post];
        }
        self->_pageKey = key;
        self->_pageData = data;
        self->_pagePosts = posts;
        self->_nextAfter = nextAfter;
        [self processPostAtIndex:0];
    }];
}

// MARK: - Posts

- (BOOL)budgetSpent {
    return _writer.bytesWritten >= _feedBudgetEnd || _keptInFeed >= _options.maxPostsPerFeed;
}

- (void)processPostAtIndex:(NSUInteger)index {
    if ([self stopIfCancelled]) return;
    if (index >= _pagePosts.count) {
        [self completePageKeeping:index endFeed:NO];
        return;
    }
    if ([self budgetSpent]) {
        [self completePageKeeping:index endFeed:YES];
        return;
    }
    NSDictionary *post = _pagePosts[index];
    void (^next)(void) = ^{
        self->_keptInFeed++;
        [self report:[NSString stringWithFormat:@"Saved %lu posts", (unsigned long)(self->_writer.postCount + self->_keptInFeed)]];
        [self processPostAtIndex:index + 1];
    };
    [self saveCommentsForPost:post then:^{
        [self saveImagesForPost:post then:^{
            [self saveVideoForPost:post then:next];
        }];
    }];
}

- (void)saveCommentsForPost:(NSDictionary *)post then:(void (^)(void))then {
    NSString *postID = [post[@"id"] isKindOfClass:[NSString class]] ? post[@"id"] : nil;
    if (!_options.includeComments || postID.length == 0) {
        then();
        return;
    }
    NSString *path = [@"/comments/" stringByAppendingString:postID];
    NSArray *query = @[
        [NSURLQueryItem queryItemWithName:@"limit" value:@"100"],
        [NSURLQueryItem queryItemWithName:@"depth" value:@"6"],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
    ];
    [self fetchAPI:path query:query completion:^(NSURLRequest *request, NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSString *key = ApolloOfflineKeyForURL(request.URL);
        id root = ApolloOfflineIsSuccess(response, data, error) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        // Apollo indexes the comments response as an array; never store anything else.
        if (key && [root isKindOfClass:[NSArray class]]) {
            [self->_writer storeData:data contentType:@"application/json; charset=UTF-8" forKey:key];
        } else if (error) {
            self->_lastError = error;
        }
        then();
    }];
}

- (void)saveImagesForPost:(NSDictionary *)post then:(void (^)(void))then {
    if (!_options.includeImages) {
        then();
        return;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSURL *url in ApolloOfflineImageURLsForPost(post, _options.maxImageWidth)) {
        NSString *key = ApolloOfflineKeyForURL(url);
        if (key && ![_writer hasKey:key]) [urls addObject:url];
    }
    if (urls.count == 0) {
        then();
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    unsigned long long maxBytes = _options.maxImageBytes;
    for (NSURL *url in urls) {
        dispatch_group_enter(group);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 30;
        _fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            dispatch_async(self->_queue, ^{
                NSString *key = ApolloOfflineKeyForURL(url);
                if (key && ApolloOfflineIsSuccess(response, data, error) && data.length <= maxBytes && self->_writer) {
                    NSString *type = response.MIMEType.length > 0 ? response.MIMEType : @"image/jpeg";
                    if ([type hasPrefix:@"image/"]) {
                        [self->_writer storeData:data contentType:type forKey:key];
                    }
                }
                dispatch_group_leave(group);
            });
        });
    }
    dispatch_group_notify(group, _queue, then);
}

// MARK: - Video

// Fetches one file for a video; nil on failure or when it's over `maxBytes`.
- (void)fetchMedia:(NSURL *)url maxBytes:(unsigned long long)maxBytes then:(void (^)(NSData *data))then {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    _fetcher(request, ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        BOOL ok = ApolloOfflineIsSuccess(response, data, error) && data.length <= maxBytes;
        dispatch_async(self->_queue, ^{ then(ok ? data : nil); });
    });
}

- (void)saveVideoForPost:(NSDictionary *)post then:(void (^)(void))then {
    NSDictionary *video = ApolloOfflineRedditVideoForPost(post);
    ApolloOfflineVideoMuxer muxer = self.videoMuxer;
    if (!_options.includeVideos || !video || !muxer || !_writer) {
        then();
        return;
    }
    NSString *videoID = video[@"id"];
    NSString *key = ApolloOfflineVideoKey(videoID);
    NSTimeInterval duration = [video[@"duration"] doubleValue];
    if ([_writer hasKey:key] || duration > _options.maxVideoDuration) {
        then();
        return;
    }
    NSURL *manifestURL = video[@"dash"];
    [self fetchMedia:manifestURL maxBytes:1024 * 1024 then:^(NSData *manifest) {
        NSDictionary *renditions = ApolloOfflineRedditVideoRenditions(manifest, manifestURL, self->_options.maxVideoHeight);
        if (!renditions || [self stopIfCancelledQuietly]) {
            then();
            return;
        }
        NSURL *audioURL = [video[@"hasAudio"] boolValue] ? renditions[@"audio"] : nil;
        // Skip a video that would overrun this feed's share of the limit
        // (bitrates from the manifest; 30 s assumed when Reddit omits the length).
        double seconds = duration > 0 ? duration : 30;
        unsigned long long estimate = (unsigned long long)(([renditions[@"videoBandwidth"] doubleValue] +
                                                            (audioURL ? [renditions[@"audioBandwidth"] doubleValue] : 0)) * seconds / 8.0);
        if (estimate > self->_options.maxVideoBytes || self->_writer.bytesWritten + estimate > self->_feedBudgetEnd) {
            then();
            return;
        }
        [self report:@"Saving videos"];
        unsigned long long maxBytes = self->_options.maxVideoBytes;
        [self fetchMedia:renditions[@"video"] maxBytes:maxBytes then:^(NSData *videoData) {
            void (^withAudio)(NSData *) = ^(NSData *audioData) {
                ApolloOfflineLibraryWriter *writer = self->_writer;
                if (!videoData || !writer || [self stopIfCancelledQuietly] || (audioURL && !audioData)) {
                    then();
                    return;
                }
                NSURL *videoFile = [writer scratchFileURLWithExtension:@"mp4"];
                NSURL *audioFile = audioData ? [writer scratchFileURLWithExtension:@"mp4"] : nil;
                NSURL *output = [writer scratchFileURLWithExtension:@"mp4"];
                if (![videoData writeToURL:videoFile atomically:NO] || (audioFile && ![audioData writeToURL:audioFile atomically:NO])) {
                    then();
                    return;
                }
                // Apollo reads the master playlist to tell a video with sound
                // from a silent "GIF"; keep Reddit's own copy for offline.
                NSURL *masterURL = video[@"hls"];
                [self fetchMedia:masterURL maxBytes:256 * 1024 then:^(NSData *master) {
                    muxer(videoFile, audioFile, output, ^(BOOL ok, NSTimeInterval muxedDuration) {
                        dispatch_async(self->_queue, ^{
                            NSFileManager *fm = NSFileManager.defaultManager;
                            [fm removeItemAtURL:videoFile error:nil];
                            if (audioFile) [fm removeItemAtURL:audioFile error:nil];
                            ApolloOfflineLibraryWriter *current = self->_writer;
                            if (ok && current == writer) {
                                NSString *masterKey = ApolloOfflineKeyForURL(masterURL);
                                if (master && masterKey) {
                                    [current storeData:master contentType:@"application/vnd.apple.mpegurl" forKey:masterKey];
                                }
                                [current storeVideoFile:output forKey:key pathExtension:@"mp4"
                                               duration:muxedDuration > 0 ? muxedDuration : duration];
                            }
                            [fm removeItemAtURL:output error:nil];
                            then();
                        });
                    });
                }];
            };
            if (audioURL && videoData) {
                [self fetchMedia:audioURL maxBytes:maxBytes then:withAudio];
            } else {
                withAudio(nil);
            }
        }];
    }];
}

// Like -stopIfCancelled, for the middle of a post: lets the post finish its
// chain (the next -processPostAtIndex: does the actual stop).
- (BOOL)stopIfCancelledQuietly {
    return _cancelled;
}

// MARK: - Pages

- (void)flushPending:(BOOL)endHere {
    ApolloOfflinePendingPage *page = _pending;
    _pending = nil;
    if (!page || page.kept == 0) return;
    NSData *data = page.data;
    if (endHere || page.kept < page.childCount) {
        data = ApolloOfflineTruncatedListing(page.data, page.kept, YES) ?: page.data;
    }
    [_writer storeFeedPage:data forKey:page.key postNames:page.keptNames];
}

// `kept` counts posts of _pagePosts. A page is held back until the next one
// shows whether it was the feed's last, so the final page can say so.
- (void)completePageKeeping:(NSUInteger)kept endFeed:(BOOL)endFeed {
    if (kept == 0) {
        [self flushPending:YES];
        [self finishFeed];
        return;
    }
    [self flushPending:NO];
    ApolloOfflinePendingPage *page = [ApolloOfflinePendingPage new];
    page.key = _pageKey;
    page.data = _pageData;
    // Feed listings only return t3 children, so post counts and listing
    // child counts line up for truncation.
    page.childCount = _pagePosts.count;
    page.kept = kept;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *post in [_pagePosts subarrayWithRange:NSMakeRange(0, kept)]) {
        if ([post[@"name"] isKindOfClass:[NSString class]]) [names addObject:post[@"name"]];
    }
    page.keptNames = names;
    _pending = page;
    _pagePosts = nil;
    _pageData = nil;

    if (endFeed || kept < page.childCount || _nextAfter.length == 0 || [self budgetSpent]) {
        [self flushPending:YES];
        [self finishFeed];
        return;
    }
    _after = _nextAfter;
    [self fetchPage];
}

@end
