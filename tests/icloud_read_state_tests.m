#import <Foundation/Foundation.h>
#import "ApolloICloudReadState.h"

static NSUInteger failures;
static void Check(BOOL condition, NSString *message) {
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition) failures++;
}

static NSDictionary *Journal(NSString *writer, double clearAt, NSDictionary *records) {
    return @{@"v": @1, @"w": writer, @"clear": @(clearAt), @"records": records};
}

static NSDictionary *Record(NSNumber *readAt, NSNumber *unreadAt, NSNumber *commentAt, NSNumber *count,
                            NSString *writer) {
    NSMutableDictionary *record = [@{@"w": writer} mutableCopy];
    if (readAt) record[@"r"] = readAt;
    if (unreadAt) record[@"u"] = unreadAt;
    if (commentAt) record[@"c"] = commentAt;
    if (count) record[@"n"] = count;
    return record;
}

int main(void) {
    @autoreleasepool {
        NSDictionary *first = Journal(@"writer-a", 0, @{
            @"abc": Record(@10, nil, @20, @4, @"writer-a"),
            @"gone": Record(@5, @12, nil, nil, @"writer-a"),
        });
        NSDictionary *second = Journal(@"writer-b", 0, @{
            @"abc": Record(@15, nil, @22, @7, @"writer-b"),
            @"fresh": Record(@30, nil, nil, nil, @"writer-b"),
        });

        Check(ApolloICloudReadStateValidatedJournal(first) != nil, @"valid journal is accepted");
        Check(ApolloICloudReadStateValidatedJournal(@{@"v": @2}) == nil, @"unknown schema is rejected");
        Check(ApolloICloudReadStateValidatedJournal(Journal(@"w", 0,
            @{@"bad id!": Record(@1, nil, nil, nil, @"w")})) == nil, @"invalid post ID is rejected");
        Check(ApolloICloudReadStateValidatedJournal(Journal(@"w", 0,
            @{@"abc": Record(@1, nil, @2, @1.5, @"w")})) == nil, @"fractional comment count is rejected");
        Check(ApolloICloudReadStateValidatedJournal(Journal(@"w", 0,
            @{@"abc": Record(@([NSDate date].timeIntervalSince1970 + 2 * 86400), nil, nil, nil, @"w")})) == nil,
            @"far-future clock poison is rejected");

        NSDictionary *mergedAB = ApolloICloudReadStateMergeJournals(@[first, second]);
        NSDictionary *mergedBA = ApolloICloudReadStateMergeJournals(@[second, first]);
        NSArray *expected = @[@"abc", @"fresh"];
        Check([ApolloICloudReadStateProjectedReadIDs(mergedAB, 5000) isEqual:expected],
              @"newer read wins and explicit unread remains unread");
        Check([ApolloICloudReadStateProjectedReadIDs(mergedAB, 5000)
            isEqual:ApolloICloudReadStateProjectedReadIDs(mergedBA, 5000)], @"merge is commutative");
        Check([[ApolloICloudReadStateMergeJournals(@[first, first]) objectForKey:@"records"]
            isEqual:[ApolloICloudReadStateMergeJournals(@[first]) objectForKey:@"records"]], @"merge is idempotent");
        NSDictionary *emptyDevice = Journal(@"new-device", 0, @{});
        Check([ApolloICloudReadStateMergeJournals(@[mergedAB, emptyDevice]) isEqual:mergedAB],
              @"receiving converged shared state reaches a no-write fixed point");
        NSMutableDictionary *adopted = [mergedAB mutableCopy];
        adopted[@"w"] = @"device-b";
        NSDictionary *capturedAgain = ApolloICloudReadStateJournalByCapturing(adopted, expected,
            @{@"abc": @{@"timestamp": @22, @"totalComments": @7}}, expected, 999, NO);
        Check([capturedAgain isEqual:adopted],
              @"capturing a projected remote snapshot preserves timestamps and writer metadata");

        NSArray *historicalOrder = @[@"z-last-alphabetically", @"a-first-alphabetically", @"middle"];
        NSDictionary *historical = ApolloICloudReadStateJournalByCapturing(
            Journal(@"device", 0, @{}), historicalOrder, @{}, nil, 100, YES);
        Check([ApolloICloudReadStateProjectedReadIDs(historical, 5000) isEqual:historicalOrder],
              @"historical seed timestamps preserve native Recently Read order");
        NSArray *revisitedOrder = @[@"a-first-alphabetically", @"middle", @"z-last-alphabetically"];
        NSDictionary *revisited = ApolloICloudReadStateJournalByCapturing(
            historical, revisitedOrder, @{}, historicalOrder, 200, NO);
        Check([ApolloICloudReadStateProjectedReadIDs(revisited, 5000) isEqual:revisitedOrder] &&
              [revisited[@"records"][@"z-last-alphabetically"][@"r"] doubleValue] > 100,
              @"moving a previously read post toward the tail refreshes its ordering clock");
        NSDictionary *revisitedAgain = ApolloICloudReadStateJournalByCapturing(
            revisited, revisitedOrder, @{}, revisitedOrder, 300, NO);
        Check([revisitedAgain isEqual:revisited],
              @"capturing unchanged ordered history does not churn timestamps");

        NSDictionary *cleared = ApolloICloudReadStateMergeJournals(@[first, Journal(@"writer-c", 25, @{})]);
        Check(ApolloICloudReadStateProjectedReadIDs(cleared, 5000).count == 0,
              @"clear marker suppresses stale reads");

        NSData *comments = ApolloICloudReadStateProjectedCommentData(mergedAB, 1000);
        NSArray *native = [NSJSONSerialization JSONObjectWithData:comments options:0 error:nil];
        Check(native.count == 2 && [native[0] isEqual:@"abc"] && [native[1][@"timestamp"] isEqual:@22] &&
              [native[1][@"totalComments"] isEqual:@7], @"latest view timestamp and baseline are projected");

        NSDictionary *tie = ApolloICloudReadStateMergeJournals(@[
            Journal(@"a", 0, @{@"same": Record(nil, nil, @50, @8, @"a")}),
            Journal(@"b", 0, @{@"same": Record(nil, nil, @50, @9, @"b")}),
        ]);
        NSArray *tieNative = [NSJSONSerialization JSONObjectWithData:
            ApolloICloudReadStateProjectedCommentData(tie, 1000) options:0 error:nil];
        Check([tieNative[1][@"totalComments"] isEqual:@9], @"higher count deterministically wins equal timestamp");

        NSMutableDictionary *many = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 12; i++) {
            many[[NSString stringWithFormat:@"p%02lu", (unsigned long)i]] =
                Record(@(i + 1), nil, @(i + 1), @(i), @"cap");
        }
        NSDictionary *capped = ApolloICloudReadStateMergeJournals(@[Journal(@"cap", 0, many)]);
        NSArray *readCap = ApolloICloudReadStateProjectedReadIDs(capped, 5);
        Check(readCap.count == 5 && [readCap.firstObject isEqual:@"p07"] && [readCap.lastObject isEqual:@"p11"],
              @"read projection keeps newest entries at cap");
        NSArray *commentCap = [NSJSONSerialization JSONObjectWithData:
            ApolloICloudReadStateProjectedCommentData(capped, 3) options:0 error:nil];
        Check(commentCap.count == 6 && [commentCap[0] isEqual:@"p09"] && [commentCap[4] isEqual:@"p11"],
              @"comment projection keeps newest baselines at cap");

        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *fixture = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        [fm createDirectoryAtURL:fixture withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *backup = [fixture URLByAppendingPathComponent:@"Keep.apollobackup"];
        NSData *backupBytes = [@"credential-bearing fixture" dataUsingEncoding:NSUTF8StringEncoding];
        [backupBytes writeToURL:backup atomically:YES];
        NSError *folderError = nil;
        NSDictionary *fileFirst = ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
            fixture, first, &folderError);
        NSURL *syncFile = [[fixture URLByAppendingPathComponent:@"Apollo Reborn Sync" isDirectory:YES]
            URLByAppendingPathComponent:@"Read State.plist"];
        Check(fileFirst != nil && folderError == nil && [fm fileExistsAtPath:syncFile.path],
              @"selected-folder merge creates only the namespaced read-state file");
        NSDictionary *fileSecond = ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
            fixture, second, &folderError);
        Check([ApolloICloudReadStateProjectedReadIDs(fileSecond, 5000) isEqual:expected],
              @"sequential device fixtures converge through coordinated file IO");
        NSNumber *inodeBefore = [[fm attributesOfItemAtPath:syncFile.path error:nil]
            objectForKey:NSFileSystemFileNumber];
        NSDictionary *fileNoOp = ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
            fixture, fileSecond, &folderError);
        NSNumber *inodeAfter = [[fm attributesOfItemAtPath:syncFile.path error:nil]
            objectForKey:NSFileSystemFileNumber];
        Check([fileNoOp isEqual:fileSecond] && [inodeAfter isEqual:inodeBefore],
              @"converged poll returns without replacing the shared file");
        NSMutableDictionary *higherJoining = [Journal(@"higher-joining", 0,
            @{@"higher-local": Record(@40, nil, nil, nil, @"higher-joining")}) mutableCopy];
        higherJoining[@"g"] = @2;
        NSDictionary *fileHigherJoining = ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
            fixture, higherJoining, &folderError);
        Check([fileHigherJoining[@"g"] isEqual:@2] &&
              fileHigherJoining[@"records"][@"higher-local"] != nil &&
              fileHigherJoining[@"records"][@"fresh"] != nil,
              @"higher-generation joining device preserves current folder records");
        NSDictionary *lowerJoining = Journal(@"lower-joining", 0,
            @{@"lower-local": Record(@50, nil, nil, nil, @"lower-joining")});
        NSDictionary *fileLowerJoining = ApolloICloudReadStateMergeJournalAtSelectedFolderURL(
            fixture, lowerJoining, &folderError);
        Check([fileLowerJoining[@"g"] isEqual:@2] &&
              fileLowerJoining[@"records"][@"lower-local"] != nil &&
              fileLowerJoining[@"records"][@"higher-local"] != nil,
              @"lower-generation joining device adopts folder generation without local data loss");
        Check([[NSData dataWithContentsOfURL:backup] isEqual:backupBytes],
              @"read-state sync leaves credential-bearing backup archives untouched");

        NSData *corrupt = [@"not a journal" dataUsingEncoding:NSUTF8StringEncoding];
        [corrupt writeToURL:syncFile atomically:YES];
        folderError = nil;
        Check(ApolloICloudReadStateMergeJournalAtSelectedFolderURL(fixture, first, &folderError) == nil &&
              folderError != nil && [[NSData dataWithContentsOfURL:syncFile] isEqual:corrupt],
              @"invalid remote state fails closed without overwrite");
        [fm removeItemAtURL:fixture error:nil];

        NSURL *consentDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSURL *consentURL = [consentDirectory URLByAppendingPathComponent:@"consent.plist"];
        NSError *consentError = nil;
        BOOL consentWritten = ApolloICloudReadStateWriteConsentAtURL(consentURL, YES, @"folder-a", &consentError);
        Check(consentWritten &&
              consentError == nil && ApolloICloudReadStateConsentAtURLMatchesFolder(consentURL, @"folder-a"),
              @"installation-local consent matches the exact selected folder");
        Check(!ApolloICloudReadStateConsentAtURLMatchesFolder(consentURL, @"folder-b"),
              @"changing selected folders requires fresh consent");
        Check(ApolloICloudReadStateWriteConsentAtURL(consentURL, NO, nil, &consentError) &&
              !ApolloICloudReadStateConsentAtURLMatchesFolder(consentURL, @"folder-a"),
              @"disabling removes installation-local consent");
        [fm createDirectoryAtURL:consentDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        [[@"malformed" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:consentURL atomically:YES];
        Check(!ApolloICloudReadStateConsentAtURLMatchesFolder(consentURL, @"folder-a"),
              @"malformed installation-local consent fails closed");
        [fm removeItemAtURL:consentDirectory error:nil];

        NSMutableDictionary *restored = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 5000; i++) {
            restored[[NSString stringWithFormat:@"r%04lu", (unsigned long)i]] =
                Record(@1, nil, nil, nil, @"restore");
        }
        NSDictionary *restoredJournal = ApolloICloudReadStateMergeJournals(@[
            Journal(@"restore", 0, restored), Journal(@"remote", 100, @{})]);
        Check(ApolloICloudReadStateProjectedReadIDs(restoredJournal, 5000).count == 0,
              @"remote clear beats timestamp-less restored history");
        NSData *largePlain = [NSPropertyListSerialization dataWithPropertyList:restoredJournal
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        Check(largePlain.length < 900 * 1024, @"single bounded 5,000-record journal fits the file safety cap");

        NSMutableDictionary *overflowA = [NSMutableDictionary dictionary];
        NSMutableDictionary *overflowB = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 4000; i++) {
            overflowA[[NSString stringWithFormat:@"a%04lu", (unsigned long)i]] = Record(@(i + 1), nil, nil, nil, @"a");
            overflowB[[NSString stringWithFormat:@"b%04lu", (unsigned long)i]] = Record(@(i + 4001), nil, nil, nil, @"b");
        }
        NSDictionary *compacted = ApolloICloudReadStateMergeJournals(@[
            Journal(@"a", 0, overflowA), Journal(@"b", 0, overflowB)]);
        Check([compacted[@"records"] count] == 6500 && [compacted[@"clear"] doubleValue] >= 1500,
              @"concurrent histories compact to one bounded journal with an anti-resurrection floor");
        NSMutableDictionary *generationOne = [first mutableCopy]; generationOne[@"g"] = @1;
        NSMutableDictionary *generationTwo = [second mutableCopy]; generationTwo[@"g"] = @2;
        NSDictionary *newGeneration = ApolloICloudReadStateMergeJournals(@[generationOne, generationTwo]);
        Check([newGeneration[@"g"] isEqual:@2] &&
              [newGeneration[@"records"] objectForKey:@"fresh"] != nil &&
              [newGeneration[@"records"] objectForKey:@"abc"] != nil &&
              [newGeneration[@"records"] objectForKey:@"gone"] == nil,
              @"newer generation tombstones all records from stale conflict versions");

        printf("%lu failure(s)\n", (unsigned long)failures);
        return failures == 0 ? 0 : 1;
    }
}
