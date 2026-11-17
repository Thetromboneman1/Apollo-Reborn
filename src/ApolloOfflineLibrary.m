#import "ApolloOfflineLibrary.h"

// Foundation-only on purpose: tests/run_offline_library_tests.sh builds this
// file for macOS. No UIKit, no ApolloLog.

static NSString *const kApolloOfflineIndexName = @"index.json";
static const NSInteger kApolloOfflineIndexVersion = 1;

// MARK: - Keys

static NSSet<NSString *> *ApolloOfflineSortNames(void) {
    static NSSet *sorts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sorts = [NSSet setWithArray:@[ @"hot", @"new", @"top", @"rising", @"controversial", @"best", @"gilded" ]];
    });
    return sorts;
}

// Path components with ".json" removed from the last one, lowercased, empties dropped.
static NSArray<NSString *> *ApolloOfflinePathComponents(NSString *path) {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *raw in [path componentsSeparatedByString:@"/"]) {
        if (raw.length == 0) continue;
        [components addObject:raw.lowercaseString];
    }
    NSString *last = components.lastObject;
    if ([last hasSuffix:@".json"]) {
        NSString *trimmed = [last substringToIndex:last.length - 5];
        [components removeLastObject];
        if (trimmed.length > 0) [components addObject:trimmed];
    }
    return components;
}

NSString *ApolloOfflineFeedKeyForPath(NSString *path) {
    NSArray<NSString *> *c = ApolloOfflinePathComponents(path ?: @"");
    NSSet *sorts = ApolloOfflineSortNames();
    if (c.count == 0) return @"home";
    if (c.count == 1 && [sorts containsObject:c[0]]) return @"home";
    if ([c[0] isEqualToString:@"r"] && c.count >= 2) {
        if (c.count == 2 || (c.count == 3 && [sorts containsObject:c[2]])) {
            return [@"r/" stringByAppendingString:c[1]];
        }
        return nil;
    }
    // The account's Saved list, which Offline Mode keeps as an archive.
    if (([c[0] isEqualToString:@"user"] || [c[0] isEqualToString:@"u"]) && c.count == 3 && [c[2] isEqualToString:@"saved"]) {
        return [@"saved/" stringByAppendingString:c[1]];
    }
    if (([c[0] isEqualToString:@"user"] || [c[0] isEqualToString:@"u"]) && c.count >= 4 && [c[2] isEqualToString:@"m"]) {
        if (c.count == 4 || (c.count == 5 && [sorts containsObject:c[4]])) {
            return [NSString stringWithFormat:@"m/%@/%@", c[1], c[3]];
        }
    }
    return nil;
}

BOOL ApolloOfflineURLIsRedditAPI(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host) return NO;
    return [host isEqualToString:@"oauth.reddit.com"] || [host isEqualToString:@"www.reddit.com"] ||
           [host isEqualToString:@"reddit.com"] || [host isEqualToString:@"old.reddit.com"];
}

static NSString *ApolloOfflineQueryValue(NSURL *url, NSString *name) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:name]) return item.value;
    }
    return nil;
}

static NSString *ApolloOfflineFileStem(NSURL *url) {
    NSString *stem = url.lastPathComponent.stringByDeletingPathExtension;
    return stem.length > 0 ? stem : nil;
}

NSString *ApolloOfflineKeyForURL(NSURL *url) {
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return nil;

    if (ApolloOfflineURLIsRedditAPI(url)) {
        NSArray<NSString *> *c = ApolloOfflinePathComponents(url.path ?: @"");
        NSUInteger commentsIndex = [c indexOfObject:@"comments"];
        // /comments/<id>[/slug] or /r/<sub>/comments/<id>[/slug] (not /r/<sub>/comments
        // alone, which is the subreddit's comment stream).
        BOOL commentsAtRoot = commentsIndex == 0;
        BOOL commentsInSub = commentsIndex == 2 && [c[0] isEqualToString:@"r"];
        if ((commentsAtRoot || commentsInSub) && commentsIndex + 1 < c.count) {
            return [@"comments:" stringByAppendingString:c[commentsIndex + 1]];
        }
        NSString *feed = ApolloOfflineFeedKeyForPath(url.path ?: @"");
        if (!feed) return nil;
        NSString *after = ApolloOfflineQueryValue(url, @"after") ?: @"";
        return [NSString stringWithFormat:@"feed:%@|%@", feed, after.lowercaseString];
    }

    if ([host isEqualToString:@"i.redd.it"] || [host isEqualToString:@"preview.redd.it"]) {
        NSString *stem = ApolloOfflineFileStem(url);
        return stem ? [@"reddimg:" stringByAppendingString:stem] : nil;
    }
    if ([host isEqualToString:@"external-preview.redd.it"]) {
        NSString *stem = ApolloOfflineFileStem(url);
        return stem ? [@"extimg:" stringByAppendingString:stem] : nil;
    }
    NSString *path = url.path.length > 0 ? url.path : @"/";
    return [NSString stringWithFormat:@"url:%@%@", host, path];
}

