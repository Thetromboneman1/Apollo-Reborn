#import <UIKit/UIKit.h>

#import "ApolloSettingsForm.h"

// Dedicated "Subreddit List Sections" screen: a declarative form whose
// "Preview" section carries the shared pinned preview
// (ApolloSettingsPinnedPreview.h), a live preview of the Subreddits list's
// section layout. The preview stays on screen while the option toggles
// (Separate Followed Users, Hide Multireddit Descriptions, Subreddit List
// Enhancements, Modern Subreddit Dividers) and the drag-to-reorder Section
// Order rows scroll beneath it, and every change animates the preview's bands
// and sample rows into place instead of reloading it. Pushed from the
// Subreddits group screen's "Subreddit Sections" row (settings route
// "subreddit-sections").
@interface ApolloSubredditSectionsViewController : ApolloSettingsFormViewController
@end
