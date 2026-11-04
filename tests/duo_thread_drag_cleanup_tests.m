#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>

typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
static const UIEdgeInsets UIEdgeInsetsZero = {0};
static const NSUInteger UIViewAnimationOptionCurveEaseOut = 1;
static BOOL reduceMotion;
static NSUInteger snapshotRequests, rememberedThreads;
static NSTimeInterval fillerFadeDuration;
@interface TestLayer : NSObject
- (void)removeAnimationForKey:(NSString *)key;
@end
@implementation TestLayer
- (void)removeAnimationForKey:(__unused NSString *)key {}
@end
@interface UIView : NSObject
@property(nonatomic) CGRect frame, bounds;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) BOOL userInteractionEnabled, snapshotAvailable;
@property(nonatomic, strong) NSObject *window;
@property(nonatomic, strong) TestLayer *layer;
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, strong) NSMutableArray<UIView *> *subviews;
- (void)removeFromSuperview;
- (void)layoutIfNeeded;
- (void)insertSubview:(UIView *)view belowSubview:(UIView *)below;
- (UIView *)resizableSnapshotViewFromRect:(CGRect)rect afterScreenUpdates:(BOOL)updates withCapInsets:(UIEdgeInsets)insets;
+ (void)performWithoutAnimation:(dispatch_block_t)block;
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(NSUInteger)options
                animations:(dispatch_block_t)animations completion:(void (^)(BOOL))completion;
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) { _alpha = 1; _layer = [TestLayer new]; _subviews = [NSMutableArray new]; } return self; }
- (void)removeFromSuperview { [self.superview.subviews removeObject:self]; self.superview = nil; }
- (void)layoutIfNeeded {}
- (void)insertSubview:(UIView *)view belowSubview:(__unused UIView *)below { [self.subviews addObject:view]; view.superview = self; }
- (UIView *)resizableSnapshotViewFromRect:(__unused CGRect)rect afterScreenUpdates:(__unused BOOL)updates withCapInsets:(__unused UIEdgeInsets)insets {
    snapshotRequests++; return self.snapshotAvailable ? [UIView new] : nil;
}
+ (void)performWithoutAnimation:(dispatch_block_t)block { block(); }
+ (void)animateWithDuration:(NSTimeInterval)duration delay:(__unused NSTimeInterval)delay options:(__unused NSUInteger)options
                animations:(dispatch_block_t)animations completion:(void (^)(BOOL))completion {
    fillerFadeDuration = duration; animations(); completion(YES);
}
@end
@interface UITableView : UIView @end
@implementation UITableView @end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic, readonly) UIView *viewIfLoaded;
@end
@implementation UIViewController
- (UIView *)viewIfLoaded { return self.view; }
@end
@interface UINavigationController : UIViewController
@property(nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property(nonatomic, readonly) UIViewController *topViewController;
- (void)setViewControllers:(NSArray *)pages animated:(BOOL)animated;
@end
@implementation UINavigationController
- (UIViewController *)topViewController { return self.viewControllers.lastObject; }
- (void)setViewControllers:(NSArray *)pages animated:(__unused BOOL)animated { self.viewControllers = pages; }
@end
@interface ApolloDuoSplitHost : NSObject
@property(nonatomic, strong) UIView *view, *threadDragFiller, *postsTransitionSnapshot, *listDismiss;
@property(nonatomic) BOOL postsShowingDetail;
@end
@implementation ApolloDuoSplitHost @end
@interface ApolloDuoSplitState : NSObject
@property(nonatomic, strong) ApolloDuoSplitHost *host;
@property(nonatomic, strong) UINavigationController *feed, *secondary;
@property(nonatomic) BOOL changing;
@end
@implementation ApolloDuoSplitState @end
#define CATransaction TestCATransaction
@interface CATransaction : NSObject
+ (void)begin;
+ (void)commit;
+ (void)setCompletionBlock:(dispatch_block_t)block;
@end
@implementation CATransaction
+ (void)begin {}
+ (void)commit {}
+ (void)setCompletionBlock:(__unused dispatch_block_t)block {}
@end
typedef NSObject ApolloDuoPostsGeometry;
typedef NSObject ApolloDuoFeedAnchor;
static const NSUInteger ApolloDuoClosedThreadEventThreadOpened = 1;
static BOOL UIAccessibilityIsReduceMotionEnabled(void) { return reduceMotion; }
static void ApolloDuoPostsReviewClosedThread(__unused id state, __unused NSUInteger event, __unused double value) {}
static void ApolloDuoPostsStopGeometry(__unused UIView *view) {}
static NSArray *ApolloDuoClosedThreadPages(NSArray *pages) { return [pages subarrayWithRange:NSMakeRange(1, pages.count - 1)]; }
static void ApolloDuoSetThreadDragOffset(__unused UIView *view, __unused CGFloat offset) {}
static NSArray *ApolloDuoPostsCaptureGeometry(__unused UIView *view, __unused UIView *surface) { return @[]; }
static CGRect ApolloDuoPostsDetailPane(__unused ApolloDuoSplitState *state) { return CGRectMake(500, 0, 500, 800); }
static UITableView *ApolloDuoSplitFindTable(__unused UIView *view) { return nil; }
static ApolloDuoFeedAnchor *ApolloDuoCaptureFeedAnchor(__unused UITableView *table) { return nil; }
static void ApolloDuoRestoreFeedAnchor(__unused UITableView *table, __unused ApolloDuoFeedAnchor *anchor) {}
static void ApolloDuoPostsRememberClosedThread(__unused id state, __unused NSArray *pages) { rememberedThreads++; }
static void ApolloDuoPostsSyncColumns(ApolloDuoSplitState *state) { state.host.postsShowingDetail = state.secondary.viewControllers.count > 1; }
static void ApolloNativeFeedSearchFinishColumnMove(__unused UIViewController *vc) {}
static void ApolloDuoMediaPrepareTableForTransition(__unused UITableView *table) {}
static void ApolloDuoSplitScheduleUpdate(void) {}
static void ApolloDuoPostsAnimateGeometry(__unused NSArray *geometry, __unused UIView *view, __unused UIView *surface, __unused double duration) {}
static void ApolloDuoHoldTextLayout(__unused NSArray *views) {}
static void ApolloDuoSlideView(__unused UIView *view, __unused CGFloat from, __unused CGFloat to, __unused double duration, dispatch_block_t finish) { if (finish) finish(); }
static void ApolloDuoSlideDrawer(__unused UIView *view, __unused CGFloat from, __unused CGFloat to, __unused CGFloat velocity, __unused BOOL animated, dispatch_block_t finish) { if (finish) finish(); }
// INCLUDE_PRODUCTION_FILLER_REMOVAL
// INCLUDE_PRODUCTION_TRANSITION
static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++; if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static ApolloDuoSplitState *State(BOOL snapshotAvailable) {
    ApolloDuoSplitState *state = [ApolloDuoSplitState new]; state.host = [ApolloDuoSplitHost new];
    state.host.view = [UIView new]; state.host.view.bounds = CGRectMake(0, 0, 1000, 800);
    state.host.view.window = [NSObject new]; state.host.view.snapshotAvailable = snapshotAvailable;
    state.host.threadDragFiller = [UIView new]; state.host.threadDragFiller.frame = CGRectMake(500, 0, 300, 800);
    [state.host.view insertSubview:state.host.threadDragFiller belowSubview:nil];
    state.host.postsShowingDetail = YES;
    state.feed = [UINavigationController new]; state.feed.view = [UIView new];
    state.feed.viewControllers = @[[UIViewController new]];
    state.secondary = [UINavigationController new]; state.secondary.view = [UIView new];
    state.secondary.viewControllers = @[[UIViewController new], [UIViewController new]];
    return state;
}
static void Close(CGFloat offset, BOOL snapshotAvailable, BOOL animated, BOOL motion, BOOL onscreen) {
    ApolloDuoSplitState *state = State(snapshotAvailable);
    UIView *filler = state.host.threadDragFiller;
    if (!onscreen) state.host.view.window = nil;
    snapshotRequests = rememberedThreads = 0; fillerFadeDuration = 0; reduceMotion = motion;
    ApolloDuoPostsSetDetailPagesFromDrag(state, @[], animated, offset, 400);
    Check(state.host.threadDragFiller == nil, @"a completed close clears the host's filler reference even without a snapshot");
    Check(filler.superview == nil, @"a completed close removes the opaque filler from the feed surface");
    Check(state.secondary.viewControllers.count == 1 && !state.host.postsShowingDetail,
          @"the thread closes through the production stack/column transition");
    Check(rememberedThreads == 1, @"closing still remembers the thread for Forward");
    BOOL animate = animated && onscreen && !motion;
    Check(snapshotRequests == (animate && offset < 500 ? 1u : 0u),
          @"full-pane drags skip an empty snapshot; partial drags attempt one");
    if (animate && offset > 0) Check(fillerFadeDuration == 0.32, @"drag filler fades with the closing transition regardless of snapshot success");
    else Check(fillerFadeDuration == 0, @"nonanimated and ordinary closes remove stale filler immediately");
}
int main(void) { @autoreleasepool {
    Close(500, YES, YES, NO, YES); // Empty shot: the finger already moved the thread out of the pane.
    Close(650, YES, YES, NO, YES); // Defensive overshoot still creates an empty shot.
    Close(300, NO, YES, NO, YES); // UIKit can fail to produce an otherwise-valid snapshot.
    Close(300, YES, YES, NO, YES); // Normal snapshot animation retains existing cleanup.
    Close(0, YES, YES, NO, YES); // A button close clears any stale filler before animating.
    Close(300, YES, NO, NO, YES);
    Close(300, YES, YES, YES, YES);
    Close(300, YES, YES, NO, NO);
    reduceMotion = NO;
    ApolloDuoSplitState *state = State(YES); UIView *filler = state.host.threadDragFiller;
    NSArray *pages = @[[UIViewController new], [UIViewController new]];
    ApolloDuoPostsSetDetailPagesFromDrag(state, pages, YES, 300, 400);
    Check(!state.host.threadDragFiller && !filler.superview, @"opening/replacing a thread also retires stale drag filler");
    Check(state.secondary.viewControllers.count == 3, @"opening retains every page in the supplied Forward stack");
    printf("Duo thread drag cleanup: %lu checks passed\n", (unsigned long)checks);
} }