BOOL ApolloOfflineShouldServe(ApolloOfflineUseMode mode, BOOL networkAvailable, BOOL hasLibrary, BOOL downloading) {
    if (!hasLibrary || downloading) return NO;
    switch (mode) {
        case ApolloOfflineUseModeAlways: return YES;
        case ApolloOfflineUseModeAutomatic: return !networkAvailable;
        case ApolloOfflineUseModeNever: return NO;
    }
    return NO;
}

const NSTimeInterval ApolloOfflineAutoRefreshMaxAge = 60 * 60;
const double ApolloOfflineAutoRefreshReadFraction = 0.5;
const NSTimeInterval ApolloOfflineAutoRefreshMinAge = 10 * 60;
const NSTimeInterval ApolloOfflineAutoRefreshRetryInterval = 15 * 60;

BOOL ApolloOfflineShouldAutoRefresh(ApolloOfflineAutoRefreshState s) {
    if (!s.enabled || !s.hasLibrary) return NO;
    if (!s.networkAvailable || !s.onWiFi || s.lowPowerMode) return NO;
    // Serving means the user is browsing the batch (Always mode, or no
    // connection): replacing it under them would change what they're reading.
    if (s.serving || s.downloading) return NO;
    if (s.sinceLastAttempt < ApolloOfflineAutoRefreshRetryInterval) return NO;
    if (s.libraryAge >= ApolloOfflineAutoRefreshMaxAge) return YES;
    // Most of it has been read: top it up now rather than waiting out the hour.
    return s.libraryAge >= ApolloOfflineAutoRefreshMinAge && s.readFraction >= ApolloOfflineAutoRefreshReadFraction;
}

NSData *ApolloOfflineListingRemovingPosts(NSData *listing, NSSet<NSString *> *postIDs, NSUInteger *removed) {
    if (removed) *removed = 0;
    if (listing.length == 0) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:listing options:NSJSONReadingMutableContainers error:nil];
    NSMutableDictionary *object = [root isKindOfClass:[NSMutableDictionary class]] ? root : nil;
    NSMutableDictionary *data = [object[@"data"] isKindOfClass:[NSMutableDictionary class]] ? object[@"data"] : nil;
    NSMutableArray *children = [data[@"children"] isKindOfClass:[NSMutableArray class]] ? data[@"children"] : nil;
    if (!children) return nil;
    if (postIDs.count == 0) return listing;
    NSIndexSet *drop = [children indexesOfObjectsPassingTest:^BOOL(id child, __unused NSUInteger index, __unused BOOL *stop) {
        NSDictionary *post = [child isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
        id postID = [post isKindOfClass:[NSDictionary class]] ? post[@"id"] : nil;
        return [postID isKindOfClass:[NSString class]] && [postIDs containsObject:postID];
    }];
    if (drop.count == 0) return listing;
    [children removeObjectsAtIndexes:drop];
    data[@"dist"] = @(children.count);
    if (removed) *removed = drop.count;
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

// MARK: - Post media

static NSString *ApolloOfflineString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSDictionary *ApolloOfflineDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *ApolloOfflineArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSURL *ApolloOfflineMediaURL(NSString *string) {
    if (string.length == 0) return nil;
    // raw_json=1 responses are already unescaped; older shapes aren't.
    NSString *unescaped = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    if (![unescaped hasPrefix:@"https://"] && ![unescaped hasPrefix:@"http://"]) return nil;
    return [NSURL URLWithString:unescaped];
}

// Largest {url|u, width|x} entry no wider than maxWidth; else the fallback.
static NSString *ApolloOfflinePickResolution(NSArray *resolutions, NSString *urlKey, NSString *widthKey,
                                             NSInteger maxWidth, NSString *fallback) {
    NSString *best = nil;
    NSInteger bestWidth = -1;
    for (id entry in resolutions) {
        NSDictionary *resolution = ApolloOfflineDict(entry);
        NSString *url = ApolloOfflineString(resolution[urlKey]);
        NSInteger width = [resolution[widthKey] respondsToSelector:@selector(integerValue)] ? [resolution[widthKey] integerValue] : 0;
        if (url.length == 0 || width > maxWidth) continue;
        if (width > bestWidth) {
            best = url;
            bestWidth = width;
        }
    }
    return best ?: fallback;
}

static BOOL ApolloOfflineIsDirectImage(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"i.redd.it"] && ![host isEqualToString:@"i.imgur.com"]) return NO;
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[ @"jpg", @"jpeg", @"png", @"webp", @"gif" ] containsObject:ext];
}

