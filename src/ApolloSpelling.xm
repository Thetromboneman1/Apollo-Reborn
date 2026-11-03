// British spelling for interface text. Automatic setters accept only immutable
// compile-time NSString literals. Account names, community names and other
// runtime content must retain their exact spelling even when their value equals
// an interface word. Trusted dynamic chrome can opt in via ApolloSpellingApply.
// Attributed strings no longer carry reliable literal provenance, so their
// generic setters are left alone; convert trusted text before building them.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloSpelling.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

static ApolloSpellingStyle sSpellingStyle = ApolloSpellingStyleAmerican;

// American -> British, lowercase. Only words whose British form is unambiguous in UI text.
static NSDictionary<NSString *, NSString *> *SpellingMap(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"favorite": @"favourite", @"favorites": @"favourites", @"favorited": @"favourited",
            @"favoriting": @"favouriting", @"unfavorite": @"unfavourite", @"unfavorited": @"unfavourited",
            @"favor": @"favour", @"favors": @"favours", @"favorable": @"favourable",
            @"color": @"colour", @"colors": @"colours", @"colored": @"coloured", @"coloring": @"colouring",
            @"colorful": @"colourful", @"colorize": @"colourise", @"colorized": @"colourised",
            @"colorblind": @"colourblind",
            @"behavior": @"behaviour", @"behaviors": @"behaviours",
            @"center": @"centre", @"centers": @"centres", @"centered": @"centred", @"centering": @"centring",
            @"gray": @"grey", @"grays": @"greys", @"grayscale": @"greyscale",
            @"customize": @"customise", @"customized": @"customised", @"customizes": @"customises",
            @"customizing": @"customising", @"customization": @"customisation",
            @"customizations": @"customisations",
            @"organize": @"organise", @"organized": @"organised", @"reorganize": @"reorganise",
            @"recognize": @"recognise", @"recognized": @"recognised",
            @"personalize": @"personalise", @"personalized": @"personalised",
            @"personalization": @"personalisation",
            @"prioritize": @"prioritise", @"prioritized": @"prioritised",
            @"minimize": @"minimise", @"minimized": @"minimised",
            @"maximize": @"maximise", @"maximized": @"maximised",
            @"optimize": @"optimise", @"optimized": @"optimised", @"optimization": @"optimisation",
            @"summarize": @"summarise", @"summarized": @"summarised", @"summarizes": @"summarises",
            @"summarizing": @"summarising", @"summarization": @"summarisation",
            @"categorize": @"categorise", @"categorized": @"categorised",
            @"analyze": @"analyse", @"analyzed": @"analysed", @"analyzing": @"analysing",
            @"canceled": @"cancelled", @"canceling": @"cancelling",
            @"labeled": @"labelled", @"labeling": @"labelling",
            @"honor": @"honour", @"honors": @"honours", @"honored": @"honoured",
            @"catalog": @"catalogue", @"catalogs": @"catalogues",
            @"theater": @"theatre",
        };
    });
    return map;
}

// British -> American, for ApolloSpellingCanonical.
static NSDictionary<NSString *, NSString *> *CanonicalMap(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *inverse = [NSMutableDictionary dictionary];
        [SpellingMap() enumerateKeysAndObjectsUsingBlock:^(NSString *american, NSString *british, BOOL *stop) {
            inverse[british] = american;
        }];
        map = [inverse copy];
    });
    return map;
}

static NSRegularExpression *WordRegex(NSArray<NSString *> *keys) {
    // Longest first so alternation never stops at a shorter prefix.
    NSArray *words = [keys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length > b.length ? NSOrderedAscending : a.length < b.length ? NSOrderedDescending : NSOrderedSame;
    }];
    NSString *pattern = [NSString stringWithFormat:@"(?<![\\w/@#.])(?:%@)(?![\\w/]|\\.\\w)",
                         [words componentsJoinedByString:@"|"]];
    return [NSRegularExpression regularExpressionWithPattern:pattern
                                                     options:NSRegularExpressionCaseInsensitive
                                                       error:NULL];
}

