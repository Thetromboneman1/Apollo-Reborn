#import <Foundation/Foundation.h>

// INCLUDE_PRODUCTION_MIGRATION

static NSUInteger checks;
static void Check(BOOL condition, NSString *label) {
    checks++;
    if (!condition) { NSLog(@"FAIL %@", label); abort(); }
}

int main(void) {
    @autoreleasepool {
        NSString *domain = [@"ApolloUnreadBadgeMigrationTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        [defaults removePersistentDomainForName:domain];
        // Registered keys must not suppress migration, and must not be saved as
        // user choices when both legacy keys are absent.
        [defaults registerDefaults:@{ UDKeyUnreadBadgeCompactTabBar: @NO,
            UDKeyUnreadBadgeCompactInbox: @NO, UDKeyUnreadBadgeThemeColor: @NO,
            UDKeyInboxBadgeShowUnreadCount: @YES, UDKeyInboxBadgeUseThemeAccent: @NO }];
        ApolloUnreadBadgesMigratePreferences(defaults, domain);
        Check([defaults persistentDomainForName:domain].count == 0, @"empty preferences remain empty");

        for (NSNumber *count in @[@NO, @YES]) {
            for (NSNumber *accent in @[@NO, @YES]) {
                NSDictionary *old = @{ UDKeyInboxBadgeShowUnreadCount: count,
                    UDKeyInboxBadgeUseThemeAccent: accent, @"ProtectedPreference": @"unchanged" };
                [defaults setPersistentDomain:old forName:domain];
                ApolloUnreadBadgesMigratePreferences(defaults, domain);
                NSDictionary *saved = [defaults persistentDomainForName:domain];
                Check([saved[UDKeyUnreadBadgeCompactTabBar] isEqual:@(!count.boolValue)], @"count becomes opposite compact flag");
                Check([saved[UDKeyUnreadBadgeThemeColor] isEqual:accent], @"theme color preserved");
                Check(saved[UDKeyUnreadBadgeCompactInbox] == nil, @"no invented compact inbox choice");
                for (NSString *key in old) Check([saved[key] isEqual:old[key]], @"old and unrelated values preserved");
                ApolloUnreadBadgesMigratePreferences(defaults, domain);
                Check([[defaults persistentDomainForName:domain] isEqual:saved], @"repeat is idempotent");
            }
        }

        for (NSNumber *explicit in @[@NO, @YES]) {
            [defaults setPersistentDomain:@{ UDKeyInboxBadgeShowUnreadCount: explicit,
                UDKeyInboxBadgeUseThemeAccent: @(!explicit.boolValue),
                UDKeyUnreadBadgeCompactTabBar: explicit, UDKeyUnreadBadgeThemeColor: explicit,
                UDKeyUnreadBadgeCompactInbox: @YES } forName:domain];
            NSDictionary *before = [defaults persistentDomainForName:domain];
            ApolloUnreadBadgesMigratePreferences(defaults, domain);
            Check([[defaults persistentDomainForName:domain] isEqual:before], @"explicit new choices win including false");
        }

        [defaults setPersistentDomain:@{ UDKeyInboxBadgeShowUnreadCount: @NO,
            UDKeyInboxBadgeUseThemeAccent: @YES, UDKeyUnreadBadgeCompactTabBar: @NO } forName:domain];
        ApolloUnreadBadgesMigratePreferences(defaults, domain);
        Check(![defaults boolForKey:UDKeyUnreadBadgeCompactTabBar], @"partial migration keeps present false");
        Check([defaults boolForKey:UDKeyUnreadBadgeThemeColor], @"partial migration fills absent theme");

        [defaults setPersistentDomain:@{ UDKeyInboxBadgeShowUnreadCount: @"false",
            UDKeyInboxBadgeUseThemeAccent: @[] } forName:domain];
        ApolloUnreadBadgesMigratePreferences(defaults, domain);
        NSDictionary *invalid = [defaults persistentDomainForName:domain];
        Check(invalid[UDKeyUnreadBadgeCompactTabBar] == nil && invalid[UDKeyUnreadBadgeThemeColor] == nil,
              @"invalid legacy types are ignored");

        // Restore replaces the domain. An old backup must migrate again even
        // after this installation previously had explicit new choices.
        [defaults setPersistentDomain:@{ UDKeyUnreadBadgeCompactTabBar: @NO,
            UDKeyUnreadBadgeThemeColor: @NO } forName:domain];
        [defaults removePersistentDomainForName:domain];
        [defaults setBool:NO forKey:UDKeyInboxBadgeShowUnreadCount];
        [defaults setBool:YES forKey:UDKeyInboxBadgeUseThemeAccent];
        ApolloUnreadBadgesMigratePreferences(defaults, domain);
        Check([defaults boolForKey:UDKeyUnreadBadgeCompactTabBar] && [defaults boolForKey:UDKeyUnreadBadgeThemeColor],
              @"old backup migrates after newer preferences are replaced");
        [defaults removePersistentDomainForName:domain];
        NSLog(@"Unread badge migration: %lu checks passed", (unsigned long)checks);
    }
    return 0;
}