static void ApolloOfflineCollectImages(NSDictionary *post, NSInteger maxWidth, NSMutableArray<NSURL *> *urls,
                                       NSMutableSet<NSString *> *keys, NSUInteger depth) {
    void (^add)(NSString *) = ^(NSString *string) {
        NSURL *url = ApolloOfflineMediaURL(string);
        NSString *key = url ? ApolloOfflineKeyForURL(url) : nil;
        if (!key || [keys containsObject:key]) return;
        [keys addObject:key];
        [urls addObject:url];
    };

    // Gallery: media_metadata keyed by id, ordered by gallery_data.items.
    NSDictionary *metadata = ApolloOfflineDict(post[@"media_metadata"]);
    if (metadata.count > 0) {
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        for (id item in ApolloOfflineArray(ApolloOfflineDict(post[@"gallery_data"])[@"items"])) {
            NSString *mediaID = ApolloOfflineString(ApolloOfflineDict(item)[@"media_id"]);
            if (mediaID) [order addObject:mediaID];
        }
        if (order.count == 0) {
            [order addObjectsFromArray:[metadata.allKeys sortedArrayUsingSelector:@selector(compare:)]];
        }
        for (NSString *mediaID in order) {
            NSDictionary *media = ApolloOfflineDict(metadata[mediaID]);
            if (![ApolloOfflineString(media[@"status"]) isEqualToString:@"valid"]) continue;
            NSString *source = ApolloOfflineString(ApolloOfflineDict(media[@"s"])[@"u"]);
            add(ApolloOfflinePickResolution(ApolloOfflineArray(media[@"p"]), @"u", @"x", maxWidth, source));
        }
    }

    // Link/image preview.
    NSDictionary *image = ApolloOfflineDict(ApolloOfflineArray(ApolloOfflineDict(post[@"preview"])[@"images"]).firstObject);
    if (image) {
        NSString *source = ApolloOfflineString(ApolloOfflineDict(image[@"source"])[@"url"]);
        add(ApolloOfflinePickResolution(ApolloOfflineArray(image[@"resolutions"]), @"url", @"width", maxWidth, source));
    }

    // Direct image link (dedupes against the preview for i.redd.it: same stem).
    NSString *link = ApolloOfflineString(post[@"url_overridden_by_dest"]) ?: ApolloOfflineString(post[@"url"]);
    NSURL *linkURL = ApolloOfflineMediaURL(link);
    if (linkURL && ApolloOfflineIsDirectImage(linkURL)) add(linkURL.absoluteString);

    add(ApolloOfflineString(post[@"thumbnail"]));

    if (depth == 0) {
        NSDictionary *parent = ApolloOfflineDict(ApolloOfflineArray(post[@"crosspost_parent_list"]).firstObject);
        if (parent) ApolloOfflineCollectImages(parent, maxWidth, urls, keys, depth + 1);
    }
}

NSArray<NSURL *> *ApolloOfflineImageURLsForPost(NSDictionary *post, NSInteger maxWidth) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    if (![post isKindOfClass:[NSDictionary class]]) return urls;
    ApolloOfflineCollectImages(post, maxWidth, urls, [NSMutableSet set], 0);
    return urls;
}

// MARK: - Video

