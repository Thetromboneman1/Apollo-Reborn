#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, UINavigationItemSearchBarPlacement) {
    UINavigationItemSearchBarPlacementAutomatic,
    UINavigationItemSearchBarPlacementStacked,
    UINavigationItemSearchBarPlacementIntegratedButton,
};
typedef NS_ENUM(NSInteger, ApolloDuoMode) { ApolloDuoModePhone, ApolloDuoModeOpen };
@interface UIBarButtonItem : NSObject
@property(nonatomic) BOOL hidden;
@end
@implementation UIBarButtonItem @end
@interface UISearchController : NSObject
@property(nonatomic) BOOL active;
@end
@implementation UISearchController @end
@interface UINavigationItem : NSObject
@property(nonatomic) UINavigationItemSearchBarPlacement preferredSearchBarPlacement;
@property(nonatomic) BOOL searchBarPlacementAllowsExternalIntegration;
@property(nonatomic) BOOL searchBarPlacementAllowsToolbarIntegration;
@property(nonatomic, strong) UIBarButtonItem *searchBarPlacementBarButtonItem;
@property(nonatomic, strong) UISearchController *searchController;
@end
@implementation UINavigationItem @end
@interface UIViewController : NSObject
@property(nonatomic, strong) UINavigationItem *navigationItem;
@property(nonatomic) BOOL comments;
@end
@implementation UIViewController @end
static BOOL sShowFindInCommentsBar = YES, sShowFeedSearchBar = YES;
static BOOL unfolded, rail;
static ApolloDuoMode mode;
static NSUInteger controlsUpdates;
static BOOL ApolloDuoSplitIsUnfolded(void) { return unfolded; }
static ApolloDuoMode ApolloDuoCurrentMode(void) { return mode; }
static BOOL ApolloDuoRailHasVisibleSideBar(void) { return rail; }
static BOOL NSBIsNativeSearchCommentsVC(UIViewController *vc) { return vc.comments; }
static void NSBUpdateDuoControls(__unused UIViewController *vc) { controlsUpdates++; }
// INCLUDE_PRODUCTION_VISIBILITY_STATE
// INCLUDE_PRODUCTION_PLACEMENT
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
    vc.navigationItem.searchController = [UISearchController new];
    return vc;
}
static void Show(UIViewController *vc, BOOL show) {
    if (vc.comments) sShowFindInCommentsBar = show;
    else sShowFeedSearchBar = show;
    NSBUpdateSearchPlacement(vc);
}
int main(void) { @autoreleasepool {
    // Same retained feed/thread: OFF is reversible and Find keeps its controller.
    for (NSUInteger comments = 0; comments < 2; comments++) {
        UIViewController *vc = Controller(comments, YES, YES, NO);
        UINavigationItem *item = vc.navigationItem;
        UISearchController *search = item.searchController;
        Show(vc, NO);
        Check(!item.searchBarPlacementAllowsExternalIntegration && !item.searchBarPlacementAllowsToolbarIntegration,
              @"OFF suppresses both search integration paths");
        Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementIntegratedButton
              && item.searchBarPlacementBarButtonItem.hidden, @"OFF removes the field and button");
        item.searchController.active = YES;
        Check(item.searchController == search && search.active, @"programmatic Find keeps the attached controller usable while OFF");
        Show(vc, NO); // A layout/appearance repeat must not overwrite the original snapshot with NO/YES.
        Show(vc, YES);
        Check(item.searchBarPlacementAllowsExternalIntegration && item.searchBarPlacementAllowsToolbarIntegration,
              @"ON restores both integration flags on the same retained controller");
        Check(!item.searchBarPlacementBarButtonItem.hidden, @"ON restores the button's original visibility");
        Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementAutomatic,
              @"phone ON restores the original placement");
        Check(item.searchController == search && search.active, @"OFF/ON preserves active Find and its controller");
        Show(vc, YES);
        Check(item.searchBarPlacementAllowsExternalIntegration && !item.searchBarPlacementBarButtonItem.hidden,
              @"repeated ON is stable");
    }
    // Snapshot exact original values, including mixed flags and already-hidden buttons.
    for (NSUInteger mask = 0; mask < 8; mask++) {
        BOOL external = (mask & 1) != 0, toolbar = (mask & 2) != 0, hidden = (mask & 4) != 0;
        UIViewController *vc = Controller(NO, external, toolbar, hidden);
        Show(vc, NO); Show(vc, YES);
        Check(vc.navigationItem.searchBarPlacementAllowsExternalIntegration == external
              && vc.navigationItem.searchBarPlacementAllowsToolbarIntegration == toolbar
              && vc.navigationItem.searchBarPlacementBarButtonItem.hidden == hidden,
              @"ON restores exact original flag/visibility values, not unconditional YES/visible");
    }
    // Independent Duo placement snapshot survives the visibility round trip and pose changes.
    UIViewController *duo = Controller(NO, YES, NO, NO);
    UINavigationItem *item = duo.navigationItem;
    mode = ApolloDuoModeOpen;
    NSBUpdateSearchPlacement(duo);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementStacked, @"Duo keeps stacked placement");
    Show(duo, NO); Show(duo, YES);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementStacked
          && item.searchBarPlacementAllowsExternalIntegration && !item.searchBarPlacementAllowsToolbarIntegration,
          @"Duo ON restores visibility flags while retaining stacked policy");
    mode = ApolloDuoModePhone; rail = YES;
    Show(duo, NO); Show(duo, YES);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementStacked, @"closed landscape rail retains stacked policy");
    Show(duo, NO); rail = NO; unfolded = NO; Show(duo, YES);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementAutomatic,
          @"Duo-to-phone while OFF restores original phone placement on ON");
    Show(duo, NO); unfolded = YES; Show(duo, YES);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementStacked,
          @"phone-to-Duo while OFF applies current stacked policy on ON");
    unfolded = NO; NSBUpdateSearchPlacement(duo);
    Check(item.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementAutomatic,
          @"leaving Duo after ON still restores the original placement");

    // UIKit can replace or temporarily remove the generated placement button.
    UIViewController *replacementVC = Controller(YES, YES, YES, NO);
    item = replacementVC.navigationItem;
    UIBarButtonItem *old = item.searchBarPlacementBarButtonItem;
    Show(replacementVC, NO);
    UIBarButtonItem *replacement = [UIBarButtonItem new];
    item.searchBarPlacementBarButtonItem = replacement;
    Show(replacementVC, NO);
    Check(!old.hidden && replacement.hidden, @"replacement restores the previous UIKit button and hides the new one");
    Show(replacementVC, YES);
    Check(!replacement.hidden, @"ON restores the replacement button's own original visibility");
    Show(replacementVC, NO);
    item.searchBarPlacementBarButtonItem = nil;
    Show(replacementVC, NO);
    Check(!replacement.hidden, @"disappearance restores a removed button while another owner still retains it");
    Show(replacementVC, YES);
    Check(item.searchBarPlacementAllowsExternalIntegration && item.searchBarPlacementAllowsToolbarIntegration,
          @"a missing generated button does not block restoration of integration flags");
    __weak UIBarButtonItem *weakButton;
    @autoreleasepool {
        item.searchBarPlacementBarButtonItem = [UIBarButtonItem new];
        weakButton = item.searchBarPlacementBarButtonItem;
        Show(replacementVC, NO);
        item.searchBarPlacementBarButtonItem = nil;
    }
    Check(!weakButton, @"visibility snapshot does not retain a discarded UIKit button");
    Show(replacementVC, YES);
    Check(item.searchController != nil, @"button deallocation leaves the search controller attached");
    // A replacement not observed while OFF must keep its own state when ON.
    item.searchBarPlacementBarButtonItem = [UIBarButtonItem new];
    Show(replacementVC, NO);
    UIBarButtonItem *unobserved = [UIBarButtonItem new]; unobserved.hidden = YES;
    item.searchBarPlacementBarButtonItem = unobserved;
    Show(replacementVC, YES);
    Check(unobserved.hidden, @"ON does not unhide a replacement it never overrode");
    // UIKit may not create the placement button until a later deferred layout.
    UIViewController *late = Controller(NO, YES, YES, NO);
    late.navigationItem.searchBarPlacementBarButtonItem = nil;
    Show(late, NO);
    late.navigationItem.searchBarPlacementBarButtonItem = [UIBarButtonItem new];
    Show(late, NO);
    Check(late.navigationItem.searchBarPlacementBarButtonItem.hidden, @"a button created after OFF is hidden on the next placement pass");
    Show(late, YES);
    Check(!late.navigationItem.searchBarPlacementBarButtonItem.hidden, @"ON restores a button created during the OFF interval");
    late.navigationItem.searchBarPlacementAllowsExternalIntegration = NO;
    late.navigationItem.searchBarPlacementAllowsToolbarIntegration = YES;
    late.navigationItem.searchBarPlacementBarButtonItem.hidden = YES;
    late.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementIntegratedButton;
    Show(late, NO); Show(late, YES);
    Check(!late.navigationItem.searchBarPlacementAllowsExternalIntegration
          && late.navigationItem.searchBarPlacementAllowsToolbarIntegration
          && late.navigationItem.searchBarPlacementBarButtonItem.hidden,
          @"a new OFF interval snapshots the current values after the previous interval is restored");
    Check(late.navigationItem.preferredSearchBarPlacement == UINavigationItemSearchBarPlacementIntegratedButton,
          @"an original integrated placement remains integrated after OFF/ON");
    Check(controlsUpdates > 0, @"search placement continues to update independent Duo controls");
    printf("Native search visibility: %lu checks passed\n", (unsigned long)checks);
} }
