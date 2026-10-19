#import "ApolloICloudReadState.h"

#import <limits.h>
#if !defined(APOLLO_ICLOUD_READ_STATE_TESTS)
#import <UIKit/UIKit.h>
#import "ApolloCommon.h"
#import "ApolloPostReadState.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloICloudBackupStore.h"
#endif
#import <math.h>

static NSNumber *const kConsentVersion = @1;

BOOL ApolloICloudReadStateConsentAtURLMatchesFolder(NSURL *consentURL, NSString *folderIdentifier) {
    if (!consentURL.isFileURL || folderIdentifier.length == 0 || folderIdentifier.length > 128) return NO;
    NSData *data = [NSData dataWithContentsOfURL:consentURL options:NSDataReadingMappedIfSafe error:nil];
    if (data.length == 0 || data.length > 4096) return NO;
    id value = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *consent = value;
    return [consent[@"v"] isEqual:kConsentVersion] && [consent[@"enabled"] isEqual:@YES] &&
        [consent[@"folder"] isKindOfClass:NSString.class] &&
        [consent[@"folder"] isEqualToString:folderIdentifier];
}

BOOL ApolloICloudReadStateWriteConsentAtURL(NSURL *consentURL, BOOL enabled,
                                             NSString *folderIdentifier, NSError **error) {
    if (!consentURL.isFileURL) {
        if (error) *error = [NSError errorWithDomain:@"ApolloICloudReadState" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"The local consent location is invalid."}];
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!enabled) {
        if (![fm fileExistsAtPath:consentURL.path]) return YES;
        return [fm removeItemAtURL:consentURL error:error];
    }
    if (folderIdentifier.length == 0 || folderIdentifier.length > 128) {
        if (error) *error = [NSError errorWithDomain:@"ApolloICloudReadState" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Choose the iCloud Drive folder again before enabling sync."}];
        return NO;
    }
    NSURL *directory = consentURL.URLByDeletingLastPathComponent;
    NSDictionary *directoryAttributes = nil;
    NSDataWritingOptions writingOptions = NSDataWritingAtomic;
#if !defined(APOLLO_ICLOUD_READ_STATE_TESTS)
    directoryAttributes = @{NSFileProtectionKey: NSFileProtectionComplete};
    writingOptions |= NSDataWritingFileProtectionComplete;
#endif
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES
        attributes:directoryAttributes error:error]) return NO;
    [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{
        @"v": kConsentVersion, @"enabled": @YES, @"folder": folderIdentifier,
    } format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToURL:consentURL options:writingOptions error:error];
}

static NSString *const kJournalVersion = @"v";
static NSString *const kJournalWriter = @"w";
static NSString *const kJournalClear = @"clear";
static NSString *const kJournalGeneration = @"g";
static NSString *const kJournalRecords = @"records";
static NSString *const kRecordRead = @"r";
static NSString *const kRecordUnread = @"u";
static NSString *const kRecordCommentTime = @"c";
static NSString *const kRecordCommentCount = @"n";
static NSString *const kRecordWriter = @"w";
static NSUInteger const kMaximumJournalRecords = 6500;
static NSUInteger const kMaximumJournalBytes = 900 * 1024;

static BOOL ApolloICloudFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && number <= [NSDate date].timeIntervalSince1970 + 24 * 60 * 60;
}

static NSString *ApolloICloudBarePostID(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *postID = [value hasPrefix:@"t3_"] ? [value substringFromIndex:3] : value;
    if (postID.length == 0 || postID.length > 32) return nil;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"].invertedSet;
    return [postID rangeOfCharacterFromSet:invalid].location == NSNotFound ? postID.lowercaseString : nil;
}

static NSDictionary *ApolloICloudValidatedRecord(id value, NSString *defaultWriter) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    for (NSString *key in @[kRecordRead, kRecordUnread, kRecordCommentTime]) {
        id number = value[key];
        if (number && !ApolloICloudFiniteNumber(number)) return nil;
        if (number) record[key] = @([number doubleValue]);
    }
    id count = value[kRecordCommentCount];
    if (count) {
        if (!ApolloICloudFiniteNumber(count) || floor([count doubleValue]) != [count doubleValue] ||
            [count doubleValue] >= (double)LLONG_MAX || !record[kRecordCommentTime]) return nil;
        record[kRecordCommentCount] = @([count longLongValue]);
    }
    NSString *writer = [value[kRecordWriter] isKindOfClass:NSString.class] ? value[kRecordWriter] : defaultWriter;
    if (writer.length == 0 || writer.length > 64) return nil;
    record[kRecordWriter] = writer;
    return record.count > 1 ? record : nil;
}

