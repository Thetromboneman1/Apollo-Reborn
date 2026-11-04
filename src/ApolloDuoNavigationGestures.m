#import "ApolloDuoNavigationGestures.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import "ApolloDuoPaneDrag.h"
#import <objc/runtime.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

// Apollo's pans use the whole navigation surface for edge checks. On Duo a
// visible pane can start well inside that surface, and the outer stack is a
// containment host. Qualify Back at the pane's left content edge (or anywhere
// with row left swipes disabled). A real page pop uses Apollo's interactive
// Back; a root drawer or closing thread follows the finger through Duo's
// surface drag. Split-only Back uses its own transition. The same environment
// gates the Forward swipe that restores a closed thread.
static BOOL ApolloDuoSwipeEnvironmentAllows(UINavigationController *navigation) {
    BOOL eligible = ApolloDeviceIsDuo() && navigation.viewIfLoaded.window
        && ![NSUserDefaults.standardUserDefaults boolForKey:@"DisableNavigationGestures"]
        && !ApolloDuoSplitIsResizing() && !navigation.transitionCoordinator
        && !navigation.presentedViewController && !navigation.topViewController.presentedViewController
        && !navigation.isBeingDismissed;
    if (!eligible) return NO;
    // Sheets can belong to the containing split, tab, or outer navigation
    // controller rather than the pane itself. Never navigate behind one.
    for (UIViewController *parent = navigation.parentViewController; parent; parent = parent.parentViewController) {
        if (parent.presentedViewController || parent.isBeingDismissed || parent.transitionCoordinator) return NO;
    }
    return YES;
}

static BOOL ApolloDuoBackSwipeCanNavigate(UINavigationController *navigation) {
    // A visited profile is a visit of the whole account split, header column
    // included: from either column, Back leaves the profile.
    BOOL pane = (navigation.viewControllers.count > 1 || ApolloDuoSplitCanRevealPostsListWithSwipe(navigation))
        && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitDetailNavigation(navigation) == navigation;
    return (pane || ApolloDuoSplitCanReturnFromVisitedProfile(navigation)) && ApolloDuoSwipeEnvironmentAllows(navigation);
}

// Gestures > Disable Left Swipes turns off the row actions a right swipe would
// trigger, and Apollo's own Back pan then starts anywhere on the page. Give a
// Duo pane the same reach; with the setting off only the edge strip qualifies.
// Either way a swipe acts on the pane it starts in: the feed's own Back while
// a thread stays open beside it, the thread's Back from the thread.
static BOOL ApolloDuoBackSwipeStartsAnywhere(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"DisableLeftSwipeGestureActions"];
}

static CGRect ApolloDuoBackSwipePane(UINavigationController *navigation) {
    UIView *view = navigation.view;
    CGRect pane = ApolloDuoSplitContentFrame(navigation, view);
    if (CGRectIsNull(pane)) {
        CGRect safe = view.safeAreaLayoutGuide.layoutFrame;
        // A full-width landscape screen can inset content for a camera or
        // rounded corner. Back still begins at its physical left edge.
        pane = CGRectMake(CGRectGetMinX(view.bounds), CGRectGetMinY(safe),
                          CGRectGetWidth(view.bounds), CGRectGetHeight(safe));
    }
    return pane;
}

static BOOL ApolloDuoBackSwipeInEdgeStrip(CGRect pane, CGPoint point) {
    return point.x <= CGRectGetMinX(pane) + 28.0;
}

static BOOL ApolloDuoBackSwipeAcceptsPoint(UINavigationController *navigation, CGPoint point) {
    if (!ApolloDuoBackSwipeCanNavigate(navigation)) return NO;
    CGRect pane = ApolloDuoBackSwipePane(navigation);
    if (CGRectIsEmpty(pane) || !CGRectContainsPoint(pane, point)) return NO;
    return ApolloDuoBackSwipeInEdgeStrip(pane, point) || ApolloDuoBackSwipeStartsAnywhere();
}

