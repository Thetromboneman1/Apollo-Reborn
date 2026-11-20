// Foundation-only Devvit custom-post detection shared by the live-widget
// renderer and feeds that need to classify raw classic-JSON t3 payloads.

#import "ApolloDevvitPosts.h"

static const NSUInteger kApolloDevvitMarkerWindow = 300;

BOOL ApolloDevvitSelfTextIsInteractiveForPostID(NSString *body, NSString *postID) {
    if (body.length < 40 || body.length > 40000) return NO;
    NSRange fallback = [body rangeOfString:@"not supported on old Reddit"
                                   options:NSCaseInsensitiveSearch];
    if (fallback.location == NSNotFound) return NO;
    NSUInteger from = fallback.location > kApolloDevvitMarkerWindow
                    ? fallback.location - kApolloDevvitMarkerWindow : 0;
    NSUInteger to = MIN(body.length, NSMaxRange(fallback) + kApolloDevvitMarkerWindow);
    NSRange window = NSMakeRange(from, to - from);
    NSRange shLink = [body rangeOfString:@"sh.reddit.com/r/" options:0 range:window];
    if (shLink.location == NSNotFound) return NO;
    if (postID.length == 0) return YES;

    NSUInteger tailStart = NSMaxRange(shLink);
    NSRange tail = NSMakeRange(tailStart, MIN(body.length - tailStart, (NSUInteger)140));
    NSRange comments = [body rangeOfString:@"/comments/" options:0 range:tail];
    if (comments.location == NSNotFound) return NO;
    NSUInteger idStart = NSMaxRange(comments);
    NSUInteger idEnd = idStart;
    static NSCharacterSet *base36 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        base36 = [NSCharacterSet characterSetWithCharactersInString:
                  @"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    });
    while (idEnd < body.length && idEnd - idStart < 20 &&
           [base36 characterIsMember:[body characterAtIndex:idEnd]]) {
        idEnd += 1;
    }
    if (idEnd == idStart) return NO;
    NSString *linkedID = [body substringWithRange:NSMakeRange(idStart, idEnd - idStart)];
    return [linkedID caseInsensitiveCompare:postID] == NSOrderedSame;
}

BOOL ApolloDevvitSelfTextIsInteractive(NSString *body) {
    return ApolloDevvitSelfTextIsInteractiveForPostID(body, nil);
}

static NSString *ApolloDevvitBarePostID(NSString *fullNameOrID) {
    if (![fullNameOrID isKindOfClass:[NSString class]] || fullNameOrID.length == 0) return nil;
    return [fullNameOrID hasPrefix:@"t3_"] ? [fullNameOrID substringFromIndex:3] : fullNameOrID;
}

BOOL ApolloDevvitPostDataIsInteractive(NSDictionary *postData) {
    if (![postData isKindOfClass:[NSDictionary class]]) return NO;
    id isSelf = postData[@"is_self"];
    if (![isSelf respondsToSelector:@selector(boolValue)] || ![isSelf boolValue]) return NO;
    id body = postData[@"selftext"];
    if (![body isKindOfClass:[NSString class]]) return NO;
    NSString *postID = ApolloDevvitBarePostID(postData[@"id"])
                    ?: ApolloDevvitBarePostID(postData[@"name"]);
    return ApolloDevvitSelfTextIsInteractiveForPostID(body, postID);
}
