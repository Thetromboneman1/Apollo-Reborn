#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import "ApolloState.h"

// UIKit doubles are confined to the host boundary. The attachment, placement
// and temporary-Find dismissal functions below are extracted from production.
typedef NS_ENUM(NSInteger, UINavigationItemSearchBarPlacement) {
    UINavigationItemSearchBarPlacementAutomatic,
    UINavigationItemSearchBarPlacementStacked,
    UINavigationItemSearchBarPlacementIntegratedButton,
};
typedef NS_ENUM(NSInteger, ApolloDuoMode) { ApolloDuoModePhone, ApolloDuoModeOpen };
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
static const NSInteger UIUserInterfaceIdiomPad = 1;
static const NSInteger NSDirectionalRectEdgeTop = 1;
static const NSInteger UIScrollViewContentInsetAdjustmentAutomatic = 0;
@protocol UISearchBarDelegate @end
@protocol UISearchControllerDelegate @end
@interface UIColor : NSObject @end
@implementation UIColor @end
@interface UIBarButtonItem : NSObject
@property(nonatomic) BOOL hidden;
@end
@implementation UIBarButtonItem @end
@interface UISearchBar : NSObject
@property(nonatomic, copy) NSString *placeholder;
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) UIColor *tintColor;
@end
@implementation UISearchBar @end
@interface UISearchController : NSObject
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL obscuresBackgroundDuringPresentation;
@property(nonatomic) BOOL hidesNavigationBarDuringPresentation;
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) UISearchBar *searchBar;
- (instancetype)initWithSearchResultsController:(id)controller;
@end
@implementation UISearchController
- (instancetype)initWithSearchResultsController:(__unused id)controller {
    if ((self = [super init])) self.searchBar = [UISearchBar new];
    return self;
}
@end
@interface UINavigationItem : NSObject
@property(nonatomic) UINavigationItemSearchBarPlacement preferredSearchBarPlacement;
@property(nonatomic) BOOL searchBarPlacementAllowsExternalIntegration;
@property(nonatomic) BOOL searchBarPlacementAllowsToolbarIntegration;
@property(nonatomic, strong) UIBarButtonItem *searchBarPlacementBarButtonItem;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic) BOOL hidesSearchBarWhenScrolling;
@end
@implementation UINavigationItem @end
@interface UIGestureRecognizer : NSObject
@property(nonatomic) NSUInteger registrations;
- (void)addTarget:(id)target action:(SEL)action;
@end
@implementation UIGestureRecognizer
- (void)addTarget:(__unused id)target action:(__unused SEL)action { self.registrations++; }
@end
@class UIViewController;
@interface UIScrollView : NSObject
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic) CGPoint contentOffset;
@property(nonatomic) UIEdgeInsets adjustedContentInset;
@property(nonatomic, strong) UIGestureRecognizer *panGestureRecognizer;
@property(nonatomic) NSInteger contentInsetAdjustmentBehavior;
@property(nonatomic) UIEdgeInsets contentInset;
@end
@implementation UIScrollView @end
@interface ApolloNativeSearchRestingState : NSObject
@property(nonatomic) BOOL revealArmed;
@property(nonatomic) BOOL revealInFlight;
@end
@implementation ApolloNativeSearchRestingState @end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIScrollView *table;
@property(nonatomic, strong) UIScrollView *managedTable;
@property(nonatomic, strong) ApolloNativeSearchRestingState *resting;
@property(nonatomic) BOOL landsOnLinkedComment;
@property(nonatomic, strong) UINavigationItem *navigationItem;
@property(nonatomic) BOOL comments;
- (void)setContentScrollView:(UIScrollView *)table forEdge:(NSInteger)edge;
@end
@implementation UIViewController
- (void)setContentScrollView:(UIScrollView *)table forEdge:(__unused NSInteger)edge { self.managedTable = table; }
@end
@interface UIDevice : NSObject
@property(nonatomic) NSInteger userInterfaceIdiom;
+ (instancetype)currentDevice;
@end
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *device; if (!device) device = [UIDevice new]; return device; }
@end
@interface ApolloNativeSearchBridge : NSObject <UISearchBarDelegate, UISearchControllerDelegate>
@property(nonatomic, weak) UIViewController *feedVC;
@end
@implementation ApolloNativeSearchBridge @end
static BOOL unfolded, rail;
static ApolloDuoMode mode;
static NSUInteger controlsUpdates;
static BOOL ApolloDuoSplitIsUnfolded(void) { return unfolded; }
static ApolloDuoMode ApolloDuoCurrentMode(void) { return mode; }
static BOOL ApolloDuoRailHasVisibleSideBar(void) { return rail; }
static BOOL NSBIsNativeSearchCommentsVC(UIViewController *vc) { return vc.comments; }
static void NSBUpdateDuoControls(__unused UIViewController *vc) { controlsUpdates++; }
static char bridgeKey, nativeBarKey, appearedKey, parkedKey, feedTableKey;
static const void *kNSBBridgeKey = &bridgeKey, *kNSBNativeBarKey = &nativeBarKey;
static const void *kNSBAppearedKey = &appearedKey, *kNSBParkedForLandingKey = &parkedKey, *kNSBFeedTableKey = &feedTableKey;
static id<UISearchBarDelegate, UISearchControllerDelegate> ApolloFindInCommentsGlassBridgeForController(__unused UIViewController *vc) { return [ApolloNativeSearchBridge new]; }
static NSString *ApolloFindInCommentsGlassPlaceholder(void) { return @"Find in Comments"; }
static UIColor *ApolloThemeAccentColor(void) { return nil; }
void ApolloHeaderStyleRegisterSearchBar(__unused UISearchBar *bar) {}
static BOOL ApolloInboxCommentScrollLandsOnLinkedComment(UIViewController *vc) { return vc.landsOnLinkedComment; }
static UIScrollView *NSBTableForVC(UIViewController *vc) { return vc.table; }
static UIViewController *NSBFeedVCForView(UIScrollView *table) { return table.controller; }
static ApolloNativeSearchRestingState *NSBRestingStateForVC(UIViewController *vc) { return vc.resting; }
static BOOL NSBTraceEnabled(void) { return NO; }
static void NSBRelativizeInset(__unused UIScrollView *table, __unused UIEdgeInsets *insets) {}
static void ApolloPaneApplySearchPlacement(__unused UIViewController *vc) {}
void ApolloHeaderStyleRegisterScrollAwaySearchBar(__unused UISearchBar *bar, __unused UINavigationItem *item, __unused UIScrollView *table) {}
#define ApolloLog(...) do { if (0) NSLog(__VA_ARGS__); } while (0)
// INCLUDE_PRODUCTION_VISIBILITY_STATE
// INCLUDE_PRODUCTION_SETTING_POLICY
// INCLUDE_PRODUCTION_PLACEMENT
// The host fixture executes the scheduled policy immediately; the UIKit
// harness also exercises the shipping main-queue scheduling boundary.
static void NSBScheduleSearchPlacement(UIViewController *vc) { NSBUpdateSearchPlacement(vc); }
// INCLUDE_PRODUCTION_TABLE_MANAGEMENT
// INCLUDE_PRODUCTION_REVEAL
// INCLUDE_PRODUCTION_ATTACHMENT
// INCLUDE_PRODUCTION_FIND_DISMISSED
static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static UIViewController *Controller(BOOL comments, BOOL external, BOOL toolbar, BOOL hidden) {
    UIViewController *vc = [UIViewController new]; vc.comments = comments;
    vc.navigationItem = [UINavigationItem new];
    vc.navigationItem.searchBarPlacementAllowsExternalIntegration = external;
    vc.navigationItem.searchBarPlacementAllowsToolbarIntegration = toolbar;
    vc.navigationItem.searchBarPlacementBarButtonItem = [UIBarButtonItem new];
    vc.navigationItem.searchBarPlacementBarButtonItem.hidden = hidden;
    vc.resting = [ApolloNativeSearchRestingState new];
    return vc;
}
static void Show(UIViewController *vc, BOOL show) {
    sSearchBarModeExplicit = NO;
    if (vc.comments) sShowFindInCommentsBar = show;
    else sShowFeedSearchBar = show;
    NSBAttachNativeSearch(vc);
}
static void BeginTemporaryFind(UIViewController *vc) {
    objc_setAssociatedObject(vc, &kNSBSearchForFindKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSBAttachNativeSearch(vc);
    vc.navigationItem.searchController.active = YES;
}
int main(void) { @autoreleasepool {
    // OFF removes the controller, so there is no search field or generated
    // search button on 26 as well as 27. Original flags remain exact.
    for (NSUInteger comments = 0; comments < 2; comments++) {
      for (NSUInteger mask = 0; mask < 8; mask++) {
        BOOL external = (mask & 1) != 0, toolbar = (mask & 2) != 0, hidden = (mask & 4) != 0;
        UIViewController *vc = Controller(comments, external, toolbar, hidden);
        UINavigationItem *item = vc.navigationItem;
        for (NSUInteger cycle = 0; cycle < 3; cycle++) {
            Show(vc, YES);
            Check(item.searchController != nil, @"ON attaches native search");
            Show(vc, NO); Show(vc, NO);
            Check(item.searchController == nil, @"repeated resting OFF stays detached");
            Check(item.searchBarPlacementAllowsExternalIntegration == external &&
                  item.searchBarPlacementAllowsToolbarIntegration == toolbar,
                  @"detachment leaves exact original integration flags");
            Check(item.searchBarPlacementBarButtonItem.hidden == hidden, @"detachment never changes unrelated button visibility");
            Show(vc, YES); Show(vc, YES);
            Check(item.searchController != nil &&
                  item.searchBarPlacementAllowsExternalIntegration == external &&
                  item.searchBarPlacementAllowsToolbarIntegration == toolbar,
                  @"ON reattaches with original flags after every OFF cycle");
            Check(!objc_getAssociatedObject(item, &kNSBSearchVisibilitySnapshotKey), @"no stale visibility override after ON");
            Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementAutomatic, @"phone placement restores after OFF/ON");
        }
        if (!comments) continue;
        Show(vc, NO); BeginTemporaryFind(vc);
        UISearchController *search = item.searchController;
        Check(search && search.active, @"Find temporarily attaches usable search while OFF");
        Check(!item.searchBarPlacementAllowsExternalIntegration && !item.searchBarPlacementAllowsToolbarIntegration,
              @"temporary Find suppresses external/toolbar integration only");
        Check(item.searchBarPlacementBarButtonItem.hidden == hidden, @"temporary Find does not hide UIKit button");
        Show(vc, NO);
        Check(item.searchController == search, @"layout retains active temporary Find while OFF");
        ApolloNativeFeedSearchFindDismissed(vc);
        Check(item.searchController == nil && !objc_getAssociatedObject(vc, &kNSBSearchForFindKey), @"dismissed temporary Find detaches and clears its note");
        Check(item.searchBarPlacementAllowsExternalIntegration == external && item.searchBarPlacementAllowsToolbarIntegration == toolbar,
              @"Find dismissal restores both original integration flags");
        Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementAutomatic, @"Find dismissal restores phone placement");
        ApolloNativeFeedSearchFindDismissed(vc);
        Check(item.searchController == nil, @"Find cleanup is idempotent");
        BeginTemporaryFind(vc); search = item.searchController;
        Show(vc, YES); ApolloNativeFeedSearchFindDismissed(vc);
        Check(item.searchController == search, @"ON during temporary Find retains its controller after dismissal");
        Check(item.searchBarPlacementAllowsExternalIntegration == external && item.searchBarPlacementAllowsToolbarIntegration == toolbar,
              @"ON during temporary Find restores exact integration flags");
      }
    }
    // Old mixed choices survive independently, while an explicit shared mode
    // takes priority over both old values on every controller.
    UIViewController *feed = Controller(NO, YES, YES, NO);
    UIViewController *thread = Controller(YES, YES, YES, NO);
    ApolloLoadSearchBarPreferences(@{@"ShowFeedSearchBar": @NO, @"ShowFindInCommentsBar": @YES});
    NSBAttachNativeSearch(feed); NSBAttachNativeSearch(thread);
    Check(!feed.navigationItem.searchController && thread.navigationItem.searchController,
          @"mixed legacy choices do not reveal the prior hidden feed bar");
    ApolloLoadSearchBarPreferences(@{@"ShowFeedSearchBar": @YES, @"ShowFindInCommentsBar": @NO});
    NSBAttachNativeSearch(feed); NSBAttachNativeSearch(thread);
    Check(feed.navigationItem.searchController && !thread.navigationItem.searchController,
          @"opposite legacy mixture preserves thread Off independently");
    for (NSNumber *choice in @[@0, @1, @2]) {
        ApolloLoadSearchBarPreferences(@{@"SearchBarMode": choice, @"ShowFeedSearchBar": @NO, @"ShowFindInCommentsBar": @YES});
        UIViewController *a = Controller(NO, YES, YES, NO), *b = Controller(YES, YES, YES, NO);
        NSBAttachNativeSearch(a); NSBAttachNativeSearch(b);
        Check((a.navigationItem.searchController != nil) == (choice.integerValue != ApolloSearchBarModeOff) &&
              (b.navigationItem.searchController != nil) == (choice.integerValue != ApolloSearchBarModeOff),
              @"explicit enum consistently controls feed and thread attachment");
        if (choice.integerValue == ApolloSearchBarModeHidden) {
            Check(a.navigationItem.hidesSearchBarWhenScrolling && b.navigationItem.hidesSearchBarWhenScrolling,
                  @"Hidden attaches both bars already parked");
        }
    }
    ApolloLoadSearchBarPreferences(@{@"SearchBarMode": @(ApolloSearchBarModeOn)});
    UIViewController *linked = Controller(YES, YES, YES, NO); linked.landsOnLinkedComment = YES;
    NSBAttachNativeSearch(linked);
    Check(linked.navigationItem.hidesSearchBarWhenScrolling && objc_getAssociatedObject(linked, kNSBParkedForLandingKey),
          @"On still preserves linked-comment landing without a reveal jump");

    // Off still manages the real table, including a table created after the
    // controller first laid out. Repeated layouts must not add duplicate pans.
    ApolloLoadSearchBarPreferences(@{@"SearchBarMode": @(ApolloSearchBarModeOff)});
    UIViewController *late = Controller(NO, YES, YES, NO);
    NSBAttachNativeSearch(late);
    Check(late.managedTable == nil, @"Off tolerates a table not created yet");
    late.table = [UIScrollView new]; late.table.controller = late;
    late.table.panGestureRecognizer = [UIGestureRecognizer new];
    late.table.contentInsetAdjustmentBehavior = 1;
    NSBAttachNativeSearch(late); NSBAttachNativeSearch(late);
    Check(late.managedTable == late.table && late.table.contentInsetAdjustmentBehavior == UIScrollViewContentInsetAdjustmentAutomatic,
          @"Off retries table tracking and automatic insets once table exists");
    Check(late.table.panGestureRecognizer.registrations == 1 && !late.navigationItem.searchController,
          @"Off management is idempotent and keeps no search chrome");
    ApolloLoadSearchBarPreferences(@{@"SearchBarMode": @(ApolloSearchBarModeHidden)});
    NSBArmReveal(late.table, "test");
    Check(!late.resting.revealArmed, @"Hidden suppresses programmatic reveal arming");
    ApolloLoadSearchBarPreferences(@{@"SearchBarMode": @(ApolloSearchBarModeOn)});
    NSBArmReveal(late.table, "test");
    Check(late.resting.revealArmed, @"On retains programmatic reveal arming");

    // The temporary override and the live Duo pose remain independent.
    UIViewController *duo = Controller(YES, YES, NO, NO);
    UINavigationItem *item = duo.navigationItem;
    unfolded = YES; Show(duo, YES);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementStacked, @"Duo is stacked when enabled");
    Show(duo, NO); BeginTemporaryFind(duo);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementIntegratedButton, @"temporary Find gets integrated placement in Duo");
    unfolded = NO; ApolloNativeFeedSearchFindDismissed(duo);
    Check(item.searchController == nil && item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementAutomatic,
          @"Duo-to-phone during Find restores phone placement on dismissal");
    BeginTemporaryFind(duo); mode = ApolloDuoModeOpen; ApolloNativeFeedSearchFindDismissed(duo);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementStacked && item.searchController == nil,
          @"phone-to-Duo during Find applies current stacked policy without reattaching");
    mode = ApolloDuoModePhone; rail = YES; Show(duo, YES);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementStacked, @"closed landscape rail retains stacked policy");
    Show(duo, NO); BeginTemporaryFind(duo); rail = NO; Show(duo, YES);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementAutomatic && item.searchBarPlacementAllowsExternalIntegration && !item.searchBarPlacementAllowsToolbarIntegration,
          @"ON after pose change restores placement and mixed flags independently");
    ApolloNativeFeedSearchFindDismissed(duo);

    // Exact restore/weak ownership of buttons from a visibility override.
    // The temporary Find policy itself no longer hides generated buttons.
    for (NSNumber *hidden in @[@NO, @YES]) {
        UIBarButtonItem *button = [UIBarButtonItem new]; button.hidden = hidden.boolValue;
        NSBSearchVisibilitySnapshot *snapshot = [NSBSearchVisibilitySnapshot new];
        [snapshot hideButton:button]; [snapshot hideButton:button]; [snapshot restoreButton];
        Check(button.hidden == hidden.boolValue, @"snapshot restores original hidden state exactly");
    }
    UIBarButtonItem *first = [UIBarButtonItem new], *replacement = [UIBarButtonItem new];
    NSBSearchVisibilitySnapshot *snapshot = [NSBSearchVisibilitySnapshot new];
    [snapshot hideButton:first]; [snapshot hideButton:replacement];
    Check(!first.hidden && replacement.hidden, @"replacement restores previous owned button");
    [snapshot hideButton:nil];
    Check(!replacement.hidden, @"removed generated button is restored");
    __weak UIBarButtonItem *weakButton;
    @autoreleasepool {
        UIBarButtonItem *discarded = [UIBarButtonItem new]; weakButton = discarded;
        [snapshot hideButton:discarded];
    }
    Check(!weakButton, @"snapshot does not retain discarded UIKit button");
    [snapshot restoreButton];
    Check(controlsUpdates > 0, @"search placement continues independent Duo controls");
    printf("Native search visibility: %lu checks passed\n", (unsigned long)checks);
} }
