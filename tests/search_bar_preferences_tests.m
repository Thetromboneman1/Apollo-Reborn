#import <Foundation/Foundation.h>
#import "ApolloState.h"
#import "UserDefaultConstants.h"

static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    NSString *suite = [@"ApolloSearchBarPreferencesTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    [defaults registerDefaults:@{UDKeySearchBarMode: @0, UDKeyShowFeedSearchBar: @YES, UDKeyShowFindInCommentsBar: @YES}];
    // Absence is distinct from an explicit On/Off, even with registered defaults.
    NSArray *legacy = @[NSNull.null, @NO, @YES];
    for (id feed in legacy) for (id comments in legacy) {
        NSMutableDictionary *old = [NSMutableDictionary dictionary];
        if (feed != NSNull.null) old[UDKeyShowFeedSearchBar] = feed;
        if (comments != NSNull.null) old[UDKeyShowFindInCommentsBar] = comments;
        [defaults setPersistentDomain:old forName:suite];
        NSDictionary *persisted = [defaults persistentDomainForName:suite];
        ApolloLoadSearchBarPreferences(persisted);
        Check(!sSearchBarModeExplicit, @"registered On never becomes an explicit choice");
        Check(ApolloSearchBarModeForComments(NO) == (feed == NSNull.null || [feed boolValue] ? ApolloSearchBarModeOn : ApolloSearchBarModeOff), @"each old feed choice survives");
        Check(ApolloSearchBarModeForComments(YES) == (comments == NSNull.null || [comments boolValue] ? ApolloSearchBarModeOn : ApolloSearchBarModeOff), @"each old thread choice survives independently");
        Check([defaults persistentDomainForName:suite][UDKeySearchBarMode] == nil, @"loading does not persist a mode or rewrite the old backup");
        for (NSNumber *mode in @[@0, @1, @2]) {
            NSMutableDictionary *explicit = [old mutableCopy]; explicit[UDKeySearchBarMode] = mode;
            ApolloLoadSearchBarPreferences(explicit);
            Check(sSearchBarModeExplicit && ApolloSearchBarModeForComments(NO) == mode.integerValue && ApolloSearchBarModeForComments(YES) == mode.integerValue, @"explicit new mode wins over every legacy combination");
        }
    }
    for (NSNumber *mode in @[@0, @1, @2]) {
        NSDictionary *mixed = @{UDKeyShowFeedSearchBar: @NO, UDKeyShowFindInCommentsBar: @YES};
        [defaults setPersistentDomain:mixed forName:suite];
        ApolloLoadSearchBarPreferences([defaults persistentDomainForName:suite]);
        ApolloSaveSearchBarMode(defaults, mode.integerValue);
        NSDictionary *saved = [defaults persistentDomainForName:suite];
        Check(sSearchBarModeExplicit && [saved[UDKeySearchBarMode] isEqual:mode], @"picker persists an explicit selection, including re-picking On");
        Check([saved[UDKeyShowFeedSearchBar] isEqual:@NO] && [saved[UDKeyShowFindInCommentsBar] isEqual:@YES], @"selecting a mode retains old keys for backup compatibility");
        Check(ApolloSearchBarModeForComments(NO) == mode.integerValue && ApolloSearchBarModeForComments(YES) == mode.integerValue, @"selection applies to both screens immediately");
        ApolloLoadSearchBarPreferences(saved);
        Check(ApolloSearchBarModeForComments(NO) == mode.integerValue && ApolloSearchBarModeForComments(YES) == mode.integerValue, @"selected mode survives simulated relaunch/backup load");
    }
    ApolloLoadSearchBarPreferences(@{UDKeySearchBarMode: @99, UDKeyShowFeedSearchBar: @NO});
    Check(sSearchBarModeExplicit && ApolloSearchBarModeForComments(NO) == ApolloSearchBarModeOn, @"invalid explicit enum is normalized without reviving legacy overrides");
    ApolloLoadSearchBarPreferences(nil);
    Check(!sSearchBarModeExplicit && ApolloSearchBarModeForComments(NO) == ApolloSearchBarModeOn && ApolloSearchBarModeForComments(YES) == ApolloSearchBarModeOn, @"empty installation defaults to On for both screens");
    [defaults removePersistentDomainForName:suite];
    printf("Search bar preference compatibility: %lu checks passed\n", (unsigned long)checks);
} }