NSDictionary *ApolloICloudReadStateValidatedJournal(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[kJournalVersion] isEqual:@1]) return nil;
    NSString *writer = [value[kJournalWriter] isKindOfClass:NSString.class] ? value[kJournalWriter] : nil;
    NSDictionary *records = [value[kJournalRecords] isKindOfClass:NSDictionary.class] ? value[kJournalRecords] : nil;
    if (writer.length == 0 || writer.length > 64 || !records || records.count > kMaximumJournalRecords) return nil;
    id clear = value[kJournalClear];
    if (clear && !ApolloICloudFiniteNumber(clear)) return nil;
    id generation = value[kJournalGeneration];
    if (generation && (!ApolloICloudFiniteNumber(generation) || floor([generation doubleValue]) != [generation doubleValue])) return nil;

    NSMutableDictionary *cleanRecords = [NSMutableDictionary dictionaryWithCapacity:records.count];
    for (id rawID in records) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        NSDictionary *record = postID ? ApolloICloudValidatedRecord(records[rawID], writer) : nil;
        if (!postID || !record || cleanRecords[postID]) return nil;
        cleanRecords[postID] = record;
    }
    return @{kJournalVersion: @1, kJournalWriter: writer, kJournalClear: clear ?: @0,
             kJournalGeneration: generation ?: @0,
             kJournalRecords: cleanRecords};
}

static BOOL ApolloICloudRecordWins(NSDictionary *candidate, NSDictionary *current, NSString *timeKey) {
    double candidateTime = [candidate[timeKey] doubleValue];
    double currentTime = [current[timeKey] doubleValue];
    if (candidateTime != currentTime) return candidateTime > currentTime;
    if ([timeKey isEqualToString:kRecordCommentTime]) {
        long long candidateCount = [candidate[kRecordCommentCount] longLongValue];
        long long currentCount = [current[kRecordCommentCount] longLongValue];
        if (candidateCount != currentCount) return candidateCount > currentCount;
    }
    return NO;
}

static NSDictionary *ApolloICloudReadStateJournalByAdoptingGeneration(
    NSDictionary *rawJournal, long long generation) {
    NSDictionary *journal = ApolloICloudReadStateValidatedJournal(rawJournal);
    if (!journal) return nil;
    long long adopted = MAX([journal[kJournalGeneration] longLongValue], generation);
    if (adopted == [journal[kJournalGeneration] longLongValue]) return journal;
    NSMutableDictionary *rebased = [journal mutableCopy];
    rebased[kJournalGeneration] = @(adopted);
    return rebased;
}

NSDictionary *ApolloICloudReadStateMergeJournals(NSArray<NSDictionary *> *journals) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    double clearAt = 0;
    long long generation = 0;
    NSMutableArray *validJournals = [NSMutableArray array];
    for (id rawJournal in journals) {
        NSDictionary *journal = ApolloICloudReadStateValidatedJournal(rawJournal);
        if (journal) {
            generation = MAX(generation, [journal[kJournalGeneration] longLongValue]);
            [validJournals addObject:journal];
        }
    }
    [validJournals sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[kJournalWriter] compare:b[kJournalWriter]];
    }];
    for (NSDictionary *journal in validJournals) {
        // A newer generation is a distributed tombstone for the entire prior
        // journal. Old offline clients can reappear as file-provider conflict
        // versions, but their records must never be resurrected.
        if ([journal[kJournalGeneration] longLongValue] != generation) continue;
        clearAt = MAX(clearAt, [journal[kJournalClear] doubleValue]);
        [journal[kJournalRecords] enumerateKeysAndObjectsUsingBlock:^(NSString *postID, NSDictionary *record, __unused BOOL *stop) {
            NSMutableDictionary *current = [merged[postID] mutableCopy] ?: [NSMutableDictionary dictionary];
            for (NSString *timeKey in @[kRecordRead, kRecordUnread]) {
                if (record[timeKey] && (!current[timeKey] || ApolloICloudRecordWins(record, current, timeKey))) {
                    current[timeKey] = record[timeKey];
                    current[kRecordWriter] = record[kRecordWriter];
                }
            }
            if (record[kRecordCommentTime] && (!current[kRecordCommentTime] ||
                ApolloICloudRecordWins(record, current, kRecordCommentTime))) {
                current[kRecordCommentTime] = record[kRecordCommentTime];
                current[kRecordCommentCount] = record[kRecordCommentCount];
                current[kRecordWriter] = record[kRecordWriter];
            }
            merged[postID] = current;
        }];
    }
    if (merged.count > kMaximumJournalRecords) {
        NSArray *oldestFirst = [merged keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double aTime = MAX(MAX([a[kRecordRead] doubleValue], [a[kRecordUnread] doubleValue]), [a[kRecordCommentTime] doubleValue]);
            double bTime = MAX(MAX([b[kRecordRead] doubleValue], [b[kRecordUnread] doubleValue]), [b[kRecordCommentTime] doubleValue]);
            return aTime < bTime ? NSOrderedAscending : aTime > bTime ? NSOrderedDescending : NSOrderedSame;
        }];
        NSUInteger removeCount = merged.count - kMaximumJournalRecords;
        for (NSUInteger index = 0; index < removeCount; index++) {
            NSDictionary *record = merged[oldestFirst[index]];
            // A compaction floor prevents an old device or conflict version
            // from resurrecting a read whose individual tombstone was pruned.
            clearAt = MAX(clearAt, MAX([record[kRecordRead] doubleValue], [record[kRecordUnread] doubleValue]));
            [merged removeObjectForKey:oldestFirst[index]];
        }
    }
    return @{kJournalVersion: @1, kJournalWriter: @"merged", kJournalClear: @(clearAt),
             kJournalGeneration: @(generation),
             kJournalRecords: merged};
}