static NSRegularExpression *CanonicalRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = WordRegex(CanonicalMap().allKeys); });
    return regex;
}

static NSRegularExpression *SpellingRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = WordRegex(SpellingMap().allKeys); });
    return regex;
}

// Carries the matched word's case over: COLORS -> COLOURS, Colors -> Colours, colors -> colours.
static NSString *MatchCase(NSString *british, NSString *original) {
    if (original.length > 1 && [original isEqualToString:original.uppercaseString]) return british.uppercaseString;
    unichar first = [original characterAtIndex:0];
    if ([NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:first]) {
        return [[british substringToIndex:1].uppercaseString stringByAppendingString:[british substringFromIndex:1]];
    }
    return british;
}

// Long strings are body text, not chrome.
static const NSUInteger kSpellingMaxLength = 600;

static NSArray<NSTextCheckingResult *> *SpellingMatches(NSString *text) {
    if (sSpellingStyle != ApolloSpellingStyleBritish) return nil;
    if (![text isKindOfClass:NSString.class] || text.length < 3 || text.length > kSpellingMaxLength) return nil;
    NSArray *matches = [SpellingRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    return matches.count ? matches : nil;
}

static NSString *BritishFor(NSString *word) {
    NSString *british = SpellingMap()[word.lowercaseString];
    return british ? MatchCase(british, word) : word;
}

NSString *ApolloSpellingApply(NSString *text) {
    NSArray<NSTextCheckingResult *> *matches = SpellingMatches(text);
    if (!matches) return text;
    NSMutableString *result = [text mutableCopy];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        [result replaceCharactersInRange:match.range withString:BritishFor([text substringWithRange:match.range])];
    }
    return result;
}

NSString *ApolloSpellingCanonical(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length < 3 || text.length > kSpellingMaxLength) return text;
    NSArray<NSTextCheckingResult *> *matches = [CanonicalRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!matches.count) return text;
    NSMutableString *result = [text mutableCopy];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *word = [text substringWithRange:match.range];
        [result replaceCharactersInRange:match.range withString:MatchCase(CanonicalMap()[word.lowercaseString], word)];
    }
    return result;
}

// Identity/provenance, never a value or prefix heuristic: a tagged, mutable,
// bridged or otherwise dynamically created string does not become trusted merely
// because it happens to contain the same bytes as one of our interface literals.
static NSString *ApolloSpellingApplyInterfaceLiteral(NSString *text) {
    if (sSpellingStyle != ApolloSpellingStyleBritish) return text;
    return text && object_getClass(text) == object_getClass(@"") ? ApolloSpellingApply(text) : text;
}

static void CollectTables(UIView *view, UIView *except, Class textureTable, NSMutableArray<UITableView *> *out, int depth) {
    if (!view || view == except || depth > 12) return;
    if ([view isKindOfClass:UITableView.class] && !(textureTable && [view isKindOfClass:textureTable])) {
        [out addObject:(UITableView *)view];
        return;
    }
    for (UIView *sub in view.subviews) CollectTables(sub, except, textureTable, out, depth + 1);
}

static void CollectControllers(UIViewController *vc, NSMutableArray<UIViewController *> *out) {
    if (!vc || [out containsObject:vc]) return;
    [out addObject:vc];
    for (UIViewController *child in vc.childViewControllers) CollectControllers(child, out);
    // Tabs and navigation stacks that are off screen keep their loaded views out of the window.
    if ([vc isKindOfClass:UITabBarController.class]) {
        for (UIViewController *tab in ((UITabBarController *)vc).viewControllers) CollectControllers(tab, out);
    }
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *pushed in ((UINavigationController *)vc).viewControllers) CollectControllers(pushed, out);
    }
    CollectControllers(vc.presentedViewController, out);
}