// The forward half. After the thread beside the Posts feed is closed, a left
// swipe on the full-width feed brings it back as it was left. It mirrors Back:
// the feed's trailing 28pt strip, or anywhere with Gestures > Disable Right
// Swipes on, which turns off the row actions a left swipe would trigger.
static BOOL ApolloDuoForwardSwipeStartsAnywhere(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"DisableRightSwipeGestureActions"];
}

static BOOL ApolloDuoForwardSwipeCanNavigate(UINavigationController *navigation) {
    return ApolloDuoSplitCanRestoreClosedThread(navigation) && ApolloDuoSwipeEnvironmentAllows(navigation);
}

static BOOL ApolloDuoForwardSwipeInEdgeStrip(CGRect pane, CGPoint point) {
    return point.x >= CGRectGetMaxX(pane) - 28.0;
}

static BOOL ApolloDuoForwardSwipeAcceptsPoint(UINavigationController *navigation, CGPoint point) {
    if (!ApolloDuoForwardSwipeCanNavigate(navigation)) return NO;
    CGRect pane = ApolloDuoBackSwipePane(navigation);
    if (CGRectIsEmpty(pane) || !CGRectContainsPoint(pane, point)) return NO;
    return ApolloDuoForwardSwipeInEdgeStrip(pane, point) || ApolloDuoForwardSwipeStartsAnywhere();
}

// Away from the edge strip, content with its own sideways drag keeps it: a
// gallery or carousel that can still page back, and sliders/switches. When
// the swipe would only reveal a root's list, any sideways scroller keeps it,
// even at its leading end or when its content fits (one that bounces
// sideways still drags): a Community Highlights carousel is being scrolled,
// not asked to open the list over itself. Forward mirrors it: a scroller keeps
// the touch until it has scrolled to its trailing end.
static BOOL ApolloDuoBackSwipeTouchOwnsHorizontalDrag(UIView *view, UIView *container, BOOL rootReveal, BOOL forward) {
    for (UIView *candidate = view; candidate && candidate != container; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UISlider.class] || [candidate isKindOfClass:UISwitch.class]) return YES;
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)candidate;
        if (!scroll.scrollEnabled) continue;
        BOOL overflows = scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1.0;
        if (forward) {
            CGFloat trailingOffset = scroll.contentSize.width + scroll.adjustedContentInset.right - CGRectGetWidth(scroll.bounds);
            if (overflows && scroll.contentOffset.x < trailingOffset - 0.5) return YES;
            continue;
        }
        if (rootReveal ? overflows || scroll.alwaysBounceHorizontal
                       : overflows && scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5) return YES;
    }
    return NO;
}

// Mirrors swiped: below. Leaving a visited profile and popping a page are
// Back; only a plain root reveals its list.
static BOOL ApolloDuoBackSwipeRevealsAtRoot(UINavigationController *navigation) {
    return navigation.viewControllers.count == 1 && !ApolloDuoSplitCanReturnFromVisitedProfile(navigation);
}

// The row under the finger highlights on touchesBegan, before any swipe has
// moved far enough to recognize. Like UIScrollView's delaysContentTouches,
// hold that touch-down back while the guard is undecided: it recognizes on a
// clear sideways move (cancelling the row's touch), and otherwise fails on a
// vertical move or after a short delay, when UIKit delivers the withheld
// touches. Taps and press-and-hold still highlight, only that much later.
static const NSTimeInterval kApolloDuoHighlightGuardDelay = 0.12;

@interface ApolloDuoHighlightGuard : UIPanGestureRecognizer
@property(nonatomic) CGPoint touchStart;
@property(nonatomic) NSUInteger touchGeneration;
@end