NSArray<NSString *> *ApolloICloudReadStateProjectedReadIDs(NSDictionary *merged, NSUInteger limit) {
    NSDictionary *journal = ApolloICloudReadStateValidatedJournal(merged);
    if (!journal || limit == 0) return @[];
    double clearAt = [journal[kJournalClear] doubleValue];
    NSMutableArray *rows = [NSMutableArray array];
    [journal[kJournalRecords] enumerateKeysAndObjectsUsingBlock:^(NSString *postID, NSDictionary *record, __unused BOOL *stop) {
        double readAt = [record[kRecordRead] doubleValue];
        if (readAt > MAX(clearAt, [record[kRecordUnread] doubleValue])) {
            [rows addObject:@{ @"id": postID, @"time": @(readAt), @"writer": record[kRecordWriter] ?: @"" }];
        }
    }];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult time = [a[@"time"] compare:b[@"time"]];
        return time != NSOrderedSame ? time : [a[@"id"] compare:b[@"id"]];
    }];
    if (rows.count > limit) [rows removeObjectsInRange:NSMakeRange(0, rows.count - limit)];
    return [rows valueForKey:@"id"];
}

NSData *ApolloICloudReadStateProjectedCommentData(NSDictionary *merged, NSUInteger limit) {
    NSDictionary *journal = ApolloICloudReadStateValidatedJournal(merged);
    if (!journal || limit == 0) return [NSJSONSerialization dataWithJSONObject:@[] options:0 error:nil];
    NSMutableArray *rows = [NSMutableArray array];
    [journal[kJournalRecords] enumerateKeysAndObjectsUsingBlock:^(NSString *postID, NSDictionary *record, __unused BOOL *stop) {
        if (record[kRecordCommentTime] && record[kRecordCommentCount]) {
            [rows addObject:@{ @"id": postID, @"time": record[kRecordCommentTime],
                               @"count": record[kRecordCommentCount], @"writer": record[kRecordWriter] ?: @"" }];
        }
    }];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult time = [a[@"time"] compare:b[@"time"]];
        return time != NSOrderedSame ? time : [a[@"id"] compare:b[@"id"]];
    }];
    if (rows.count > limit) [rows removeObjectsInRange:NSMakeRange(0, rows.count - limit)];
    NSMutableArray *native = [NSMutableArray arrayWithCapacity:rows.count * 2];
    for (NSDictionary *row in rows) {
        [native addObject:row[@"id"]];
        [native addObject:@{ @"timestamp": row[@"time"], @"totalComments": row[@"count"] }];
    }
    return [NSJSONSerialization dataWithJSONObject:native options:0 error:nil];
}

