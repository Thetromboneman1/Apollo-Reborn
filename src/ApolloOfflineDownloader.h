#import <Foundation/Foundation.h>

// Fills an ApolloOfflineLibrary with one batch: for each chosen feed, listing
// pages and, per post, its comments and images, until the data budget is
// spent. Foundation-only and transport-agnostic (the fetcher and the Reddit
// request builder are injected) so tests/offline_library_tests.m can drive it
// with fixtures; ApolloOfflineMode.xm supplies the real session and auth.
//
// What Apollo later sees offline:
//   • each feed's pages chain exactly as downloaded (page N's `after` is the
//     key of page N+1) and the last kept page has `after: null`, so the feed
//     ends cleanly instead of failing on a page that was never fetched;
//   • a page is cut to the posts whose comments and images were saved, so
//     every post you can scroll to opens offline.

NS_ASSUME_NONNULL_BEGIN

typedef void (^ApolloOfflineFetchCompletion)(NSData * _Nullable data, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error);
typedef void (^ApolloOfflineFetcher)(NSURLRequest *request, ApolloOfflineFetchCompletion completion);
// Builds an authenticated Reddit read for `path` ("/r/pics/hot", "/comments/abc").
typedef NSURLRequest * _Nonnull (^ApolloOfflineRequestBuilder)(NSString *path, NSArray<NSURLQueryItem *> *query);

@interface ApolloOfflineFeedSource : NSObject
@property (nonatomic, copy, readonly) NSString *path;   // "/best", "/r/popular/hot", "/r/pics/hot"
@property (nonatomic, copy, readonly) NSString *title;  // "Home", "r/pics"
+ (instancetype)sourceWithPath:(NSString *)path title:(NSString *)title;
@end

@interface ApolloOfflineDownloadOptions : NSObject
@property (nonatomic, copy) NSArray<ApolloOfflineFeedSource *> *sources;
@property (nonatomic) unsigned long long byteBudget;
@property (nonatomic) BOOL includeComments;            // default YES
@property (nonatomic) BOOL includeImages;              // default YES
@property (nonatomic) NSUInteger pageSize;             // default 50
@property (nonatomic) NSUInteger maxPostsPerFeed;      // default 300
@property (nonatomic) NSInteger maxImageWidth;         // default 1080 px
@property (nonatomic) unsigned long long maxImageBytes; // default 12 MB (skips huge GIFs)
// Gap between Reddit API calls, to stay well under Reddit's ~100/minute limit.
@property (nonatomic) NSTimeInterval apiSpacing;       // default 0.75 s
// Bare post ids ("abc123") to leave out: posts the user has already read.
// They're removed from the saved pages too, so offline feeds only show new
// posts. A page that's entirely read is replaced by the next one under the
// same key, so the feed doesn't end early.
@property (nonatomic, copy) NSSet<NSString *> *skipPostIDs;
@end

typedef void (^ApolloOfflineProgress)(unsigned long long bytes, NSUInteger posts, NSString *status);
typedef void (^ApolloOfflineCompletion)(BOOL committed, NSUInteger posts, unsigned long long bytes, NSError * _Nullable error);

extern NSErrorDomain const ApolloOfflineErrorDomain;
typedef NS_ENUM(NSInteger, ApolloOfflineErrorCode) {
    ApolloOfflineErrorCancelled = 1,
    ApolloOfflineErrorNothingDownloaded = 2,
    ApolloOfflineErrorStorage = 3,
};

@interface ApolloOfflineDownloader : NSObject

- (instancetype)initWithLibraryDirectory:(NSURL *)directory
                                 fetcher:(ApolloOfflineFetcher)fetcher
                          requestBuilder:(ApolloOfflineRequestBuilder)requestBuilder NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) BOOL running;
// Posts left out of the last run because they were already read.
@property (nonatomic, readonly) NSUInteger skippedPostCount;

// Callbacks arrive on the main queue. The library on disk is replaced only
// when the batch commits; a failed or cancelled run leaves the old one.
- (void)startWithOptions:(ApolloOfflineDownloadOptions *)options
                progress:(nullable ApolloOfflineProgress)progress
              completion:(ApolloOfflineCompletion)completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