NSString *ApolloOfflineRedditVideoIDForURL(NSURL *url) {
    // Matched on the text, not url.host: Apollo's player rewrites the scheme
    // (and may wrap the original URL), but "v.redd.it/<id>" always survives.
    NSString *string = url.absoluteString;
    if (string.length == 0) return nil;
    NSRange marker = [string rangeOfString:@"v.redd.it/" options:NSCaseInsensitiveSearch];
    if (marker.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(marker);
    NSUInteger end = start;
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    while (end < string.length && [allowed characterIsMember:[string characterAtIndex:end]]) end++;
    if (end - start < 4) return nil;
    return [[string substringWithRange:NSMakeRange(start, end - start)] lowercaseString];
}

NSString *ApolloOfflineVideoKey(NSString *videoID) {
    return [@"video:" stringByAppendingString:videoID.lowercaseString ?: @""];
}

static NSDictionary *ApolloOfflineRedditVideoOf(NSDictionary *post) {
    for (NSString *field in @[ @"secure_media", @"media" ]) {
        NSDictionary *video = ApolloOfflineDict(ApolloOfflineDict(post[field])[@"reddit_video"]);
        if (!video) continue;
        NSURL *dash = ApolloOfflineMediaURL(ApolloOfflineString(video[@"dash_url"]));
        NSURL *hls = ApolloOfflineMediaURL(ApolloOfflineString(video[@"hls_url"]));
        NSURL *fallback = ApolloOfflineMediaURL(ApolloOfflineString(video[@"fallback_url"]));
        NSString *videoID = ApolloOfflineRedditVideoIDForURL(dash) ?: ApolloOfflineRedditVideoIDForURL(hls)
                            ?: ApolloOfflineRedditVideoIDForURL(fallback);
        if (!videoID) continue;
        if (!dash) dash = [NSURL URLWithString:[NSString stringWithFormat:@"https://v.redd.it/%@/DASHPlaylist.mpd", videoID]];
        if (!hls) hls = [NSURL URLWithString:[NSString stringWithFormat:@"https://v.redd.it/%@/HLSPlaylist.m3u8", videoID]];
        id duration = video[@"duration"];
        id hasAudio = video[@"has_audio"];
        return @{
            @"id": videoID,
            @"dash": dash,
            @"hls": hls,
            @"duration": @([duration respondsToSelector:@selector(doubleValue)] ? [duration doubleValue] : 0),
            // Older posts omit has_audio; the manifest decides then.
            @"hasAudio": @([hasAudio respondsToSelector:@selector(boolValue)] ? [hasAudio boolValue] : YES),
        };
    }
    return nil;
}

NSDictionary *ApolloOfflineRedditVideoForPost(NSDictionary *post) {
    if (![post isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *video = ApolloOfflineRedditVideoOf(post);
    if (video) return video;
    NSDictionary *parent = ApolloOfflineDict(ApolloOfflineArray(post[@"crosspost_parent_list"]).firstObject);
    return parent ? ApolloOfflineRedditVideoOf(parent) : nil;
}

// Walks a DASH MPD keeping the kind (from AdaptationSet or Representation
// contentType/mimeType) and the BaseURL of each Representation. Reddit's
// manifests list each rendition as one file (CMAF_720.mp4, DASH_AUDIO_128.mp4)
// with a SegmentBase index; a SegmentTemplate/SegmentList rendition is a set
// of segments, not one file, and is skipped.
@interface ApolloOfflineManifestParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *representations;
@property (nonatomic, copy) NSString *setKind;
@property (nonatomic, strong) NSMutableDictionary *current;
@property (nonatomic, strong) NSMutableString *text;
@end

static NSString *ApolloOfflineManifestKind(NSDictionary<NSString *, NSString *> *attributes) {
    NSString *contentType = attributes[@"contentType"].lowercaseString;
    NSString *mimeType = attributes[@"mimeType"].lowercaseString;
    if ([contentType isEqualToString:@"audio"] || [mimeType hasPrefix:@"audio/"]) return @"audio";
    if ([contentType isEqualToString:@"video"] || [mimeType hasPrefix:@"video/"]) return @"video";
    if (contentType.length || mimeType.length) return @"other";
    return nil;
}

@implementation ApolloOfflineManifestParser

- (void)parser:(__unused NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(__unused NSString *)namespaceURI
 qualifiedName:(__unused NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    NSString *name = [elementName componentsSeparatedByString:@":"].lastObject;
    if ([name isEqualToString:@"AdaptationSet"]) {
        self.setKind = ApolloOfflineManifestKind(attributes);
    } else if ([name isEqualToString:@"Representation"]) {
        self.current = [NSMutableDictionary dictionary];
        self.current[@"kind"] = ApolloOfflineManifestKind(attributes) ?: self.setKind ?: @"other";
        self.current[@"bandwidth"] = @([attributes[@"bandwidth"] longLongValue]);
        self.current[@"height"] = @([attributes[@"height"] integerValue]);
    } else if ([name isEqualToString:@"BaseURL"] && self.current) {
        self.text = [NSMutableString string];
    } else if (([name isEqualToString:@"SegmentTemplate"] || [name isEqualToString:@"SegmentList"]) && self.current) {
        self.current[@"segmented"] = @YES;
    }
}

- (void)parser:(__unused NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.text appendString:string];
}

- (void)parser:(__unused NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(__unused NSString *)namespaceURI
 qualifiedName:(__unused NSString *)qName {
    NSString *name = [elementName componentsSeparatedByString:@":"].lastObject;
    if ([name isEqualToString:@"BaseURL"] && self.current && self.text) {
        self.current[@"base"] = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        self.text = nil;
    } else if ([name isEqualToString:@"Representation"] && self.current) {
        if ([self.current[@"base"] length] > 0 && ![self.current[@"segmented"] boolValue]) {
            [self.representations addObject:self.current];
        }
        self.current = nil;
    } else if ([name isEqualToString:@"AdaptationSet"]) {
        self.setKind = nil;
    }
}

@end

NSDictionary *ApolloOfflineRedditVideoRenditions(NSData *manifest, NSURL *manifestURL, NSInteger maxHeight) {
    if (manifest.length == 0 || !manifestURL) return nil;
    ApolloOfflineManifestParser *delegate = [ApolloOfflineManifestParser new];
    delegate.representations = [NSMutableArray array];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:manifest];
    parser.delegate = delegate;
    parser.shouldResolveExternalEntities = NO;
    if (![parser parse]) return nil;

    // Relative BaseURLs resolve against the manifest without its query.
    NSURLComponents *baseComponents = [NSURLComponents componentsWithURL:manifestURL resolvingAgainstBaseURL:NO];
    baseComponents.query = nil;
    NSURL *base = baseComponents.URL;

    NSDictionary *bestFit = nil, *shortest = nil, *audio = nil;
    for (NSDictionary *rep in delegate.representations) {
        NSInteger height = [rep[@"height"] integerValue];
        long long bandwidth = [rep[@"bandwidth"] longLongValue];
        if ([rep[@"kind"] isEqualToString:@"video"]) {
            if (height > 0 && height <= maxHeight) {
                NSInteger bestHeight = [bestFit[@"height"] integerValue];
                if (!bestFit || height > bestHeight || (height == bestHeight && bandwidth > [bestFit[@"bandwidth"] longLongValue])) bestFit = rep;
            }
            if (!shortest || (height > 0 && height < [shortest[@"height"] integerValue])) shortest = rep;
        } else if ([rep[@"kind"] isEqualToString:@"audio"]) {
            if (!audio || bandwidth > [audio[@"bandwidth"] longLongValue]) audio = rep;
        }
    }
    NSDictionary *video = bestFit ?: shortest;
    NSURL *videoURL = video ? [NSURL URLWithString:video[@"base"] relativeToURL:base].absoluteURL : nil;
    if (!videoURL) return nil;
    NSMutableDictionary *result = [@{
        @"video": videoURL,
        @"videoBandwidth": video[@"bandwidth"],
        @"height": video[@"height"],
    } mutableCopy];
    NSURL *audioURL = audio ? [NSURL URLWithString:audio[@"base"] relativeToURL:base].absoluteURL : nil;
    if (audioURL) {
        result[@"audio"] = audioURL;
        result[@"audioBandwidth"] = audio[@"bandwidth"];
    }
    return result;
}

NSTimeInterval ApolloOfflineEstimatedBrowseTime(NSUInteger posts, NSTimeInterval videoSeconds) {
    return posts * 12.0 + MAX(0, videoSeconds);
}

NSData *ApolloOfflineTruncatedListing(NSData *listing, NSUInteger keep, BOOL endHere) {
    if (listing.length == 0) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:listing options:NSJSONReadingMutableContainers error:nil];
    NSMutableDictionary *object = [root isKindOfClass:[NSMutableDictionary class]] ? root : nil;
    NSMutableDictionary *data = [object[@"data"] isKindOfClass:[NSMutableDictionary class]] ? object[@"data"] : nil;
    NSMutableArray *children = [data[@"children"] isKindOfClass:[NSMutableArray class]] ? data[@"children"] : nil;
    if (!children) return nil;
    if (children.count > keep) {
        [children removeObjectsInRange:NSMakeRange(keep, children.count - keep)];
    }
    data[@"dist"] = @(children.count);
    if (endHere) data[@"after"] = [NSNull null];
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

// MARK: - Library

static NSDictionary *ApolloOfflineReadIndex(NSURL *directory) {
    NSData *data = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:kApolloOfflineIndexName]];
    if (!data) return nil;
    NSDictionary *index = ApolloOfflineDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
    if ([index[@"version"] integerValue] != kApolloOfflineIndexVersion) return nil;
    return index;
}

static NSString *ApolloOfflineFeedOfKey(NSString *key) {
    if (![key hasPrefix:@"feed:"]) return nil;
    NSRange bar = [key rangeOfString:@"|"];
    return bar.location == NSNotFound ? nil : [key substringWithRange:NSMakeRange(5, bar.location - 5)];
}

@implementation ApolloOfflineLibrary {
    NSLock *_lock;
    NSDictionary<NSString *, NSDictionary *> *_entries;
    // "feed:<feed>|<post fullname>" -> @[ page key, @(position in page) ]
    NSDictionary<NSString *, NSArray *> *_cursors;
    NSUInteger _postCount;
    unsigned long long _totalBytes;
    NSDate *_downloadedAt;
    NSArray<NSString *> *_feedTitles;
    NSUInteger _videoCount;
    NSTimeInterval _videoSeconds;
}

+ (NSURL *)defaultDirectory {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"ApolloReborn" isDirectory:YES]
            URLByAppendingPathComponent:@"OfflineLibrary" isDirectory:YES];
}