NSDictionary *ApolloICloudReadStateJournalByCapturing(NSDictionary *rawJournal,
    NSArray<NSString *> *readIDs, NSDictionary<NSString *, NSDictionary *> *comments,
    NSArray<NSString *> *previousReadIDs, NSTimeInterval now, BOOL historicalSeed) {
    NSDictionary *validated = ApolloICloudReadStateValidatedJournal(rawJournal);
    if (!validated) return rawJournal ?: @{};
    NSMutableDictionary *journal = [validated mutableCopy];
    NSMutableDictionary *records = [journal[kJournalRecords] mutableCopy];
    NSString *writer = journal[kJournalWriter];
    NSMutableDictionary<NSString *, NSNumber *> *previousIndexes = previousReadIDs
        ? [NSMutableDictionary dictionaryWithCapacity:previousReadIDs.count] : nil;
    [previousReadIDs enumerateObjectsUsingBlock:^(NSString *postID, NSUInteger index, __unused BOOL *stop) {
        if (!previousIndexes[postID]) previousIndexes[postID] = @(index);
    }];
    NSUInteger index = 0;
    for (NSString *rawID in readIDs) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        if (!postID) continue;
        NSMutableDictionary *record = [records[postID] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSNumber *previousIndex = previousIndexes[postID];
        BOOL newlyObserved = previousReadIDs &&
            (!previousIndex || index > previousIndex.unsignedIntegerValue);
        if (!record[kRecordRead] || newlyObserved) {
            record[kRecordRead] = historicalSeed && !previousReadIDs
                ? @(1 + (double)index / 1e6) : @(now - (double)(readIDs.count - index) / 1000.0);
            record[kRecordWriter] = writer;
        }
        index++;
        records[postID] = record;
    }
    [comments enumerateKeysAndObjectsUsingBlock:^(NSString *rawID, NSDictionary *snapshot, __unused BOOL *stop) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        NSNumber *timestamp = snapshot[@"timestamp"];
        NSNumber *count = snapshot[@"totalComments"];
        if (!postID || !ApolloICloudFiniteNumber(timestamp) || !ApolloICloudFiniteNumber(count) ||
            floor(count.doubleValue) != count.doubleValue) return;
        NSMutableDictionary *record = [records[postID] mutableCopy] ?: [NSMutableDictionary dictionary];
        BOOL newerTime = !record[kRecordCommentTime] || timestamp.doubleValue > [record[kRecordCommentTime] doubleValue];
        BOOL higherEqualTimeCount = record[kRecordCommentTime] &&
            timestamp.doubleValue == [record[kRecordCommentTime] doubleValue] &&
            count.longLongValue > [record[kRecordCommentCount] longLongValue];
        if (newerTime || higherEqualTimeCount) {
            record[kRecordCommentTime] = @([timestamp doubleValue]);
            record[kRecordCommentCount] = @([count longLongValue]);
            record[kRecordWriter] = writer;
            records[postID] = record;
        }
    }];
    journal[kJournalRecords] = records;
    return journal;
}

NSNotificationName const ApolloICloudReadStateDidChangeNotification = @"ApolloICloudReadStateDidChangeNotification";

static NSError *ApolloICloudReadStateError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloICloudReadState" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"iCloud Drive read-state sync is unavailable."}];
}

static NSDictionary *ApolloICloudReadStateJournalAtURL(NSURL *url, NSError **error) {
    NSNumber *regular = nil;
    NSNumber *symlink = nil;
    NSNumber *size = nil;
    if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error] ||
        ![url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:error] ||
        ![url getResourceValue:&size forKey:NSURLFileSizeKey error:error]) return nil;
    if (!regular.boolValue || symlink.boolValue || size.unsignedLongLongValue > kMaximumJournalBytes) {
        if (error) *error = ApolloICloudReadStateError(
            @"The shared read-state file is unsafe or too large. It was not overwritten.");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data) return nil;
    id raw = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:error];
    NSDictionary *journal = ApolloICloudReadStateValidatedJournal(raw);
    if (!journal && error && !*error) *error = ApolloICloudReadStateError(
        @"The shared read-state file is invalid. It was not overwritten.");
    return journal;
}