@implementation ApolloDuoHighlightGuard
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        self.maximumNumberOfTouches = 1;
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = YES;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.state != UIGestureRecognizerStatePossible) return;
    self.touchStart = [touches.anyObject locationInView:self.view];
    NSUInteger generation = ++self.touchGeneration;
    __weak ApolloDuoHighlightGuard *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloDuoHighlightGuardDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf failIfUndecided:generation]; });
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible) {
        CGPoint point = [touches.anyObject locationInView:self.view];
        CGFloat dx = point.x - self.touchStart.x, dy = point.y - self.touchStart.y;
        // Scrolling: give the row its touch back at once.
        if (fabs(dy) > 6.0 && fabs(dy) > fabs(dx)) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
    }
    [super touchesMoved:touches withEvent:event];
}
- (void)failIfUndecided:(NSUInteger)generation {
    if (generation == self.touchGeneration && self.state == UIGestureRecognizerStatePossible)
        self.state = UIGestureRecognizerStateFailed;
}
- (void)reset {
    [super reset];
    self.touchGeneration++;
}
@end

BOOL ApolloDuoPaneBackIsNative(UINavigationController *navigation) {
    return !ApolloDuoSplitCanReturnFromVisitedProfile(navigation)
        && !ApolloDuoSplitIsResizing() && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitPopRevealsContent(navigation);
}

static ApolloDuoBackRoute ApolloDuoPaneBackRoute(UINavigationController *navigation) {
    return ApolloDuoBackRouteFor(ApolloDuoBackSwipeCanNavigate(navigation),
                                 ApolloDuoPaneBackIsNative(navigation),
                                 ApolloDuoSplitCanRevealPostsListWithSwipe(navigation),
                                 ApolloDuoSplitCanDragThreadClosed(navigation));
}

static UIGestureRecognizer *ApolloDuoNativeBackPan(UINavigationController *navigation) {
    Ivar ivar = navigation ? class_getInstanceVariable(navigation.class, "leftScreenEdgePanGestureRecognizer") : NULL;
    id pan = ivar ? object_getIvar(navigation, ivar) : nil;
    return [pan isKindOfClass:UIGestureRecognizer.class] ? pan : nil;
}

static BOOL ApolloDuoIsScrollPan(UIGestureRecognizer *gesture) {
    return [gesture.view isKindOfClass:UIScrollView.class]
        && gesture == ((UIScrollView *)gesture.view).panGestureRecognizer;
}

@interface ApolloDuoBackSwipe : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UINavigationController *navigation;
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
@property(nonatomic) ApolloDuoBackRoute route;
@property(nonatomic) CGFloat start;
// The forward half: a left swipe that brings back the thread just closed.
@property(nonatomic, strong) UISwipeGestureRecognizer *forwardSwipe;
// Recognizes as soon as a touch Back or Forward accepts moves sideways, so
// the row under the finger drops its highlight before the navigation completes.
// Either direction: a leftward move is a row action, which still runs alongside.
@property(nonatomic, strong) ApolloDuoHighlightGuard *highlightGuard;
@end

static NSHashTable<ApolloDuoBackSwipe *> *sDuoPaneDrags;