+ (instancetype)sharedLibrary {
    static ApolloOfflineLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        library = [[ApolloOfflineLibrary alloc] initWithDirectory:[self defaultDirectory]];
    });
    return library;
}

- (instancetype)initWithDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        _directory = directory;
        _lock = [NSLock new];
        [self reload];
    }
    return self;
}

- (void)reload {
    NSDictionary *index = ApolloOfflineReadIndex(_directory);
    NSDictionary *entries = ApolloOfflineDict(index[@"entries"]) ?: @{};
    NSNumber *downloaded = [index[@"downloadedAt"] isKindOfClass:[NSNumber class]] ? index[@"downloadedAt"] : nil;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (id title in ApolloOfflineArray(index[@"feeds"])) {
        if ([title isKindOfClass:[NSString class]]) [titles addObject:title];
    }
    NSMutableDictionary<NSString *, NSArray *> *cursors = [NSMutableDictionary dictionary];
    [entries enumerateKeysAndObjectsUsingBlock:^(NSString *key, id entry, __unused BOOL *stop) {
        NSString *feed = ApolloOfflineFeedOfKey(key);
        NSArray *names = ApolloOfflineArray(ApolloOfflineDict(entry)[@"names"]);
        if (!feed || names.count == 0) return;
        [names enumerateObjectsUsingBlock:^(id name, NSUInteger position, __unused BOOL *innerStop) {
            if (![name isKindOfClass:[NSString class]]) return;
            cursors[[NSString stringWithFormat:@"feed:%@|%@", feed, [name lowercaseString]]] = @[ key, @(position) ];
        }];
    }];
    [_lock lock];
    _entries = entries;
    _cursors = cursors;
    _postCount = [index[@"posts"] unsignedIntegerValue];
    _totalBytes = [index[@"bytes"] unsignedLongLongValue];
    _downloadedAt = downloaded ? [NSDate dateWithTimeIntervalSince1970:downloaded.doubleValue] : nil;
    _feedTitles = titles;
    _videoCount = [index[@"videos"] unsignedIntegerValue];
    _videoSeconds = [index[@"videoSeconds"] doubleValue];
    [_lock unlock];
}