NSDictionary *ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
    NSURL *selectedFolderURL, NSDictionary *localJournal, NSError **error) {
    NSDictionary *validLocal = ApolloICloudReadStateValidatedJournal(localJournal);
    if (!selectedFolderURL.isFileURL || !validLocal) {
        if (error) *error = ApolloICloudReadStateError(@"The selected folder or local read state is invalid.");
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *namespaceURL = [selectedFolderURL
        URLByAppendingPathComponent:@"Apollo Reborn Sync" isDirectory:YES];
    __block NSError *workError = nil;
    BOOL directoryReady = NO;
    if ([fm fileExistsAtPath:namespaceURL.path isDirectory:&directoryReady]) {
        NSNumber *symlink = nil;
        [namespaceURL getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:&workError];
        directoryReady = directoryReady && !workError && !symlink.boolValue;
        if (!directoryReady && !workError) workError = ApolloICloudReadStateError(
            @"Apollo Reborn Sync is not a safe folder. Read state was not changed.");
    } else {
        directoryReady = [fm createDirectoryAtURL:namespaceURL
                       withIntermediateDirectories:NO attributes:nil error:&workError];
    }
    if (!directoryReady) {
        if (error) *error = workError ?:
            ApolloICloudReadStateError(@"Could not open Apollo Reborn Sync in the selected folder.");
        return nil;
    }

    NSURL *stateURL = [namespaceURL URLByAppendingPathComponent:@"Read State.plist" isDirectory:NO];
    __block NSDictionary *merged = nil;
    void (^mergeAccessor)(NSURL *) = ^(NSURL *coordinatedURL) {
            if (![fm fileExistsAtPath:coordinatedURL.path]) {
                NSData *initialData = [NSPropertyListSerialization dataWithPropertyList:validLocal
                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:&workError];
                if (!initialData || initialData.length > kMaximumJournalBytes ||
                    ![initialData writeToURL:coordinatedURL options:NSDataWritingAtomic error:&workError]) {
                    if (!workError) workError = ApolloICloudReadStateError(
                        @"Could not create the shared read-state file.");
                    return;
                }
                merged = validLocal;
                return;
            }
            NSDictionary *current = ApolloICloudReadStateJournalAtURL(coordinatedURL, &workError);
            if (!current) return;
            NSMutableArray<NSDictionary *> *conflictJournals = [NSMutableArray array];
            long long activeGeneration = MAX([validLocal[kJournalGeneration] longLongValue],
                                             [current[kJournalGeneration] longLongValue]);
            NSArray<NSFileVersion *> *conflicts = [NSFileVersion unresolvedConflictVersionsOfItemAtURL:coordinatedURL] ?: @[];
            for (NSFileVersion *version in conflicts) {
                NSDictionary *conflict = ApolloICloudReadStateJournalAtURL(version.URL, &workError);
                if (!conflict) return;
                activeGeneration = MAX(activeGeneration, [conflict[kJournalGeneration] longLongValue]);
                [conflictJournals addObject:conflict];
            }
            // The joining device and the provider's current file are both live
            // sources. Adopt the highest observed reset generation before the
            // merge so neither is mistaken for a stale conflict version. Only
            // historical NSFileVersion conflicts retain their old generation.
            NSMutableArray<NSDictionary *> *journals = [NSMutableArray arrayWithObjects:
                ApolloICloudReadStateJournalByAdoptingGeneration(validLocal, activeGeneration),
                ApolloICloudReadStateJournalByAdoptingGeneration(current, activeGeneration), nil];
            [journals addObjectsFromArray:conflictJournals];
            merged = ApolloICloudReadStateMergeJournals(journals);
            // Polling a converged folder must not create a new provider upload
            // or conflict version. Conflicts still take the replacement path
            // so their versions can be marked resolved below.
            if (conflicts.count == 0 && [merged isEqual:current]) return;
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:merged
                format:NSPropertyListBinaryFormat_v1_0 options:0 error:&workError];
            if (!data || data.length > kMaximumJournalBytes) {
                if (!workError) workError = ApolloICloudReadStateError(
                    @"The merged read state is too large. The shared file was not overwritten.");
                merged = nil;
                return;
            }
            if (![data writeToURL:coordinatedURL options:NSDataWritingAtomic error:&workError]) {
                merged = nil;
                return;
            }
            for (NSFileVersion *version in conflicts) version.resolved = YES;
            if (conflicts.count > 0) [NSFileVersion removeOtherVersionsOfItemAtURL:coordinatedURL error:nil];
        };
    NSError *coordinationError = nil;
#if defined(APOLLO_ICLOUD_READ_STATE_TESTS)
    // Command-line Foundation harnesses have no file-provider process and
    // NSFileCoordinator rejects even ordinary temporary URLs. Exercise the
    // exact accessor against synthetic files; the simulator scenario covers
    // the coordinator wrapper in an iOS process.
    mergeAccessor(stateURL);
#else
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateWritingItemAtURL:stateURL options:NSFileCoordinatorWritingForReplacing
        error:&coordinationError byAccessor:mergeAccessor];
#endif
    if (!merged && error) *error = workError ?: coordinationError ?:
        ApolloICloudReadStateError(@"Could not update the shared read-state file. Local history is unchanged.");
    return merged;
}

#if !defined(APOLLO_ICLOUD_READ_STATE_TESTS)

static NSURL *ApolloICloudReadStateURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ApolloReborn/ICloudReadState/state.plist"];
}

