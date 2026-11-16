#import <Foundation/Foundation.h>
#import "ApolloOfflineLibrary.h"

// Offline Mode runtime (ApolloOfflineMode.xm): the URL protocol that answers
// Apollo's own requests from the saved batch, the connectivity watch that
// decides when it does, and the controller the settings screen drives.

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue when download progress, the library, connectivity
// or the serving state changes.
extern NSNotificationName const ApolloOfflineModeDidChangeNotification;

@interface ApolloOfflineModeController : NSObject

+ (instancetype)sharedController;

@property (nonatomic, readonly) BOOL downloading;
@property (nonatomic, readonly) BOOL networkAvailable;
// YES while saved entries are answering requests.
@property (nonatomic, readonly) BOOL serving;
@property (nonatomic, readonly, copy) NSString *progressText;
@property (nonatomic, readonly) unsigned long long progressBytes;
@property (nonatomic, readonly) unsigned long long budgetBytes;

@property (nonatomic, readonly) ApolloOfflineUseMode useMode;
- (void)setUseMode:(ApolloOfflineUseMode)useMode;

// Feeds the next download would fetch, from the settings (Home, Popular, subs).
- (NSArray<NSString *> *)plannedFeedTitles;

// Completion runs on the main queue with a user-facing message.
- (void)startDownloadWithCompletion:(void (^ _Nullable)(BOOL success, NSString *message))completion;
- (void)cancelDownload;
- (void)deleteLibrary;

// "42 posts · 87 MB · Today" or "Not downloaded".
- (NSString *)librarySummary;

@end

NS_ASSUME_NONNULL_END