- (BOOL)hasContent {
    [_lock lock];
    BOOL has = _entries.count > 0;
    [_lock unlock];
    return has;
}

- (NSUInteger)postCount { [_lock lock]; NSUInteger v = _postCount; [_lock unlock]; return v; }
- (unsigned long long)totalBytes { [_lock lock]; unsigned long long v = _totalBytes; [_lock unlock]; return v; }
- (NSDate *)downloadedAt { [_lock lock]; NSDate *v = _downloadedAt; [_lock unlock]; return v; }
- (NSArray<NSString *> *)feedTitles { [_lock lock]; NSArray *v = _feedTitles; [_lock unlock]; return v; }
- (NSUInteger)videoCount { [_lock lock]; NSUInteger v = _videoCount; [_lock unlock]; return v; }
- (NSTimeInterval)videoSeconds { [_lock lock]; NSTimeInterval v = _videoSeconds; [_lock unlock]; return v; }

- (NSURL *)fileURLForKey:(NSString *)key {
    if (key.length == 0) return nil;
    [_lock lock];
    NSDictionary *entry = ApolloOfflineDict(_entries[key]);
    [_lock unlock];
    NSString *file = ApolloOfflineString(entry[@"file"]);
    if (file.length == 0 || [file containsString:@"/"]) return nil;
    NSURL *url = [_directory URLByAppendingPathComponent:file isDirectory:NO];
    return [NSFileManager.defaultManager fileExistsAtPath:url.path] ? url : nil;
}

- (NSArray<NSString *> *)savedPostIDs {
    [_lock lock];
    NSArray<NSString *> *cursorKeys = _cursors.allKeys;
    [_lock unlock];
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (NSString *key in cursorKeys) {
        // "feed:<feed>|t3_<id>"
        NSRange marker = [key rangeOfString:@"|t3_"];
        if (marker.location != NSNotFound) [ids addObject:[key substringFromIndex:NSMaxRange(marker)]];
    }
    return ids.allObjects;
}