static NSURL *ApolloICloudReadStateConsentURL(void) {
    return [ApolloICloudReadStateURL().URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"consent.plist"];
}

BOOL ApolloICloudReadStateInstallationConsentEnabled(void) {
    NSString *folderIdentifier = ApolloICloudBackupStore.sharedStore.selectedFolderConsentIdentifier;
    return folderIdentifier && ApolloICloudReadStateConsentAtURLMatchesFolder(
        ApolloICloudReadStateConsentURL(), folderIdentifier);
}

@interface ApolloICloudReadState ()
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL available;
@property (nonatomic, copy) NSString *availabilityMessage;
@property (nonatomic, strong) NSMutableDictionary *journal;
@property (nonatomic, strong) NSTimer *uploadTimer;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic) BOOL applyingProjection;
@property (nonatomic, copy) NSArray<NSString *> *lastObservedReadIDs;
@property (nonatomic) BOOL hasObservedReadIDs;
@property (nonatomic) BOOL syncInFlight;
@property (nonatomic) BOOL syncPending;
@end

@implementation ApolloICloudReadState

+ (instancetype)sharedManager {
    static ApolloICloudReadState *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [self new]; });
    return manager;
}

- (instancetype)init {
    return [super init];
}

- (BOOL)isEnabled { return sICloudReadStateSyncEnabled; }

- (NSDictionary *)loadOrCreateJournal {
    NSData *data = [NSData dataWithContentsOfURL:ApolloICloudReadStateURL()];
    NSDictionary *saved = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    NSDictionary *valid = ApolloICloudReadStateValidatedJournal(saved);
    if (valid) return valid;
    NSString *writer = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
    return @{kJournalVersion: @1, kJournalWriter: writer, kJournalClear: @0,
             kJournalGeneration: @0,
             kJournalRecords: @{}};
}

- (void)saveJournal {
    NSURL *url = ApolloICloudReadStateURL();
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:nil];
    [url.URLByDeletingLastPathComponent setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.journal
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:nil];
}

- (void)start {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    if (self.started) return;
    self.started = YES;
    if (!self.enabled) return;
    self.journal = [[self loadOrCreateJournal] mutableCopy];
    self.available = NO;
    self.availabilityMessage = @"Connecting to Selected Folder…";
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(localDidChange:)
        name:ApolloPostReadStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshForLifecycle:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(flushForLifecycle:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(selectedFolderDidChange:)
        name:ApolloICloudBackupStoreDidChangeNotification object:nil];
    [self captureLocalStateUsingHistoricalSeed:YES];
    [self syncWithSelectedFolderApplyingRemote:YES];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self
        selector:@selector(pollSelectedFolder:) userInfo:nil repeats:YES];
}

- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"iCloud Drive read-state setting is main-thread owned");
    NSString *folderIdentifier = ApolloICloudBackupStore.sharedStore.selectedFolderConsentIdentifier;
    if (enabled && folderIdentifier.length == 0) {
        self.available = NO;
        self.availabilityMessage = @"Choose an iCloud Drive folder in Backup Settings first.";
        if (error) *error = ApolloICloudReadStateError(self.availabilityMessage);
        return NO;
    }
    if (enabled) {
        NSError *consentError = nil;
        if (!ApolloICloudReadStateWriteConsentAtURL(ApolloICloudReadStateConsentURL(), YES,
                                                     folderIdentifier, &consentError)) {
            if (error) *error = consentError ?: ApolloICloudReadStateError(
                @"Could not save this installation's read-state sync consent.");
            return NO;
        }
        if (!self.journal) self.journal = [[self loadOrCreateJournal] mutableCopy];
        sICloudReadStateSyncEnabled = YES;
        self.started = NO;
        [self start];
    } else {
        // Explicit opt-out is fail-closed in memory. Marker cleanup can report
        // a persistence error, but it must never leave uploads or polls alive.
        sICloudReadStateSyncEnabled = NO;
        [self.uploadTimer invalidate];
        self.uploadTimer = nil;
        [self.pollTimer invalidate];
        self.pollTimer = nil;
        [NSNotificationCenter.defaultCenter removeObserver:self];
        self.started = NO;
        self.syncPending = NO;
        self.availabilityMessage = @"Off";
        [NSNotificationCenter.defaultCenter postNotificationName:
            ApolloICloudReadStateDidChangeNotification object:self];
        NSError *consentError = nil;
        if (!ApolloICloudReadStateWriteConsentAtURL(ApolloICloudReadStateConsentURL(), NO,
                                                     folderIdentifier, &consentError)) {
            if (error) *error = consentError ?: ApolloICloudReadStateError(
                @"Sync is off, but its local consent marker could not be removed.");
            return NO;
        }
    }
    return YES;
}