@implementation ApolloDuoBackSwipe
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    UINavigationController *navigation = self.navigation;
    CGPoint point = [touch locationInView:navigation.view];
    if (gesture != self.pan && gesture != self.forwardSwipe && gesture != self.highlightGuard) return NO;
    BOOL back = gesture != self.forwardSwipe && ApolloDuoBackSwipeAcceptsPoint(navigation, point)
        && (ApolloDuoBackSwipeInEdgeStrip(ApolloDuoBackSwipePane(navigation), point)
            || !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(touch.view, navigation.view, ApolloDuoBackSwipeRevealsAtRoot(navigation), NO));
    // A carousel keeps its sideways swipes until it is at its last item, in
    // the strip too: Back gets that from the carousel's own yielding.
    BOOL forward = gesture != self.pan && ApolloDuoForwardSwipeAcceptsPoint(navigation, point)
        && !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(touch.view, navigation.view, NO, YES);
    return back || forward;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.forwardSwipe) return ApolloDuoForwardSwipeCanNavigate(self.navigation);
    if (gesture == self.highlightGuard) {
        if (!ApolloDuoBackSwipeCanNavigate(self.navigation) && !ApolloDuoForwardSwipeCanNavigate(self.navigation)) return NO;
        CGPoint velocity = [self.highlightGuard velocityInView:self.navigation.view];
        return fabs(velocity.x) > fabs(velocity.y) * 1.5;
    }
    if (gesture != self.pan) return NO;
    // Window coordinates: the thread route moves this pan's own view.
    CGPoint translation = [self.pan translationInView:nil];
    CGPoint velocity = [self.pan velocityInView:nil];
    if (!ApolloDuoDragIsRightward(translation.x, translation.y, velocity.x, velocity.y)) return NO;
    self.route = ApolloDuoPaneBackRoute(self.navigation);
    return self.route != ApolloDuoBackRouteNone && self.route != ApolloDuoBackRouteNative;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if (gesture == self.highlightGuard || other == self.highlightGuard) return YES;
    return gesture == self.forwardSwipe && ApolloDuoIsScrollPan(other);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // Native Back owns real page pops. Neither a scroll pan nor the highlight
    // guard waits for the pane's navigation recognizers.
    return (gesture == self.pan || gesture == self.forwardSwipe) && other != self.highlightGuard
        && [other isKindOfClass:UIPanGestureRecognizer.class] && !ApolloDuoIsScrollPan(other)
        && other != ApolloDuoNativeBackPan(self.navigation);
}
- (void)guardMoved:(__unused UIPanGestureRecognizer *)gesture {
    // Recognizing cancels the row's touch and clears its highlight.
}
- (void)swiped:(UISwipeGestureRecognizer *)gesture {
    if (gesture != self.forwardSwipe || gesture.state != UIGestureRecognizerStateRecognized
        || !ApolloDuoForwardSwipeCanNavigate(self.navigation)) return;
    ApolloDuoSplitRestoreClosedThread(self.navigation);
}
- (void)cancel {
    UIGestureRecognizerState state = self.pan.state;
    if (state != UIGestureRecognizerStateBegan && state != UIGestureRecognizerStateChanged) return;
    self.pan.enabled = NO;
    self.pan.enabled = YES;
}
- (void)panned:(UIPanGestureRecognizer *)pan {
    UINavigationController *navigation = self.navigation;
    CGFloat dx = [pan translationInView:nil].x;
    CGFloat vx = [pan velocityInView:nil].x;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self beginRoute:navigation];
            [self track:navigation dx:dx];
            break;
        case UIGestureRecognizerStateChanged:
            if (ApolloDuoSplitIsResizing() || !navigation.viewIfLoaded.window) {
                [self cancel];
                break;
            }
            [self track:navigation dx:dx];
            break;
        case UIGestureRecognizerStateEnded:
            [self finish:navigation dx:dx velocity:vx cancelled:NO];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self finish:navigation dx:dx velocity:0 cancelled:YES];
            break;
        default:
            break;
    }
}
- (void)beginRoute:(UINavigationController *)navigation {
    ApolloLog(@"[DuoDrag] pane Back began route=%d pages=%lu", (int)self.route,
              (unsigned long)navigation.viewControllers.count);
    switch (self.route) {
        case ApolloDuoBackRouteDrawer:
            if (!ApolloDuoSplitBeginListDrag(navigation)) self.route = ApolloDuoBackRouteNone;
            else self.start = ApolloDuoSplitListDragStart(navigation);
            break;
        case ApolloDuoBackRouteCloseThread: {
            CGFloat offset = ApolloDuoSplitBeginThreadDrag(navigation);
            if (offset < 0) self.route = ApolloDuoBackRouteNone;
            else self.start = offset;
            break;
        }
        case ApolloDuoBackRoutePop:
            // A Back only the split lays out has no surface to follow the
            // finger; run it as soon as the drag is clearly a Back.
            if (!ApolloDuoSplitReturnFromVisitedProfile(navigation))
                [navigation popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
            self.route = ApolloDuoBackRouteNone;
            break;
        default:
            self.route = ApolloDuoBackRouteNone;
            break;
    }
}
- (void)track:(UINavigationController *)navigation dx:(CGFloat)dx {
    if (self.route == ApolloDuoBackRouteDrawer) {
        ApolloDuoSplitMoveListDrag(navigation, self.start + dx);
    } else if (self.route == ApolloDuoBackRouteCloseThread) {
        ApolloDuoSplitDragThread(navigation, ApolloDuoDragClamp(self.start + dx, ApolloDuoSplitThreadDragTravel(navigation)));
    }
}
- (void)finish:(UINavigationController *)navigation dx:(CGFloat)dx velocity:(CGFloat)vx cancelled:(BOOL)cancelled {
    ApolloDuoBackRoute route = self.route;
    self.route = ApolloDuoBackRouteNone;
    if (route == ApolloDuoBackRouteDrawer) {
        CGFloat travel = ApolloDuoSplitListDragTravel(navigation);
        CGFloat shown = ApolloDuoDragClamp(self.start + dx, travel);
        ApolloDuoSplitEndListDrag(navigation, !cancelled && ApolloDuoDragCommits(shown, travel, vx), vx);
    } else if (route == ApolloDuoBackRouteCloseThread) {
        CGFloat travel = ApolloDuoSplitThreadDragTravel(navigation);
        CGFloat offset = ApolloDuoDragClamp(self.start + dx, travel);
        ApolloDuoSplitEndThreadDrag(navigation, !cancelled && ApolloDuoDragCommits(offset, travel, vx), offset, vx);
    }
}
@end

static char kApolloDuoBackSwipe;
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation) {
    return objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe) != nil;
}