- (BOOL)hasEntryForKey:(NSString *)key {
    if (key.length == 0) return NO;
    [_lock lock];
    BOOL has = _entries[key] != nil || _cursors[key] != nil;
    [_lock unlock];
    return has;
}

- (NSData *)storedDataForKey:(NSString *)key contentType:(NSString **)contentType {
    [_lock lock];
    NSDictionary *entry = ApolloOfflineDict(_entries[key]);
    [_lock unlock];
    NSString *file = ApolloOfflineString(entry[@"file"]);
    if (file.length == 0 || [file containsString:@"/"]) return nil;
    if (contentType) *contentType = ApolloOfflineString(entry[@"type"]);
    return [NSData dataWithContentsOfURL:[_directory URLByAppendingPathComponent:file]];
}

- (NSData *)dataForKey:(NSString *)key contentType:(NSString **)contentType {
    if (key.length == 0) return nil;
    NSData *stored = [self storedDataForKey:key contentType:contentType];
    if (stored) return stored;

    // A cursor in the middle of a saved page: the posts after it, keeping the
    // page's own `after` so the chain continues into the next saved page.
    [_lock lock];
    NSArray *cursor = _cursors[key];
    [_lock unlock];
    if (cursor.count != 2) return nil;
    NSData *page = [self storedDataForKey:cursor[0] contentType:contentType];
    id root = page ? [NSJSONSerialization JSONObjectWithData:page options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableDictionary *listing = [root isKindOfClass:[NSMutableDictionary class]] ? root : nil;
    NSMutableDictionary *data = [listing[@"data"] isKindOfClass:[NSMutableDictionary class]] ? listing[@"data"] : nil;
    NSMutableArray *children = [data[@"children"] isKindOfClass:[NSMutableArray class]] ? data[@"children"] : nil;
    if (!children) return nil;
    NSUInteger start = [cursor[1] unsignedIntegerValue] + 1;
    if (start >= children.count) {
        NSString *after = ApolloOfflineString(data[@"after"]);
        NSString *feed = ApolloOfflineFeedOfKey(key);
        if (after.length > 0 && feed) {
            NSString *next = [NSString stringWithFormat:@"feed:%@|%@", feed, after.lowercaseString];
            if (![next isEqualToString:key]) {
                NSData *nextPage = [self storedDataForKey:next contentType:contentType];
                if (nextPage) return nextPage;
            }
        }
        [children removeAllObjects];
        data[@"after"] = [NSNull null];
    } else {
        [children removeObjectsInRange:NSMakeRange(0, start)];
    }
    data[@"dist"] = @(children.count);
    if (contentType) *contentType = @"application/json; charset=UTF-8";
    return [NSJSONSerialization dataWithJSONObject:listing options:0 error:nil];
}

- (BOOL)removeAll:(NSError **)error {
    BOOL ok = YES;
    if ([NSFileManager.defaultManager fileExistsAtPath:_directory.path]) {
        ok = [NSFileManager.defaultManager removeItemAtURL:_directory error:error];
    }
    [self reload];
    return ok;
}

@end

// MARK: - Writer

@implementation ApolloOfflineLibraryWriter {
    NSURL *_libraryDirectory;
    NSURL *_stagingDirectory;
    NSMutableDictionary<NSString *, NSDictionary *> *_entries;
    NSMutableArray<NSString *> *_feedTitles;
    NSUInteger _nextFile;
    NSUInteger _videoCount;
    NSTimeInterval _videoSeconds;
    BOOL _finished;
}

- (instancetype)initWithLibraryDirectory:(NSURL *)directory error:(NSError **)error {
    if ((self = [super init])) {
        _libraryDirectory = directory;
        NSURL *parent = directory.URLByDeletingLastPathComponent;
        _stagingDirectory = [parent URLByAppendingPathComponent:
            [directory.lastPathComponent stringByAppendingString:@".staging"] isDirectory:YES];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtURL:_stagingDirectory error:nil];
        if (![fm createDirectoryAtURL:_stagingDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
            return nil;
        }
        _entries = [NSMutableDictionary dictionary];
        _feedTitles = [NSMutableArray array];
    }
    return self;
}

- (BOOL)hasKey:(NSString *)key {
    return _entries[key] != nil;
}

- (BOOL)storeData:(NSData *)data contentType:(NSString *)contentType forKey:(NSString *)key {
    if (_finished || data.length == 0 || key.length == 0) return NO;
    NSString *file = [NSString stringWithFormat:@"e%lu", (unsigned long)++_nextFile];
    if (![data writeToURL:[_stagingDirectory URLByAppendingPathComponent:file] atomically:NO]) return NO;
    NSDictionary *previous = _entries[key];
    if (previous) {
        _bytesWritten -= [previous[@"bytes"] unsignedLongLongValue];
        [NSFileManager.defaultManager removeItemAtURL:[_stagingDirectory URLByAppendingPathComponent:previous[@"file"]] error:nil];
    }
    _entries[key] = @{ @"file": file, @"type": contentType ?: @"application/octet-stream", @"bytes": @(data.length) };
    _bytesWritten += data.length;
    return YES;
}

- (BOOL)storeFeedPage:(NSData *)data forKey:(NSString *)key postNames:(NSArray<NSString *> *)names {
    if (![self storeData:data contentType:@"application/json; charset=UTF-8" forKey:key]) return NO;
    if (names.count > 0) {
        NSMutableDictionary *entry = [_entries[key] mutableCopy];
        entry[@"names"] = [names copy];
        _entries[key] = entry;
    }
    return YES;
}

- (BOOL)storeVideoFile:(NSURL *)file forKey:(NSString *)key pathExtension:(NSString *)pathExtension
              duration:(NSTimeInterval)duration {
    if (_finished || !file || key.length == 0) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    unsigned long long bytes = [[fm attributesOfItemAtPath:file.path error:nil] fileSize];
    if (bytes == 0) return NO;
    NSString *name = [NSString stringWithFormat:@"e%lu", (unsigned long)++_nextFile];
    if (pathExtension.length > 0) name = [name stringByAppendingPathExtension:pathExtension];
    if (![fm moveItemAtURL:file toURL:[_stagingDirectory URLByAppendingPathComponent:name] error:nil]) return NO;
    NSDictionary *previous = _entries[key];
    if (previous) {
        _bytesWritten -= [previous[@"bytes"] unsignedLongLongValue];
        [fm removeItemAtURL:[_stagingDirectory URLByAppendingPathComponent:previous[@"file"]] error:nil];
    } else {
        _videoCount++;
        _videoSeconds += MAX(0, duration);
    }
    _entries[key] = @{ @"file": name, @"type": @"video/mp4", @"bytes": @(bytes) };
    _bytesWritten += bytes;
    return YES;
}

- (NSURL *)scratchFileURLWithExtension:(NSString *)pathExtension {
    NSURL *scratch = [_stagingDirectory URLByAppendingPathComponent:@"scratch" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = NSUUID.UUID.UUIDString;
    if (pathExtension.length > 0) name = [name stringByAppendingPathExtension:pathExtension];
    return [scratch URLByAppendingPathComponent:name isDirectory:NO];
}

- (void)noteFeedTitle:(NSString *)title posts:(NSUInteger)posts {
    if (posts == 0) return;
    [_feedTitles addObject:title];
    _postCount += posts;
}

- (BOOL)commit:(NSError **)error {
    if (_finished) return NO;
    _finished = YES;
    NSDictionary *index = @{
        @"version": @(kApolloOfflineIndexVersion),
        @"downloadedAt": @((long long)NSDate.date.timeIntervalSince1970),
        @"posts": @(_postCount),
        @"bytes": @(_bytesWritten),
        @"feeds": _feedTitles,
        @"videos": @(_videoCount),
        @"videoSeconds": @(_videoSeconds),
        @"entries": _entries,
    };
    [NSFileManager.defaultManager removeItemAtURL:[_stagingDirectory URLByAppendingPathComponent:@"scratch" isDirectory:YES] error:nil];
    NSData *json = [NSJSONSerialization dataWithJSONObject:index options:0 error:error];
    if (!json || ![json writeToURL:[_stagingDirectory URLByAppendingPathComponent:kApolloOfflineIndexName] options:NSDataWritingAtomic error:error]) {
        [self discard];
        return NO;
    }
    NSURL *staged = _stagingDirectory;
    [staged setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL ok;
    if ([fm fileExistsAtPath:_libraryDirectory.path]) {
        ok = [fm replaceItemAtURL:_libraryDirectory withItemAtURL:staged backupItemName:nil
                          options:0 resultingItemURL:nil error:error];
    } else {
        ok = [fm moveItemAtURL:staged toURL:_libraryDirectory error:error];
    }
    if (!ok) [fm removeItemAtURL:staged error:nil];
    [_libraryDirectory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return ok;
}

- (void)discard {
    _finished = YES;
    [NSFileManager.defaultManager removeItemAtURL:_stagingDirectory error:nil];
}

@end