- (void)selectedFolderDidChange:(__unused NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self selectedFolderDidChange:nil]; });
        return;
    }
    if (self.enabled && !ApolloICloudReadStateInstallationConsentEnabled()) {
        NSError *error = nil;
        [self setEnabled:NO error:&error];
        self.availabilityMessage = @"Off — confirm sync for the newly selected folder.";
        [NSNotificationCenter.defaultCenter postNotificationName:
            ApolloICloudReadStateDidChangeNotification object:self];
    }
}

- (void)refreshForLifecycle:(__unused NSNotification *)note {
    if (!self.enabled) return;
    [self captureLocalStateUsingHistoricalSeed:!self.hasObservedReadIDs];
    [self syncWithSelectedFolderApplyingRemote:YES];
}
- (void)flushForLifecycle:(__unused NSNotification *)note {
    [self.uploadTimer invalidate];
    self.uploadTimer = nil;
    [self captureLocalStateAndUpload];
}

- (void)pollSelectedFolder:(__unused NSTimer *)timer {
    if (self.enabled) [self syncWithSelectedFolderApplyingRemote:YES];
}

- (void)localDidChange:(__unused NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self localDidChange:nil]; });
        return;
    }
    if (self.applyingProjection) return;
    [self.uploadTimer invalidate];
    self.uploadTimer = [NSTimer scheduledTimerWithTimeInterval:0.75 target:self
        selector:@selector(captureLocalStateAndUpload) userInfo:nil repeats:NO];
}

- (void)recordPostIDAsUnread:(NSString *)postID {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self recordPostIDAsUnread:postID]; });
        return;
    }
    if (!self.enabled) return;
    NSString *bare = ApolloICloudBarePostID(postID);
    if (!bare) return;
    NSMutableDictionary *records = [self.journal[kJournalRecords] mutableCopy];
    NSMutableDictionary *record = [records[bare] mutableCopy] ?: [NSMutableDictionary dictionary];
    record[kRecordUnread] = @([NSDate date].timeIntervalSince1970);
    record[kRecordWriter] = self.journal[kJournalWriter];
    records[bare] = record;
    self.journal[kJournalRecords] = records;
    [self saveJournal];
    [self flushNow];
}

- (void)recordClearAll {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self recordClearAll]; });
        return;
    }
    if (!self.enabled) return;
    self.journal[kJournalClear] = @([NSDate date].timeIntervalSince1970);
    [self saveJournal];
    [self flushNow];
}

- (void)captureLocalStateAndUpload {
    [self captureLocalStateUsingHistoricalSeed:NO];
    [self syncWithSelectedFolderApplyingRemote:YES];
}

- (void)captureLocalStateUsingHistoricalSeed:(BOOL)historicalSeed {
    if (!self.enabled) return;
    NSArray *readIDs = ApolloReadPostIDsSnapshot();
    if (!readIDs) readIDs = [NSUserDefaults.standardUserDefaults stringArrayForKey:@"ReadPostIDs"] ?: @[];
    NSDictionary *comments = ApolloRawPostCommentSnapshots();
    if (!readIDs) return;
    double now = [NSDate date].timeIntervalSince1970;
    NSMutableArray *observed = [NSMutableArray array];
    NSMutableSet *observedSet = [NSMutableSet set];
    for (NSString *rawID in readIDs) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        if (postID && ![observedSet containsObject:postID]) {
            [observed addObject:postID];
            [observedSet addObject:postID];
        }
    }
    self.journal = [ApolloICloudReadStateJournalByCapturing(self.journal, observed, comments,
        self.hasObservedReadIDs ? self.lastObservedReadIDs : nil, now, historicalSeed) mutableCopy];
    self.lastObservedReadIDs = observed;
    self.hasObservedReadIDs = YES;
    [self pruneOwnJournal];
    [self saveJournal];
}

- (void)pruneOwnJournal {
    NSMutableDictionary *records = [self.journal[kJournalRecords] mutableCopy];
    if (records.count <= kMaximumJournalRecords) return;
    NSArray *keys = [records keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double aTime = MAX(MAX([a[kRecordRead] doubleValue], [a[kRecordUnread] doubleValue]), [a[kRecordCommentTime] doubleValue]);
        double bTime = MAX(MAX([b[kRecordRead] doubleValue], [b[kRecordUnread] doubleValue]), [b[kRecordCommentTime] doubleValue]);
        return aTime < bTime ? NSOrderedAscending : aTime > bTime ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSUInteger i = 0; i < keys.count - kMaximumJournalRecords; i++) [records removeObjectForKey:keys[i]];
    self.journal[kJournalRecords] = records;
}