void ApolloSpellingReloadLoadedTables(UIView *except) {
    // Texture lists (feeds, comments) draw Reddit content and are never rewritten; reloading them
    // would only cost scroll position.
    Class textureTable = objc_getClass("ASTableView");
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) CollectControllers(window.rootViewController, controllers);
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    for (UIViewController *vc in controllers) {
        if (vc.isViewLoaded) CollectTables(vc.view, except, textureTable, tables, 0);
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (UITableView *table in tables) {
        if ([seen containsObject:table]) continue;
        [seen addObject:table];
        [table reloadData];
    }
    ApolloLog(@"[Spelling] reloaded %lu loaded table(s) for the new style", (unsigned long)seen.count);
}

ApolloSpellingStyle ApolloSpellingCurrentStyle(void) {
    return sSpellingStyle;
}

void ApolloSpellingSetStyle(ApolloSpellingStyle style) {
    sSpellingStyle = style == ApolloSpellingStyleBritish ? ApolloSpellingStyleBritish : ApolloSpellingStyleAmerican;
    [NSUserDefaults.standardUserDefaults setInteger:sSpellingStyle forKey:UDKeySpellingStyle];
    ApolloLog(@"[Spelling] style -> %@", sSpellingStyle == ApolloSpellingStyleBritish ? @"British" : @"American");
}

%hook UILabel
- (void)setText:(NSString *)text { text = ApolloSpellingApplyInterfaceLiteral(text); %orig(text); }
%end

%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title, state); }
%end

%hook UINavigationItem
- (void)setTitle:(NSString *)title { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title); }
- (void)setBackButtonTitle:(NSString *)title { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title); }
%end

%hook UIBarButtonItem
- (void)setTitle:(NSString *)title { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title); }
%end

%hook UITabBarItem
- (void)setTitle:(NSString *)title { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title); }
%end

%hook UIAlertController
- (void)setTitle:(NSString *)title { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title); }
- (void)setMessage:(NSString *)message { message = ApolloSpellingApplyInterfaceLiteral(message); %orig(message); }
%end

%hook UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(id)handler {
    title = ApolloSpellingApplyInterfaceLiteral(title);
    return %orig(title, style, handler);
}
%end

%hook UIAction
+ (instancetype)actionWithTitle:(NSString *)title image:(UIImage *)image identifier:(UIActionIdentifier)identifier handler:(id)handler {
    title = ApolloSpellingApplyInterfaceLiteral(title);
    return %orig(title, image, identifier, handler);
}
- (void)setTitle:(NSString *)title { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title); }
%end

%hook UIMenu
+ (instancetype)menuWithTitle:(NSString *)title image:(UIImage *)image identifier:(UIMenuIdentifier)identifier options:(UIMenuOptions)options children:(NSArray *)children {
    title = ApolloSpellingApplyInterfaceLiteral(title);
    return %orig(title, image, identifier, options, children);
}
%end

%hook UISegmentedControl
- (void)setTitle:(NSString *)title forSegmentAtIndex:(NSUInteger)segment { title = ApolloSpellingApplyInterfaceLiteral(title); %orig(title, segment); }
- (void)insertSegmentWithTitle:(NSString *)title atIndex:(NSUInteger)segment animated:(BOOL)animated {
    title = ApolloSpellingApplyInterfaceLiteral(title);
    %orig(title, segment, animated);
}
%end

%hook UIListContentConfiguration
- (void)setText:(NSString *)text { text = ApolloSpellingApplyInterfaceLiteral(text); %orig(text); }
- (void)setSecondaryText:(NSString *)text { text = ApolloSpellingApplyInterfaceLiteral(text); %orig(text); }
%end

%ctor {
    sSpellingStyle = [NSUserDefaults.standardUserDefaults integerForKey:UDKeySpellingStyle] == ApolloSpellingStyleBritish
        ? ApolloSpellingStyleBritish : ApolloSpellingStyleAmerican;
    %init;
    ApolloLog(@"[Spelling] hooks installed (style %@)", sSpellingStyle == ApolloSpellingStyleBritish ? @"British" : @"American");
}
