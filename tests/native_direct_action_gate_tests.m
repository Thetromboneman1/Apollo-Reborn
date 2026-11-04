#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ApolloSwiftRuntime.h"

@interface UIView : NSObject @end
@implementation UIView @end
@interface UIViewController : NSObject @end
@implementation UIViewController @end
@interface ApolloTestActionController : NSObject { @public BOOL actionsEnabled; } @end
@implementation ApolloTestActionController @end
@interface ApolloTestControllerWithoutFlag : NSObject @end
@implementation ApolloTestControllerWithoutFlag @end

static Class ApolloClassActionController;
static BOOL sApolloNativeCapturingController;
static BOOL sApolloNativeCapturingMenuContext;
static id sApolloNativeCapturedController;
static UIViewController *sApolloNativeDirectActionOwner;
static UIView *sApolloNativeDirectActionSourceView;
static uint16_t sApolloNativeDirectActionKind;
static char kApolloNativeActionMenuSourceViewKey;
static NSInteger sRow;
static unsigned sPrepared, sSelected;

#define ApolloLog(...) ((void)0)
static void ApolloActionMenuCaptureContextForController(__unused id controller) {}
static void ApolloActionMenuPrepareControllerForDirectAction(__unused id controller) { sPrepared++; }
static NSInteger ApolloNativeActionMenuRowForActionKind(__unused id controller, __unused uint16_t kind) { return sRow; }
static void ApolloNativeActionMenuSelectRow(__unused id controller, __unused NSInteger row) { sSelected++; }

// INCLUDE_PRODUCTION_DIRECT_DISPATCH

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static BOOL Attempt(id controller, NSInteger row) {
    sApolloNativeDirectActionOwner = [UIViewController new];
    sApolloNativeDirectActionSourceView = [UIView new];
    sApolloNativeDirectActionKind = 12;
    sRow = row;
    return ApolloNativeActionMenuPerformPendingDirectAction(controller);
}

int main(void) {
    @autoreleasepool {
        ApolloClassActionController = NSObject.class;
        ApolloTestActionController *controller = [ApolloTestActionController new];
        controller->actionsEnabled = NO;
        Check(Attempt(controller, 0), "disabled direct action is consumed");
        Check(sPrepared == 0 && sSelected == 0, "disabled action never prepares or selects a row");
        Check(!sApolloNativeDirectActionOwner, "disabled attempt clears pending owner");

        Check(Attempt([ApolloTestControllerWithoutFlag new], 0), "missing guard is consumed");
        Check(sPrepared == 0 && sSelected == 0, "missing actionsEnabled fails closed");

        controller->actionsEnabled = YES;
        Check(Attempt(controller, NSNotFound), "missing Reply is consumed");
        Check(sPrepared == 1 && sSelected == 0, "missing Reply never selects a row");

        Check(Attempt(controller, 0), "enabled Reply is consumed");
        Check(sPrepared == 2 && sSelected == 1, "enabled Reply selects its native row once");
        Check(objc_getAssociatedObject(controller, &kApolloNativeActionMenuSourceViewKey) != nil,
              "enabled action retains its source anchor");
    }
    puts("Native direct action gate: 10 checks passed");
    return 0;
}
