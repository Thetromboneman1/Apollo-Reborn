#import <Foundation/Foundation.h>

// Offline Mode: a pre-downloaded batch of feed posts, their comments and their
// images that Apollo can browse with no connection (a flight, the subway).
// Suggested on r/ApolloReborn as "offline mode similar to TikTok": you choose
// how much data to spend, it downloads a batch, and you scroll it offline.
//
// This file is the Foundation-only half (host-tested in
// tests/offline_library_tests.m):
//   • request keys: maps the URLs Apollo itself asks for to the entries the
//     downloader stored, so the library serves Apollo's own requests even
//     though they carry different sort/limit/raw_json/host details;
//   • the on-disk library (index + one file per entry) and its staged writer;
//   • the policy that decides when the library answers instead of the network.
//
// ApolloOfflineDownloader fills the library; ApolloOfflineMode.xm serves it
// through an NSURLProtocol and owns the settings-facing controller.

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// "home", "r/<sub>", "m/<user>/<multi>" or "saved/<user>" for a Reddit
// listing path such as "/", "/best", "/r/Pics/top", "/user/x/m/y/new",
// "/user/x/saved" (".json" and a trailing slash
// are ignored, names are lowercased). nil for any other path. Sort is
// deliberately dropped: offline, a feed shows the batch that was downloaded
// whatever sort Apollo asks for.
NSString * _Nullable ApolloOfflineFeedKeyForPath(NSString *path);

// The library key for a request URL, or nil when the URL is never served
// offline:
//   feed:<feed>|<after>   Reddit listing page (<after> empty on page one)
//   comments:<id>         a post's comments (/comments/<id>, /r/x/comments/<id>/slug)
//   reddimg:<stem>        i.redd.it / preview.redd.it image (any resolution)
//   extimg:<stem>         external-preview.redd.it image (any resolution)
//   url:<host><path>      any other host (query dropped)
NSString * _Nullable ApolloOfflineKeyForURL(NSURL *url);

// YES for the hosts Apollo's Reddit API reads go to (oauth/www/old reddit.com).
BOOL ApolloOfflineURLIsRedditAPI(NSURL *url);

// The image URLs worth saving for one post's `data` dictionary (a t3 child):
// the preview at the largest resolution no wider than maxWidth (or the
// source), every gallery image, the thumbnail, a direct i.redd.it/i.imgur.com
// image, and the same for a crosspost's parent. Duplicates by library key are
// removed. Videos are saved separately (below); this covers their posters.
NSArray<NSURL *> *ApolloOfflineImageURLsForPost(NSDictionary *post, NSInteger maxWidth);

// MARK: Video
//
// A Reddit-hosted video (v.redd.it, including the silent clips Apollo labels
// "GIF") is saved as ONE local mp4 with its sound: the downloader picks a
// video and an audio rendition from the post's DASH manifest, fetches both
// files and remuxes them (no re-encode). Offline, ApolloOfflineMode.xm hands
// Apollo's player that file in place of the streaming URL, so playback never
// touches the network. The master playlist is saved as well, because Apollo
// reads it to decide whether a post has sound (no sound = "GIF" pill).

// The v.redd.it id in any URL that names one: the https master/variant/media
// URLs and Apollo's own player URLs, whatever their scheme. nil otherwise.
NSString * _Nullable ApolloOfflineRedditVideoIDForURL(NSURL * _Nullable url);
// "video:<id>", the library key for a saved video file.
NSString *ApolloOfflineVideoKey(NSString *videoID);

// The post's Reddit-hosted video (its own, else its crosspost parent's):
// @{ "id", "dash" (NSURL), "hls" (NSURL), "duration" (NSNumber, seconds),
//    "hasAudio" (NSNumber BOOL) }. nil when it has none.
NSDictionary * _Nullable ApolloOfflineRedditVideoForPost(NSDictionary *post);

// The renditions to save from a DASH manifest: the tallest video no taller
// than maxHeight (else the shortest one) and the highest-bandwidth audio:
// @{ "video" (NSURL), "videoBandwidth", "height", optional "audio" (NSURL),
//    "audioBandwidth" }. Only self-contained files (a BaseURL per
// Representation) qualify; nil when there's no usable video.
NSDictionary * _Nullable ApolloOfflineRedditVideoRenditions(NSData *manifest, NSURL *manifestURL, NSInteger maxHeight);

// Rough time it takes to get through a batch: ~12 s per post plus the running
// time of its saved videos. Shown next to the size so "how much is this?" can
// be read in minutes as well as megabytes.
NSTimeInterval ApolloOfflineEstimatedBrowseTime(NSUInteger posts, NSTimeInterval videoSeconds);

// The listing JSON with only its first `keep` children and, when `endHere`,
// data.after set to null so Apollo treats it as the last page. nil when the
// data isn't a listing.
NSData * _Nullable ApolloOfflineTruncatedListing(NSData *listing, NSUInteger keep, BOOL endHere);

typedef NS_ENUM(NSInteger, ApolloOfflineUseMode) {
    ApolloOfflineUseModeAutomatic = 0,  // only while the device has no connection
    ApolloOfflineUseModeAlways = 1,     // always, even online (captive Wi-Fi, saving data)
    ApolloOfflineUseModeNever = 2,      // keep the library but never use it
};

