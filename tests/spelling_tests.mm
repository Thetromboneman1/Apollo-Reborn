#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#define ApolloLog(...) ((void)0)

typedef NS_ENUM(NSInteger, ApolloSpellingStyle) {
    ApolloSpellingStyleAmerican = 0,
    ApolloSpellingStyleBritish = 1,
};
typedef NSUInteger UIControlState;
static const UIControlState UIControlStateNormal = 0;
static const UIControlState UIControlStateHighlighted = 1;
static const UIControlState UIControlStateDisabled = 2;

@interface UILabel : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSAttributedString *attributedText;
@end
@implementation UILabel
@end

// Model UIButton's independently stored state titles and forwarding into its
// current title label, rather than treating a button as one string slot.
@interface UIButton : NSObject
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *titles;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSAttributedString *> *attributedTitles;
@property (nonatomic) UIControlState displayedState;
@property (nonatomic, readonly) NSString *storedTitle;
@property (nonatomic, readonly) NSAttributedString *storedAttributedTitle;
- (void)setTitle:(NSString *)title forState:(UIControlState)state;
- (NSString *)titleForState:(UIControlState)state;
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state;
- (NSAttributedString *)attributedTitleForState:(UIControlState)state;
- (void)showState:(UIControlState)state;
@end
@implementation UIButton
- (instancetype)init {
    if ((self = [super init])) {
        _titleLabel = [UILabel new];
        _titles = [NSMutableDictionary dictionary];
        _attributedTitles = [NSMutableDictionary dictionary];
    }
    return self;
}
- (NSString *)storedTitle { return [self titleForState:UIControlStateNormal]; }
- (NSAttributedString *)storedAttributedTitle { return [self attributedTitleForState:UIControlStateNormal]; }
- (NSString *)titleForState:(UIControlState)state { return self.titles[@(state)]; }
- (NSAttributedString *)attributedTitleForState:(UIControlState)state { return self.attributedTitles[@(state)]; }
- (void)showState:(UIControlState)state {
    self.displayedState = state;
    NSAttributedString *attributed = [self attributedTitleForState:state];
    if (attributed) self.titleLabel.attributedText = attributed;
    else self.titleLabel.text = [self titleForState:state];
}
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    if (title) self.titles[@(state)] = title;
    else [self.titles removeObjectForKey:@(state)];
    if (state == self.displayedState) [self showState:state];
}
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    if (title) self.attributedTitles[@(state)] = title;
    else [self.attributedTitles removeObjectForKey:@(state)];
    if (state == self.displayedState) [self showState:state];
}
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
        UILabel *excludedLabel = [UILabel new];
        ApolloSpellingSetExcluded(excludedLabel, YES);
        excludedLabel.text = @"Colors";
        CHECK([excludedLabel.text isEqualToString:@"Colors"], "explicit content exclusion preserves even literal names");
        ApolloSpellingSetExcluded(excludedLabel, NO);
        excludedLabel.text = @"Colors";
        CHECK([excludedLabel.text isEqualToString:@"Colours"], "a reused label resumes interface conversion after exclusion ends");
        ApolloSpellingSetExcluded(excludedLabel, YES);
        CHECK([excludedLabel.text isEqualToString:@"Colors"], "late label exclusion restores original literal text");
        UINavigationItem *excludedNavigation = [UINavigationItem new];
        excludedNavigation.title = @"ColorBlind";
        ApolloSpellingSetExcluded(excludedNavigation, YES);
        CHECK([excludedNavigation.title isEqualToString:@"ColorBlind"], "late navigation exclusion restores exact subreddit slug");
        excludedNavigation.title = @"Colors";
        CHECK([excludedNavigation.title isEqualToString:@"Colors"], "excluded navigation title stays exact on reuse");
        UIButton *excludedButton = [UIButton new];
        ApolloSpellingSetExcluded(excludedButton, YES);
        [excludedButton setTitle:@"Colors" forState:0];
        excludedButton.titleLabel.text = @"Colors";
        CHECK([excludedButton.storedTitle isEqualToString:@"Colors"] && [excludedButton.titleLabel.text isEqualToString:@"Colors"], "button exclusion propagates to its title label");
        UILabel *replacement = [UILabel new];
        replacement.text = @"Colors";
        replacement.text = Dynamic("Colours");
        ApolloSpellingSetExcluded(replacement, YES);
        CHECK([replacement.text isEqualToString:@"Colours"], "new dynamic text invalidates stale restore provenance even for matching bytes");
        UILabel *attributedReplacement = [UILabel new];
        attributedReplacement.text = @"Colors";
        NSAttributedString *replacementContent = [[NSAttributedString alloc] initWithString:Dynamic("Colours") attributes:@{@"test": @2}];
        attributedReplacement.attributedText = replacementContent;
        ApolloSpellingSetExcluded(attributedReplacement, YES);
        CHECK([attributedReplacement.attributedText isEqualToAttributedString:replacementContent] && [attributedReplacement.text isEqualToString:@"Colours"], "attributed content invalidates stale plain-text restore provenance");
        UIButton *lateButton = [UIButton new];
        [lateButton setTitle:@"Colors" forState:UIControlStateNormal];
        [lateButton setTitle:@"Favorites" forState:UIControlStateHighlighted];
        [lateButton setTitle:@"Gray" forState:UIControlStateDisabled];
        [lateButton showState:UIControlStateDisabled];
        CHECK([[lateButton titleForState:UIControlStateNormal] isEqualToString:@"Colours"] && [[lateButton titleForState:UIControlStateHighlighted] isEqualToString:@"Favourites"] && [[lateButton titleForState:UIControlStateDisabled] isEqualToString:@"Grey"], "each button state converts literal interface text");
        ApolloSpellingSetExcluded(lateButton, YES);
        CHECK([[lateButton titleForState:UIControlStateNormal] isEqualToString:@"Colors"], "late button exclusion restores normal-state title");
        CHECK([[lateButton titleForState:UIControlStateHighlighted] isEqualToString:@"Favorites"], "late button exclusion restores highlighted-state title");
        CHECK([[lateButton titleForState:UIControlStateDisabled] isEqualToString:@"Gray"] && [lateButton.titleLabel.text isEqualToString:@"Gray"], "late button exclusion restores disabled state and displayed label");
        [lateButton setTitle:@"Colors" forState:UIControlStateNormal];
        CHECK([[lateButton titleForState:UIControlStateNormal] isEqualToString:@"Colors"], "excluded button remains exact on subsequent state writes");
        ApolloSpellingSetExcluded(lateButton, NO);
        [lateButton setTitle:@"Colors" forState:UIControlStateNormal];
        CHECK([[lateButton titleForState:UIControlStateNormal] isEqualToString:@"Colours"], "button can resume literal conversion after exclusion ends");

        UIButton *stateReplacement = [UIButton new];
        [stateReplacement setTitle:@"Colors" forState:UIControlStateNormal];
        [stateReplacement setTitle:@"Favorites" forState:UIControlStateHighlighted];
        [stateReplacement setTitle:@"Gray" forState:UIControlStateDisabled];
        [stateReplacement setTitle:Dynamic("Favourites") forState:UIControlStateHighlighted];
        ApolloSpellingSetExcluded(stateReplacement, YES);
        CHECK([[stateReplacement titleForState:UIControlStateNormal] isEqualToString:@"Colors"] && [[stateReplacement titleForState:UIControlStateDisabled] isEqualToString:@"Gray"], "dynamic replacement invalidates only its own state");
        CHECK([[stateReplacement titleForState:UIControlStateHighlighted] isEqualToString:@"Favourites"], "matching dynamic state title never restores stale original");

        UIButton *attributedStateReplacement = [UIButton new];
        [attributedStateReplacement setTitle:@"Colors" forState:UIControlStateNormal];
        [attributedStateReplacement setTitle:@"Favorites" forState:UIControlStateHighlighted];
        [attributedStateReplacement setTitle:@"Gray" forState:UIControlStateDisabled];
        NSAttributedString *stateContent = [[NSAttributedString alloc] initWithString:Dynamic("Colours") attributes:@{@"test": @3}];
        [attributedStateReplacement setAttributedTitle:stateContent forState:UIControlStateNormal];
        [attributedStateReplacement setTitle:nil forState:UIControlStateDisabled];
        ApolloSpellingSetExcluded(attributedStateReplacement, YES);
        CHECK([[attributedStateReplacement attributedTitleForState:UIControlStateNormal] isEqualToAttributedString:stateContent] && [[attributedStateReplacement titleForState:UIControlStateNormal] isEqualToString:@"Colours"], "attributed state replacement preserves exact content and invalidates its plain undo");
        CHECK([[attributedStateReplacement titleForState:UIControlStateHighlighted] isEqualToString:@"Favorites"], "attributed and nil replacements preserve another state's undo");
        CHECK([attributedStateReplacement titleForState:UIControlStateDisabled] == nil, "nil plain state replacement never restores a stale title");

        UIButton *nilAttributedState = [UIButton new];
        [nilAttributedState setTitle:@"Colors" forState:UIControlStateNormal];
        [nilAttributedState setTitle:@"Favorites" forState:UIControlStateHighlighted];
        [nilAttributedState setAttributedTitle:nil forState:UIControlStateNormal];
        ApolloSpellingSetExcluded(nilAttributedState, YES);
        CHECK([[nilAttributedState titleForState:UIControlStateNormal] isEqualToString:@"Colours"] && [[nilAttributedState titleForState:UIControlStateHighlighted] isEqualToString:@"Favorites"], "nil attributed write invalidates only its state");

        UIButton *changedState = [UIButton new];
        [changedState setTitle:@"Colors" forState:UIControlStateNormal];
        changedState.titles[@(UIControlStateNormal)] = Dynamic("Author text");
        ApolloSpellingSetExcluded(changedState, YES);
        CHECK([[changedState titleForState:UIControlStateNormal] isEqualToString:@"Author text"], "late exclusion checks current same-state value before restoring");
        sSpellingStyle = ApolloSpellingStyleAmerican;
        label.text = @"Customize Colors";
        CHECK([label.text isEqualToString:@"Customize Colors"], "American style is unchanged");
        CHECK(label.text != nil, "original setter still executes");
        fprintf(stderr, "Spelling setter regressions: %s\n", failures ? "FAIL" : "PASS");
        return failures ? 1 : 0;
    }
}