- (void)flushNow {
    [self syncWithSelectedFolderApplyingRemote:YES];
}

- (void)applyMergedJournal:(NSDictionary *)merged {
    NSUInteger configured = sReadPostMaxCount > 0 ? MIN((NSUInteger)sReadPostMaxCount, 5000u) : 5000u;
    NSArray *readIDs = ApolloICloudReadStateProjectedReadIDs(merged, configured);
    NSData *comments = ApolloICloudReadStateProjectedCommentData(merged, 1000);
    // Adopt the converged values before posting the projection notification.
    // The delayed observer then sees existing timestamps instead of turning
    // remote reads into newly-viewed local reads.
    NSMutableDictionary *convergedLocal = [merged mutableCopy];
    convergedLocal[kJournalWriter] = self.journal[kJournalWriter];
    self.journal = convergedLocal;
    [self saveJournal];
    self.applyingProjection = YES;
    ApolloApplySyncedPostReadState(readIDs, comments);
    self.applyingProjection = NO;
    self.lastObservedReadIDs = readIDs;
    self.hasObservedReadIDs = YES;
}

- (void)syncWithSelectedFolderApplyingRemote:(BOOL)applyRemote {
    NSAssert(NSThread.isMainThread, @"Selected-folder sync state is main-thread owned");
    if (!self.enabled) return;
    if (self.syncInFlight) {
        self.syncPending = YES;
        return;
    }
    self.syncInFlight = YES;
    self.syncPending = NO;
    NSDictionary *snapshot = [self.journal copy];
    __weak typeof(self) weakSelf = self;
    [ApolloICloudBackupStore.sharedStore performSelectedFolderOperation:
        ^id(NSURL *folderURL, NSError **operationError) {
            return ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
                folderURL, snapshot, operationError);
        } completion:^(id result, NSError *operationError) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.syncInFlight = NO;
            if (!strongSelf.enabled) return;
            NSDictionary *folderJournal = ApolloICloudReadStateValidatedJournal(result);
            if (!folderJournal || operationError) {
                strongSelf.available = NO;
                strongSelf.availabilityMessage = operationError.localizedDescription ?:
                    @"The selected folder is unavailable. Local read history will retry later.";
                ApolloLog(@"[iCloudReadState] Selected-folder sync deferred: %@",
                    strongSelf.availabilityMessage);
                [NSNotificationCenter.defaultCenter postNotificationName:
                    ApolloICloudReadStateDidChangeNotification object:strongSelf];
                return;
            }

            // Local events may have landed while coordinated I/O was running.
            // Merge again before projection, then schedule one more write when
            // the returned file does not yet include those events.
            long long activeGeneration = MAX([folderJournal[kJournalGeneration] longLongValue],
                [strongSelf.journal[kJournalGeneration] longLongValue]);
            NSDictionary *activeFolder = ApolloICloudReadStateJournalByAdoptingGeneration(
                folderJournal, activeGeneration);
            NSDictionary *activeLocal = ApolloICloudReadStateJournalByAdoptingGeneration(
                strongSelf.journal, activeGeneration);
            NSDictionary *combined = ApolloICloudReadStateMergeJournals(@[activeFolder, activeLocal]);
            NSMutableDictionary *localWriter = [combined mutableCopy];
            localWriter[kJournalWriter] = strongSelf.journal[kJournalWriter];
            strongSelf.journal = localWriter;
            if (applyRemote) [strongSelf applyMergedJournal:combined];
            else [strongSelf saveJournal];
            strongSelf.available = YES;
            NSString *folderName = ApolloICloudBackupStore.sharedStore.selectedFolderName;
            strongSelf.availabilityMessage = folderName.length > 0
                ? [NSString stringWithFormat:@"Active · %@", folderName]
                : @"Active · Selected Folder";
            [NSNotificationCenter.defaultCenter postNotificationName:
                ApolloICloudReadStateDidChangeNotification object:strongSelf];
            BOOL needsAnotherWrite = ![combined isEqualToDictionary:folderJournal];
            if (needsAnotherWrite || strongSelf.syncPending) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf syncWithSelectedFolderApplyingRemote:YES];
                });
            }
        }];
}

@end
#endif