// Whether saved entries should answer requests right now.
BOOL ApolloOfflineShouldServe(ApolloOfflineUseMode mode, BOOL networkAvailable, BOOL hasLibrary, BOOL downloading);

// The listing JSON without the posts whose bare id ("abc123") is in `postIDs`.
// data.after is kept, so the page still chains to the same next page. Sets
// *removed to how many were dropped. nil when the data isn't a listing.
NSData * _Nullable ApolloOfflineListingRemovingPosts(NSData *listing, NSSet<NSString *> *postIDs, NSUInteger * _Nullable removed);

// Inputs for "Keep fresh": refresh the batch on its own while Apollo is open.
typedef struct {
    BOOL enabled;                   // the user's setting
    BOOL hasLibrary;                // only after a first manual download (an opt-in)
    NSTimeInterval libraryAge;      // seconds since the last batch
    double readFraction;            // share of the batch's posts already read (0...1)
    BOOL networkAvailable;
    BOOL onWiFi;                    // never on cellular
    BOOL lowPowerMode;
    BOOL serving;                   // the library is answering requests
    BOOL downloading;
    NSTimeInterval sinceLastAttempt; // seconds since the last automatic try
} ApolloOfflineAutoRefreshState;

// Refresh when the batch is this old...
extern const NSTimeInterval ApolloOfflineAutoRefreshMaxAge;        // 1 hour
// ...or sooner, once this share of it has been read (TikTok-style top-up)...
extern const double ApolloOfflineAutoRefreshReadFraction;          // 0.5
// ...but never for a batch younger than this.
extern const NSTimeInterval ApolloOfflineAutoRefreshMinAge;        // 10 minutes
extern const NSTimeInterval ApolloOfflineAutoRefreshRetryInterval; // 15 minutes

BOOL ApolloOfflineShouldAutoRefresh(ApolloOfflineAutoRefreshState state);

#ifdef __cplusplus
}
#endif

// A committed library on disk. Lookups are thread-safe and cheap (an in-memory
// key set), because the URL protocol asks for every request the app makes.
@interface ApolloOfflineLibrary : NSObject

// <Application Support>/ApolloReborn/OfflineLibrary (excluded from backups).
+ (NSURL *)defaultDirectory;
+ (instancetype)sharedLibrary;

- (instancetype)initWithDirectory:(NSURL *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *directory;
@property (nonatomic, readonly) BOOL hasContent;
@property (nonatomic, readonly) NSUInteger postCount;
@property (nonatomic, readonly) unsigned long long totalBytes;
@property (nonatomic, readonly, nullable) NSDate *downloadedAt;
// Human titles of the feeds in this batch, in download order ("Home", "r/pics").
@property (nonatomic, readonly) NSArray<NSString *> *feedTitles;

// Feed keys also resolve through any saved post's fullname (see
// -[ApolloOfflineLibraryWriter storeFeedPage:forKey:postNames:]): the answer
// is the rest of that post's page, or the next saved page when it was last.
- (BOOL)hasEntryForKey:(NSString *)key;
- (nullable NSData *)dataForKey:(NSString *)key contentType:(NSString * _Nullable * _Nullable)contentType;

// Bare ids ("abc123") of every post saved in feed pages.
@property (nonatomic, readonly) NSArray<NSString *> *savedPostIDs;

// Videos saved in this batch and their total running time.
@property (nonatomic, readonly) NSUInteger videoCount;
@property (nonatomic, readonly) NSTimeInterval videoSeconds;

// The file behind a stored entry (videos are played straight from disk).
- (nullable NSURL *)fileURLForKey:(NSString *)key;

// Re-reads the index from disk (after a download commits).
- (void)reload;
// Deletes the library from disk.
- (BOOL)removeAll:(NSError **)error;

@end

// Writes a new batch into a staging folder next to the library and swaps it in
// atomically on commit, so the old batch keeps working until the new one is
// complete and a cancelled download leaves nothing behind.
@interface ApolloOfflineLibraryWriter : NSObject

- (nullable instancetype)initWithLibraryDirectory:(NSURL *)directory error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) unsigned long long bytesWritten;
@property (nonatomic, readonly) NSUInteger postCount;

- (BOOL)hasKey:(NSString *)key;
- (BOOL)storeData:(NSData *)data contentType:(nullable NSString *)contentType forKey:(NSString *)key;
// A feed page ("feed:<feed>|<after>") plus the fullnames of its posts, in
// order. The library uses them to answer `after=<any saved post>`: Apollo
// often loaded page one online with its own page size, so its next-page
// cursor is a post in the middle of a saved page, not a saved page's key.
- (BOOL)storeFeedPage:(NSData *)data forKey:(NSString *)key postNames:(NSArray<NSString *> *)names;
// Moves `file` into the batch (keeping `pathExtension`, which AVFoundation
// uses to recognise a local mp4) and counts it as one saved video.
- (BOOL)storeVideoFile:(NSURL *)file forKey:(NSString *)key pathExtension:(NSString *)pathExtension
              duration:(NSTimeInterval)duration;
// A fresh scratch file path inside the staging folder (gone after commit).
- (NSURL *)scratchFileURLWithExtension:(NSString *)pathExtension;
- (void)noteFeedTitle:(NSString *)title posts:(NSUInteger)posts;
- (BOOL)commit:(NSError **)error;
- (void)discard;

@end

NS_ASSUME_NONNULL_END
