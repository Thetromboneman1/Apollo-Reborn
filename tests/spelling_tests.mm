#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, ApolloSpellingStyle) {
    ApolloSpellingStyleAmerican = 0,
    ApolloSpellingStyleBritish = 1,
};
typedef NSUInteger UIControlState;

@interface UILabel : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSAttributedString *attributedText;
@end
@implementation UILabel
@end

@interface UIButton : NSObject
@property (nonatomic, copy) NSString *storedTitle;
@property (nonatomic, copy) NSAttributedString *storedAttributedTitle;
- (void)setTitle:(NSString *)title forState:(UIControlState)state;
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state;
@end
@implementation UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state { self.storedTitle = title; }
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state { self.storedAttributedTitle = title; }
@end

@interface UINavigationItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *backButtonTitle;
@end
@implementation UINavigationItem
@end

@interface UIListContentConfiguration : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *secondaryText;
@end
@implementation UIListContentConfiguration
@end

// INSERT_PRODUCTION_SPELLING

static int failures;
#define CHECK(condition, message) do { if (!(condition)) { failures++; fprintf(stderr, "FAIL: %s\n", message); } } while (0)

// Construct from bytes to model identifiers read from account/server data. Short
// strings may be tagged pointers; longer ones are ordinary NSString instances.
static NSString *Dynamic(const char *bytes) {
    return [[NSString alloc] initWithBytes:bytes length:strlen(bytes) encoding:NSUTF8StringEncoding];
}

int main(void) {
    @autoreleasepool {
        sSpellingStyle = ApolloSpellingStyleBritish;
        UILabel *label = [UILabel new];
        label.text = @"Customize Colors";
        CHECK([label.text isEqualToString:@"Customise Colours"], "literal interface labels retain British spelling");
        label.text = @"Favorites";
        CHECK([label.text isEqualToString:@"Favourites"], "single-word interface labels retain British spelling");
        UIButton *chromeButton = [UIButton new];
        [chromeButton setTitle:@"Customize Colors" forState:0];
        CHECK([chromeButton.storedTitle isEqualToString:@"Customise Colours"], "literal button chrome retains British spelling");
        UINavigationItem *chromeNavigation = [UINavigationItem new];
        chromeNavigation.title = @"Customize Colors";
        chromeNavigation.backButtonTitle = @"Favorites";
        CHECK([chromeNavigation.title isEqualToString:@"Customise Colours"] && [chromeNavigation.backButtonTitle isEqualToString:@"Favourites"], "literal navigation chrome retains British spelling");
        UIListContentConfiguration *chromeConfiguration = [UIListContentConfiguration new];
        chromeConfiguration.text = @"Customize Colors";
        chromeConfiguration.secondaryText = @"Favorites";
        CHECK([chromeConfiguration.text isEqualToString:@"Customise Colours"] && [chromeConfiguration.secondaryText isEqualToString:@"Favourites"], "literal list chrome retains British spelling");
        NSAttributedString *literalAttributed = [[NSAttributedString alloc] initWithString:@"Customize Colors" attributes:@{@"test": @1}];
        label.attributedText = literalAttributed;
        CHECK([label.attributedText isEqualToAttributedString:literalAttributed], "attributed setters do not assume literal provenance");
        for (NSString *identifier in @[Dynamic("colors"), Dynamic("favorite"), Dynamic("Customize Colors"), Dynamic("Colors are my favorite behavior")]) {
            label.text = identifier;
            CHECK([label.text isEqualToString:identifier], "dynamic account/subreddit/content labels are unchanged");
            NSAttributedString *content = [[NSAttributedString alloc] initWithString:identifier attributes:@{@"test": @1}];
            label.attributedText = content;
            CHECK([label.attributedText isEqualToAttributedString:content], "attributed content and attributes are unchanged");
            UIButton *button = [UIButton new];
            [button setTitle:identifier forState:0];
            CHECK([button.storedTitle isEqualToString:identifier], "dynamic button identifiers are unchanged");
            [button setAttributedTitle:content forState:0];
            CHECK([button.storedAttributedTitle isEqualToAttributedString:content], "attributed button content is unchanged");
            UINavigationItem *navigation = [UINavigationItem new];
            navigation.title = identifier;
            navigation.backButtonTitle = identifier;
            CHECK([navigation.title isEqualToString:identifier] && [navigation.backButtonTitle isEqualToString:identifier], "dynamic navigation identifiers are unchanged");
            UIListContentConfiguration *configuration = [UIListContentConfiguration new];
            configuration.text = identifier;
            configuration.secondaryText = identifier;
            CHECK([configuration.text isEqualToString:identifier] && [configuration.secondaryText isEqualToString:identifier], "dynamic list identifiers are unchanged");
        }
        CFStringRef bridged = CFStringCreateWithCString(kCFAllocatorDefault, "colors", kCFStringEncodingUTF8);
        NSString *bridgedIdentifier = CFBridgingRelease(bridged);
        label.text = bridgedIdentifier;
        CHECK([label.text isEqualToString:bridgedIdentifier], "bridged dynamic content is unchanged");
        NSMutableString *mutableIdentifier = [@"Colors" mutableCopy];
        label.text = mutableIdentifier;
        CHECK([label.text isEqualToString:@"Colors"], "mutable content is unchanged");
        CHECK([ApolloSpellingApply(Dynamic("Customize Colors")) isEqualToString:@"Customise Colours"], "explicit trusted dynamic interface conversion remains available");
        CHECK([ApolloSpellingApply(@"r/colors u/favorite colors.com") isEqualToString:@"r/colors u/favorite colors.com"], "identifier prefixes and domains remain untouched");
        CHECK([ApolloSpellingCanonical(@"Customise Colours") isEqualToString:@"Customize Colors"], "canonical UI matching still works");
        sSpellingStyle = ApolloSpellingStyleAmerican;
        label.text = @"Customize Colors";
        CHECK([label.text isEqualToString:@"Customize Colors"], "American style is unchanged");
        CHECK(label.text != nil, "original setter still executes");
        fprintf(stderr, "Spelling setter regressions: %s\n", failures ? "FAIL" : "PASS");
        return failures ? 1 : 0;
    }
}
