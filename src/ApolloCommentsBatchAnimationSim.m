#import "ApolloCommentsBatchAnimation.h"

#if !APOLLO_SIM_BUILD
#error ApolloCommentsBatchAnimationSim.m must only be compiled for simulator builds
#endif

void ApolloCommentsRunWithAnimatedBatch(__unused NSString *reason,
                                        NS_NOESCAPE dispatch_block_t body,
                                        __unused void (^willAnimate)(id tableNode),
                                        void (^didFinish)(BOOL finished)) {
    if (!body) return;
    body();
    if (didFinish) didFinish(YES);
}
