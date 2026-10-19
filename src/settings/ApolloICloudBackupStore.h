#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloICloudBackupAvailability) {
    ApolloICloudBackupAvailabilityUnknown = 0,
    ApolloICloudBackupAvailabilityAvailable,
    ApolloICloudBackupAvailabilityMissingEntitlement,
    ApolloICloudBackupAvailabilityAccountUnavailable,
};

__BEGIN_DECLS
extern NSNotificationName const ApolloICloudBackupStoreDidChangeNotification;
__END_DECLS

typedef id _Nullable (^ApolloICloudSelectedFolderOperation)(NSURL *folderURL,
                                                             NSError **error);

// Owns the iCloud Drive seam. Every public completion returns on main. The
// backup engine remains unaware of iCloud and continues to create/restore the
// same .apollobackup archives.
@interface ApolloICloudBackupStore : NSObject
+ (instancetype)sharedStore;

@property (nonatomic, readonly) ApolloICloudBackupAvailability availability;
@property (nonatomic, readonly, copy) NSString *availabilityDescription;
@property (nonatomic, readonly, getter=isWorking) BOOL working;
@property (atomic, readonly, copy, nullable) NSString *scopeIdentifier;
@property (atomic, readonly, copy, nullable) NSString *selectedFolderName;
// Stable, non-secret identity used to bind installation-local consent to the
// exact folder the user selected. This never exposes the bookmark itself.
@property (nonatomic, readonly, copy, nullable) NSString *selectedFolderConsentIdentifier;
@property (nonatomic, readonly) BOOL hasSelectedFolder;

- (void)refreshAvailabilityWithCompletion:(nullable void (^)(void))completion;
- (void)selectFolderURL:(NSURL *)folderURL completion:(void (^)(NSError *_Nullable error))completion;
// Runs on the store's serialized file-provider queue while the existing
// selected-folder bookmark is resolved, identity-checked, and security-scoped.
// It never falls back to a signed ubiquity container: callers using this seam
// require the folder the user explicitly chose in Files.
- (void)performSelectedFolderOperation:(ApolloICloudSelectedFolderOperation)operation
                            completion:(void (^)(id _Nullable result,
                                                 NSError *_Nullable error))completion;
- (void)uploadLocalBackupURL:(NSURL *)localURL
               expectedScope:(nullable NSString *)expectedScope
               identityToken:(NSString *)identityToken
                  completion:(nullable void (^)(NSURL *_Nullable cloudURL, NSError *_Nullable error))completion;
- (void)backupURLsWithCompletion:(void (^)(NSArray<NSURL *> *urls, NSError *_Nullable error))completion;

// Downloads if needed and returns a protected local copy suitable for the
// existing restore validator. The caller owns cleanup of the returned URL.
- (void)prepareLocalCopyOfBackupURL:(NSURL *)cloudURL
                         completion:(void (^)(NSURL *_Nullable localURL, NSError *_Nullable error))completion;
- (void)deleteBackupURL:(NSURL *)cloudURL
             completion:(nullable void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