void ApolloDuoCancelPaneDrags(void) {
    for (ApolloDuoBackSwipe *owner in sDuoPaneDrags.allObjects) [owner cancel];
}

void ApolloDuoInstallBackSwipe(UINavigationController *navigation) {
    if (!ApolloDeviceIsDuo() || !navigation.isViewLoaded || ApolloDuoHasBackSwipe(navigation)) return;
    ApolloDuoBackSwipe *owner = [ApolloDuoBackSwipe new];
    owner.navigation = navigation;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:owner action:@selector(panned:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = owner;
    pan.name = @"ApolloReborn.Duo.PaneBack";
    owner.pan = pan;
    UISwipeGestureRecognizer *forwardSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:owner action:@selector(swiped:)];
    forwardSwipe.direction = UISwipeGestureRecognizerDirectionLeft;
    forwardSwipe.numberOfTouchesRequired = 1;
    forwardSwipe.delegate = owner;
    forwardSwipe.name = @"ApolloReborn.Duo.PaneForward";
    owner.forwardSwipe = forwardSwipe;
    ApolloDuoHighlightGuard *highlightGuard = [[ApolloDuoHighlightGuard alloc] initWithTarget:owner action:@selector(guardMoved:)];
    highlightGuard.delegate = owner;
    highlightGuard.name = @"ApolloReborn.Duo.PaneBackHighlightGuard";
    owner.highlightGuard = highlightGuard;
    objc_setAssociatedObject(navigation, &kApolloDuoBackSwipe, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation.view addGestureRecognizer:pan];
    [navigation.view addGestureRecognizer:forwardSwipe];
    [navigation.view addGestureRecognizer:highlightGuard];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDuoPaneDrags = [NSHashTable weakObjectsHashTable];
        // Backgrounding mid-drag (Control Center, a call) springs it back.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { ApolloDuoCancelPaneDrags(); }];
    });
    [sDuoPaneDrags addObject:owner];
}
