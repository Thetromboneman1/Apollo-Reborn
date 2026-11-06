// British spelling for interface text. Automatic setters accept only immutable
// compile-time NSString literals. Account names, community names and other
// runtime content must retain their exact spelling even when their value equals
// an interface word. Trusted dynamic chrome can opt in via ApolloSpellingApply.
// Explicit content exclusions also protect literal-looking subreddit names.
// Attributed strings no longer carry reliable literal provenance, so their
// generic setters preserve their input; convert trusted text before building them.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloSpelling.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"

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

static char kApolloSpellingExcludedKey;
// @[rewritten, original] for the last respelled set on a label or navigation item, so a later
// opt-out can put the original back.
static char kApolloSpellingRewriteKey;

static BOOL SpellingIsExcluded(id object) {
    return objc_getAssociatedObject(object, &kApolloSpellingExcludedKey) != nil;
}

// Puts the original back if the object still shows the respelled text from its last set.
static void SpellingRestoreOriginal(id object) {
    NSArray *rewrite = objc_getAssociatedObject(object, &kApolloSpellingRewriteKey);
    if (rewrite.count != 2) return;
    objc_setAssociatedObject(object, &kApolloSpellingRewriteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id rewritten = rewrite[0], original = rewrite[1];
    NSString *rewrittenText = [rewritten isKindOfClass:NSAttributedString.class] ? [rewritten string] : rewritten;
    if ([object isKindOfClass:UILabel.class]) {
        UILabel *label = object;
        if (![label.text isEqualToString:rewrittenText]) return;
        if ([original isKindOfClass:NSAttributedString.class]) label.attributedText = original;
        else label.text = original;
    } else if ([object isKindOfClass:UINavigationItem.class]) {
        UINavigationItem *item = object;
        if ([item.title isEqualToString:rewrittenText]) item.title = original;
    } else {
        return;
    }
    ApolloLog(@"[Spelling] restored original text on %@", NSStringFromClass([object class]));
}

void ApolloSpellingSetExcluded(id object, BOOL excluded) {
    if (!object) return;
    objc_setAssociatedObject(object, &kApolloSpellingExcludedKey, excluded ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A button passes its title on to its own label, so that label has to opt out too.
    if ([object isKindOfClass:UIButton.class]) ApolloSpellingSetExcluded(((UIButton *)object).titleLabel, excluded);
    if (excluded) SpellingRestoreOriginal(object);
}

// The style check comes first so American mode never reaches the associated-object lookup.
static BOOL SpellingSkips(id owner) {
    return sSpellingStyle != ApolloSpellingStyleBritish || SpellingIsExcluded(owner);
}

// Text for an owner's setter: as given when excluded, otherwise in the current style. A respelled
// set is remembered so ApolloSpellingSetExcluded can undo it.
// (Logos can't parse a ternary inside %orig, hence these wrappers.)
static NSString *SpellingTextForOwner(id owner, NSString *text) {
    // A new set replaces the previous provenance, even when its bytes match
    // an earlier rewritten value. A later exclusion must never restore stale text.
    objc_setAssociatedObject(owner, &kApolloSpellingRewriteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (SpellingSkips(owner)) return text;
    return ApolloSpellingApplyInterfaceLiteral(text);
}

// Remember after the original setter: UIKit may forward between its plain and
// attributed setters internally. A later attributed write still clears this record.
static void SpellingRememberRewrite(id owner, NSString *original, NSString *rewritten) {
    if (rewritten != original && !SpellingIsExcluded(owner)) {
        objc_setAssociatedObject(owner, &kApolloSpellingRewriteKey, @[rewritten, original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
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
- (void)setText:(NSString *)text {
    NSString *original = text;
    text = SpellingTextForOwner(self, text);
    %orig(text);
    SpellingRememberRewrite(self, original, text);
}
- (void)setAttributedText:(NSAttributedString *)text {
    objc_setAssociatedObject(self, &kApolloSpellingRewriteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(text);
}
%end

%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    NSString *original = title;
    title = SpellingTextForOwner(self, title);
    %orig(title, state);
    SpellingRememberRewrite(self, original, title);
}
- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    objc_setAssociatedObject(self, &kApolloSpellingRewriteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(title, state);
}
%end

%hook UINavigationItem
- (void)setTitle:(NSString *)title {
    NSString *original = title;
    title = SpellingTextForOwner(self, title);
    %orig(title);
    SpellingRememberRewrite(self, original, title);
}
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

// Subreddit names are Reddit content too, and the feed title is also the slug Apollo and several
// modules (subreddit headers, Community Highlights, the switcher) read back to know which
// subreddit is open: respelling r/ColorBlind's title to "Colourblind" made them look up the
// wrong subreddit.
@interface ApolloSpellingPostsController : UIViewController @end
@interface ApolloSpellingJumpBar : UIView @end
@interface ApolloSpellingRedditListCell : UITableViewCell @end

static void SpellingExcludeLabels(UIView *view, int depth) {
    if (depth > 4) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UILabel.class]) {
            if (!SpellingIsExcluded(sub)) ApolloSpellingSetExcluded(sub, YES);
        } else {
            SpellingExcludeLabels(sub, depth + 1);
        }
    }
}

%group SpellingFeedTitle
%hook ApolloSpellingPostsController
// Every title write goes through the navigation item, so tagging it on access covers Apollo's own
// sets; a title respelled before the first access is put back.
- (UINavigationItem *)navigationItem {
    UINavigationItem *item = %orig;
    if (sSpellingStyle == ApolloSpellingStyleBritish && item && !SpellingIsExcluded(item)) {
        ApolloSpellingSetExcluded(item, YES);
    }
    return item;
}
%end
%end

%group SpellingJumpBar
%hook ApolloSpellingJumpBar
// The title quick-switcher: the subreddit name, its search field and name suggestions.
- (void)didMoveToWindow {
    %orig;
    UIView *jumpBar = (UIView *)self;
    if (jumpBar.window) SpellingExcludeLabels(jumpBar, 0);
}
%end
%end

%group SpellingRedditList
%hook ApolloSpellingRedditListCell
// Subreddit, multireddit and feed names in Apollo's subreddit list. The subtitle stays rewritable:
// it also carries Apollo's own text (multireddit descriptions opt out per set).
- (void)didMoveToWindow {
    %orig;
    UIView *cell = (UIView *)self;
    if (!cell.window) return;
    UILabel *title = ApolloObjectIvar(cell, "redditTitleLabel");
    if ([title isKindOfClass:UILabel.class] && !SpellingIsExcluded(title)) ApolloSpellingSetExcluded(title, YES);
}
%end
%end

%ctor {
    sSpellingStyle = [NSUserDefaults.standardUserDefaults integerForKey:UDKeySpellingStyle] == ApolloSpellingStyleBritish
        ? ApolloSpellingStyleBritish : ApolloSpellingStyleAmerican;
    %init;
    if (ApolloClassPostsViewController) %init(SpellingFeedTitle, ApolloSpellingPostsController = ApolloClassPostsViewController);
    if (ApolloClassJumpBar) %init(SpellingJumpBar, ApolloSpellingJumpBar = ApolloClassJumpBar);
    if (ApolloClassRedditListTableViewCell) %init(SpellingRedditList, ApolloSpellingRedditListCell = ApolloClassRedditListTableViewCell);
    ApolloLog(@"[Spelling] feed-name hooks: posts=%d jumpBar=%d redditList=%d", ApolloClassPostsViewController != Nil,
              ApolloClassJumpBar != Nil, ApolloClassRedditListTableViewCell != Nil);
    ApolloLog(@"[Spelling] hooks installed (style %@)", sSpellingStyle == ApolloSpellingStyleBritish ? @"British" : @"American");
}
