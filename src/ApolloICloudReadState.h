#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Deterministic, Foundation-only helpers used by the runtime and host tests.
FOUNDATION_EXPORT NSDictionary * _Nullable ApolloICloudReadStateValidatedJournal(id value);
FOUNDATION_EXPORT NSDictionary *ApolloICloudReadStateMergeJournals(NSArray<NSDictionary *> *journals);
FOUNDATION_EXPORT NSArray<NSString *> *ApolloICloudReadStateProjectedReadIDs(NSDictionary *merged,
                                                                             NSUInteger limit);
FOUNDATION_EXPORT NSData * _Nullable ApolloICloudReadStateProjectedCommentData(NSDictionary *merged,
                                                                                NSUInteger limit);
FOUNDATION_EXPORT NSDictionary *ApolloICloudReadStateJournalByCapturing(
    NSDictionary *journal, NSArray<NSString *> *readIDs, NSDictionary<NSString *, NSDictionary *> *comments,
    NSArray<NSString *> * _Nullable previousReadIDs, NSTimeInterval now, BOOL historicalSeed);
// The caller must hold access to selectedFolderURL for the duration of this
// coordinated merge. Only the dedicated Apollo Reborn Sync namespace is used.
FOUNDATION_EXPORT NSDictionary * _Nullable ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
    NSURL *selectedFolderURL, NSDictionary *localJournal, NSError **error);
// Consent is stored outside exported preferences and is valid only for the
// exact selected-folder identity recorded when the user opted in.
FOUNDATION_EXPORT BOOL ApolloICloudReadStateConsentAtURLMatchesFolder(
    NSURL *consentURL, NSString *folderIdentifier);
FOUNDATION_EXPORT BOOL ApolloICloudReadStateOperationConsentIsCurrent(
    NSURL *consentURL, NSString *capturedFolderIdentifier,
    NSString *currentFolderIdentifier);
FOUNDATION_EXPORT BOOL ApolloICloudReadStateWriteConsentAtURL(
    NSURL *consentURL, BOOL enabled, NSString * _Nullable folderIdentifier, NSError **error);
#if !defined(APOLLO_ICLOUD_READ_STATE_TESTS)
FOUNDATION_EXPORT BOOL ApolloICloudReadStateInstallationConsentEnabled(void);
#endif

__BEGIN_DECLS
extern NSNotificationName const ApolloICloudReadStateDidChangeNotification;
__END_DECLS

@interface ApolloICloudReadState : NSObject
+ (instancetype)sharedManager;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isAvailable) BOOL available;
@property (nonatomic, readonly, nullable) NSString *availabilityMessage;

// Called after defaults are registered. The manager is completely dormant while
// the opt-in is off. Returns NO without changing the setting when no
// user-selected backup folder has been saved.
- (void)start;
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error;

// Explicit user intent. Ordinary native history eviction must not become a
// cross-device unread event.
- (void)recordPostIDAsUnread:(NSString *)postID;
- (void)recordClearAll;

@end

NS_ASSUME_NONNULL_END
