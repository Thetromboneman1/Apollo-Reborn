#import "../ApolloDuoSplitView.h"
#import "settings/ApolloSubredditSectionsViewController.h"

#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloDuoRail.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsPinnedPreview.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// The screen is a declarative form whose first section, "Preview", holds the
// shared pinned preview (ApolloSettingsPinnedPreview.h), the same block Inline
// Media and Rich Link Previews use: a transparent spacer row the card rests
// on, a card hosted directly in the table that stays put (with a copy of the
// section title) while the toggles and the drag-to-reorder rows scroll
// beneath it, and the shared pin glyph in the card's top-right corner. Tapping
// the card pins/unpins it; the choice is persisted per screen
// (UDKeySubredditSectionsPreviewPinned, default pinned). Every change animates
// the preview's bands and sample rows into their new places — nothing
// reloads — and the spacer row springs to the new card height in the same
// beat.
//
// The preview is a miniature, non-interactive rendering of the Subreddits
// list: one band + sample row per special section in the configured order,
// then a letter band showing where the alphabetical list continues. Each
// block carries a stable KEY (what it is) and a SIGNATURE (how it looks) so a
// refresh can diff two renderings: a block whose key survives slides from its
// old place to its new one (the sample followed user moves between the
// FOLLOWING band and the letter band as the separation toggle flips; every
// band below a reordered section shifts), a block whose signature changed
// cross-fades in place (a band restyled by the dividers toggle, the
// multireddit row gaining or losing its description), and blocks that appear
// or disappear scale-fade (the FOLLOWING band itself).

#pragma mark - Preview model

typedef NS_ENUM(NSInteger, ApolloSubredditSectionsPreviewBlockKind) {
    ApolloSubredditSectionsPreviewBlockKindBand,
    ApolloSubredditSectionsPreviewBlockKindRow,
};

// Native RedditListTableViewCell uses a 28 × 28 point subreddit icon.
static const CGFloat kApolloSectionsPreviewIconSize = 28.0;
static const CGFloat kApolloSectionsPreviewAccessoryInset = 22.0;
static const CGFloat kApolloSectionsPreviewBandHeight = 22.0;
static const CGFloat kApolloSectionsPreviewRowHeight = 30.0;
static const CGFloat kApolloSectionsPreviewDetailRowHeight = 48.0;
// Both divider styles share geometry; toggling only restyles the bands.
static const CGFloat kApolloSectionsPreviewTopPadding = 10.0;
static const CGFloat kApolloSectionsPreviewBottomPadding = 8.0;
static const CGFloat kApolloSectionsPreviewBlockSpacing = 3.0;
// Room the first band's rule leaves for the shared pin glyph (12pt trailing
// inset + 22pt glyph box + 10pt gap).
static const CGFloat kApolloSectionsPreviewPinCornerReserve = 44.0;

@interface ApolloSubredditSectionsPreviewBlock : NSObject
@property (nonatomic) ApolloSubredditSectionsPreviewBlockKind kind;
@property (nonatomic, copy) NSString *key;          // identity across renderings
@property (nonatomic, copy) NSString *signature;    // appearance; a change cross-fades
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;     // rows only
@property (nonatomic, strong) UIColor *circleColor; // rows only
@property (nonatomic) BOOL showIcon;
@property (nonatomic) BOOL starred;                 // rows only
@property (nonatomic) BOOL modern;                  // bands only
@property (nonatomic) CGFloat height;
@end

@implementation ApolloSubredditSectionsPreviewBlock
@end

static ApolloSubredditSectionsPreviewBlock *ApolloSectionsPreviewBand(NSString *key, NSString *title, BOOL modern) {
    ApolloSubredditSectionsPreviewBlock *block = [ApolloSubredditSectionsPreviewBlock new];
    block.kind = ApolloSubredditSectionsPreviewBlockKindBand;
    block.key = key;
    block.title = title;
    block.modern = modern;
    block.signature = [NSString stringWithFormat:@"band|%@|%d", title, modern];
    block.height = kApolloSectionsPreviewBandHeight;
    return block;
}

static ApolloSubredditSectionsPreviewBlock *ApolloSectionsPreviewRow(NSString *key,
                                                                    NSString *name,
                                                                    NSString *subtitle,
                                                                    UIColor *circleColor,
                                                                    BOOL starred) {
    ApolloSubredditSectionsPreviewBlock *block = [ApolloSubredditSectionsPreviewBlock new];
    block.kind = ApolloSubredditSectionsPreviewBlockKindRow;
    block.key = key;
    block.title = name;
    block.subtitle = subtitle;
    block.circleColor = circleColor;
    block.starred = starred;
    block.signature = [NSString stringWithFormat:@"row|%@|%@|%d", name, subtitle ?: @"", starred];
    block.height = subtitle.length > 0 ? kApolloSectionsPreviewDetailRowHeight : kApolloSectionsPreviewRowHeight;
    return block;
}

@interface ApolloSubredditSectionsPreviewState : NSObject
@property (nonatomic, copy) NSArray<ApolloSubredditSectionsPreviewBlock *> *blocks;
@property (nonatomic) CGFloat previewHeight;
@property (nonatomic) CGFloat separatorTrailingInset;
@end

@implementation ApolloSubredditSectionsPreviewState
@end

// The custom drag interaction keeps its proposed order local until the user
// drops the row. The preview reads the same draft so it remains live without
// writing preferences or reloading the real subreddit list at every crossing.
static NSArray<NSString *> *sApolloSubredditSectionsPreviewDraftOrder;

// Compare identity/order as well as styling, including icon visibility.
static BOOL ApolloPreviewStatesEqual(ApolloSubredditSectionsPreviewState *a,
                                    ApolloSubredditSectionsPreviewState *b) {
    if (!a || !b || a.blocks.count != b.blocks.count) return NO;
    for (NSUInteger i = 0; i < a.blocks.count; i++) {
        if (![a.blocks[i].key isEqualToString:b.blocks[i].key] ||
            ![a.blocks[i].signature isEqualToString:b.blocks[i].signature]) return NO;
    }
    return YES;
}

// The rendering the current settings call for. The sample followed user
// ("u/username") sits under FOLLOWING with separation on and under the U
// letter band without — exactly what that toggle changes. Band styling
// follows Modern Subreddit Dividers (accent label + hairline) vs the classic
// grey band, collapsing to classic when Subreddit List Enhancements is off —
// the same rules the real list applies. The multireddit row lists its
// subreddits as a subtitle unless Hide Multireddit Descriptions is on,
// matching the real list (where a custom description takes the subtitle's
// place; the sample shows the default).
static ApolloSubredditSectionsPreviewState *ApolloSubredditSectionsCurrentPreviewState(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL modern = (sSubredditListEnhancements || ApolloDuoRequiresSubredditEnhancements()) && [defaults boolForKey:UDKeyModernSubredditDividers];
    BOOL separate = [defaults boolForKey:UDKeySeparateFollowedUsers];
    NSString *multiredditSubtitle = sHideMultiredditDescriptions ? nil : @"ApolloReborn, iOS, Swift";

    NSMutableArray<ApolloSubredditSectionsPreviewBlock *> *blocks = [NSMutableArray array];
    NSArray<NSString *> *sectionOrder = sApolloSubredditSectionsPreviewDraftOrder
        ?: ApolloSubredditSectionsResolvedOrder();
    for (NSString *token in sectionOrder) {
        if ([token isEqualToString:ApolloSubredditSectionTokenFavorites]) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.favorites", @"FAVORITES", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.apolloapp", @"Apolloapp", nil, UIColor.systemIndigoColor, YES)];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenMultireddits]) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.multireddits", @"MULTIREDDITS", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.multireddit", @"My Multireddit", multiredditSubtitle, UIColor.systemTealColor, NO)];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenModerator]) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.moderator", @"MODERATOR", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.modclub", @"Modclub", nil, UIColor.systemGreenColor, NO)];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenFollowing] && separate) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.following", @"FOLLOWING", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.username", @"u/Username", nil, UIColor.systemOrangeColor, NO)];
        }
    }
    // Where the A-Z list picks up. Without separation the followed user sits
    // in its letter section — the same "row.username" key, so it slides
    // between the two places when the toggle flips.
    [blocks addObject:ApolloSectionsPreviewBand(@"band.letter", @"U", modern)];
    [blocks addObject:ApolloSectionsPreviewRow(@"row.ukulele", @"Ukulele", nil, UIColor.systemPurpleColor, NO)];
    if (!separate) {
        [blocks addObject:ApolloSectionsPreviewRow(@"row.username", @"u/Username", nil, UIColor.systemOrangeColor, NO)];
    }

    id iconPreference = [defaults objectForKey:UDKeyShowSubredditIconsInSubredditList];
    BOOL showIcons = iconPreference ? [iconPreference boolValue] : YES;
    for (ApolloSubredditSectionsPreviewBlock *block in blocks) {
        if (block.kind == ApolloSubredditSectionsPreviewBlockKindRow) {
            block.showIcon = showIcons;
            block.signature = [block.signature stringByAppendingFormat:@"|icons:%d", showIcons];
        }
    }
    CGFloat height = kApolloSectionsPreviewTopPadding + kApolloSectionsPreviewBottomPadding;
    for (ApolloSubredditSectionsPreviewBlock *block in blocks) height += block.height;
    if (blocks.count > 1) height += (blocks.count - 1) * kApolloSectionsPreviewBlockSpacing;

    ApolloSubredditSectionsPreviewState *state = [ApolloSubredditSectionsPreviewState new];
    state.blocks = blocks;
    state.previewHeight = height;
    state.separatorTrailingInset = sSubredditListEnhancements ? kApolloSectionsPreviewAccessoryInset : 0.0;
    if (!separate && !modern) {
        for (ApolloSubredditSectionsPreviewBlock *block in blocks) {
            if ([block.key isEqualToString:@"row.ukulele"]) {
                block.signature = [block.signature stringByAppendingFormat:@"|separator:%g", state.separatorTrailingInset];
            }
        }
    }
    return state;
}

#pragma mark - Preview view

// The preview is decorative and must look complete immediately, including on
// a fresh install and offline. These 84px assets are exactly 28pt at 3x, so
// they carry no resolution the preview can never display.
static UIImage *ApolloPreviewBundledIcon(NSString *blockKey) {
    static NSDictionary<NSString *, NSString *> *resourceNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resourceNames = @{
            @"row.apolloapp": @"SubredditSectionsPreviewApolloapp",
            @"row.multireddit": @"SubredditSectionsPreviewApolloReborn",
            @"row.modclub": @"SubredditSectionsPreviewModclub",
            @"row.username": @"SubredditSectionsPreviewReddit",
            @"row.ukulele": @"SubredditSectionsPreviewUkulele",
        };
    });
    NSString *resourceName = resourceNames[blockKey];
    NSString *path = ApolloBundledResourcePath(resourceName, @"png");
    return path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
}

// Use the backing layer so Auto Layout sizes the gradient without a second
// layout pass. Resolve the dynamic theme accent against this view's traits.
@interface ApolloSubredditPreviewDivider : UIView
@end

@implementation ApolloSubredditPreviewDivider
+ (Class)layerClass { return CAGradientLayer.class; }

- (void)layoutSubviews {
    [super layoutSubviews];
    UIColor *accent = [(ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor)
        resolvedColorWithTraitCollection:self.traitCollection];
    CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Match the real subreddit list's three-stop fade in ApolloSubredditIndexPolish.
    gradient.startPoint = CGPointMake(0.0, 0.5);
    gradient.endPoint = CGPointMake(1.0, 0.5);
    gradient.colors = @[
        (__bridge id)[accent colorWithAlphaComponent:0.76].CGColor,
        (__bridge id)[accent colorWithAlphaComponent:0.38].CGColor,
        (__bridge id)[accent colorWithAlphaComponent:0.0].CGColor,
    ];
    gradient.locations = @[@0.0, @0.62, @1.0];
    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
}
@end

@interface ApolloSubredditSectionsPreviewView : UIView
@property (nonatomic, strong) ApolloSubredditSectionsPreviewState *previewState;
// The rendered block views and their signatures, keyed by block key — what
// the container's refresh diffs against the previous rendering.
@property (nonatomic, copy) NSDictionary<NSString *, UIView *> *itemViewsByKey;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *itemSignaturesByKey;
- (void)apollo_configurePreview;
@end

@implementation ApolloSubredditSectionsPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    return self;
}

- (UIColor *)apollo_accentColor {
    return ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
}

// One section band: the header strip in the block's divider style.
// reservePinCorner: the first block sits under the shared pin glyph in the
// card's top-right corner, so a modern band's rule stops short of it.
- (UIView *)apollo_bandViewForBlock:(ApolloSubredditSectionsPreviewBlock *)block
                   reservePinCorner:(BOOL)reservePinCorner {
    UIView *band = [UIView new];
    UILabel *label = [UILabel new];
    label.text = block.title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [band addSubview:label];
    if (block.modern) {
        label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        label.textColor = [self apollo_accentColor];
        label.alpha = 0.9;
        UIView *line = [ApolloSubredditPreviewDivider new];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [band addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:band.leadingAnchor constant:22.0],
            [label.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
            [line.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:12.0],
            [line.trailingAnchor constraintEqualToAnchor:band.trailingAnchor
                                                constant:reservePinCorner ? -kApolloSectionsPreviewPinCornerReserve : -12.0],
            [line.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
            [line.heightAnchor constraintEqualToConstant:2.0],
        ]];
    } else {
        band.backgroundColor = ApolloThemeSubredditListHeaderBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        // Native classic headers use opaque #666666 in light mode. UIKit's
        // translucent secondaryLabel is lighter over the pale section band.
        label.textColor = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:band.leadingAnchor constant:22.0],
            [label.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
        ]];
    }
    [band.heightAnchor constraintEqualToConstant:block.height].active = YES;
    return band;
}

// One sample row: colored initial-circle + name (+ subtitle, + star).
- (UIView *)apollo_rowViewForBlock:(ApolloSubredditSectionsPreviewBlock *)block {
    UIView *row = [UIView new];

    UILabel *icon = [UILabel new];
    icon.tag = 101;
    NSString *bareName = [block.title stringByReplacingOccurrencesOfString:@"u/" withString:@""];
    icon.text = bareName.length > 0 ? [bareName substringToIndex:1].uppercaseString : @"";
    icon.font = [UIFont systemFontOfSize:kApolloSectionsPreviewIconSize / 2.0 weight:UIFontWeightBold];
    icon.textColor = UIColor.whiteColor;
    icon.textAlignment = NSTextAlignmentCenter;
    icon.backgroundColor = block.circleColor;
    icon.layer.cornerRadius = kApolloSectionsPreviewIconSize / 2.0;
    icon.clipsToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.hidden = !block.showIcon;
    [row addSubview:icon];
    UIImage *bundledIcon = block.showIcon ? ApolloPreviewBundledIcon(block.key) : nil;
    if (bundledIcon) {
        UIImageView *imageView = [UIImageView new];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.image = bundledIcon;
        [icon addSubview:imageView];
        [NSLayoutConstraint activateConstraints:@[
            [imageView.leadingAnchor constraintEqualToAnchor:icon.leadingAnchor],
            [imageView.trailingAnchor constraintEqualToAnchor:icon.trailingAnchor],
            [imageView.topAnchor constraintEqualToAnchor:icon.topAnchor],
            [imageView.bottomAnchor constraintEqualToAnchor:icon.bottomAnchor],
        ]];
        icon.text = nil;
        icon.backgroundColor = UIColor.clearColor;
    }


    UILabel *label = [UILabel new];
    label.text = block.title;
    label.tag = 102;
    label.font = [UIFont systemFontOfSize:17.0];
    label.textColor = ApolloThemeSubredditListTextColor() ?: UIColor.labelColor;
    NSMutableArray<UIView *> *textViews = [NSMutableArray arrayWithObject:label];
    if (block.subtitle.length > 0) {
        UILabel *detail = [UILabel new];
        detail.tag = 103;
        detail.text = block.subtitle;
        detail.font = [UIFont systemFontOfSize:13.0];
        detail.textColor = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
        [textViews addObject:detail];
    }
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:textViews];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = 1.0;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:text];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:22.0],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:kApolloSectionsPreviewIconSize],
        [icon.heightAnchor constraintEqualToConstant:kApolloSectionsPreviewIconSize],
        block.showIcon ? [text.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10.0]
            : [text.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:22.0],
        [text.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintEqualToConstant:block.height],
    ]];
    if (block.starred) {
        // Apollo’s list uses its bundled 20 × 19 point star, not an SF Symbol.
        UIImage *starImage = [[UIImage imageNamed:@"star"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIImageView *star = [[UIImageView alloc] initWithImage:starImage];
        star.tag = 104;
        star.tintColor = [self apollo_accentColor];
        star.contentMode = UIViewContentModeScaleAspectFit;
        star.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:star];
        [constraints addObjectsFromArray:@[
            [star.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kApolloSectionsPreviewAccessoryInset],
            [star.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [star.widthAnchor constraintEqualToConstant:20.0],
            [star.heightAnchor constraintEqualToConstant:19.0],
            [text.trailingAnchor constraintLessThanOrEqualToAnchor:star.leadingAnchor constant:-8.0],
        ]];
    } else {
        [constraints addObject:[text.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-22.0]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return row;
}

- (void)apollo_configurePreview {
    for (UIView *view in self.subviews) [view removeFromSuperview];
    ApolloSubredditSectionsPreviewState *state = self.previewState;
    if (!state) return;

    NSMutableArray<UIView *> *blockViews = [NSMutableArray arrayWithCapacity:state.blocks.count];
    NSMutableDictionary<NSString *, UIView *> *viewsByKey = [NSMutableDictionary dictionaryWithCapacity:state.blocks.count];
    NSMutableDictionary<NSString *, NSString *> *signaturesByKey = [NSMutableDictionary dictionaryWithCapacity:state.blocks.count];
    for (ApolloSubredditSectionsPreviewBlock *block in state.blocks) {
        UIView *view = block.kind == ApolloSubredditSectionsPreviewBlockKindBand
            ? [self apollo_bandViewForBlock:block reservePinCorner:(blockViews.count == 0)]
            : [self apollo_rowViewForBlock:block];
        [blockViews addObject:view];
        viewsByKey[block.key] = view;
        signaturesByKey[block.key] = block.signature;
    }
    for (NSUInteger i = 0; i + 1 < state.blocks.count; i++) {
        if (state.blocks.firstObject.modern ||
            state.blocks[i].kind != ApolloSubredditSectionsPreviewBlockKindRow ||
            state.blocks[i + 1].kind != ApolloSubredditSectionsPreviewBlockKindRow) continue;
        UIView *row = blockViews[i];
        UIView *separator = [UIView new];
        separator.tag = 105;
        UIColor *themeSeparator = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
        separator.backgroundColor = ApolloThemeRuntimeColor(ApolloThemeTokenSeparator)
            ?: [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [themeSeparator resolvedColorWithTraitCollection:traits]
                    : [UIColor colorWithWhite:0.8 alpha:1.0];
            }];
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:separator];
        [NSLayoutConstraint activateConstraints:@[
            [separator.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:18.0],
            [separator.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-state.separatorTrailingInset],
            [separator.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
            [separator.heightAnchor constraintEqualToConstant:1.0],
        ]];
    }
    self.itemViewsByKey = viewsByKey;
    self.itemSignaturesByKey = signaturesByKey;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:blockViews];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = kApolloSectionsPreviewBlockSpacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:kApolloSectionsPreviewTopPadding],
        // Reserve the same bottom breathing room in the model and layout.
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-kApolloSectionsPreviewBottomPadding],
    ]];
}

@end

#pragma mark - Preview content (the shared host's contentView)

// What the shared pinned host shows in its card: the current rendering, and
// the keyed transition between two renderings. The card's height is the spacer
// row's height, so a height change is the screen's job: layoutAlongside runs
// inside the same animation (and after an immediate swap) to spring the spacer
// row, and with it the card, to the new height.
@interface ApolloSubredditSectionsPreviewContentView : UIView
@property (nonatomic, copy) void (^layoutAlongside)(void);
+ (CGFloat)heightForCardWidth:(CGFloat)width;
- (void)apollo_refreshPreviewAnimated:(BOOL)animated;
- (void)apollo_finishPreviewTransition;
@end

@interface ApolloSubredditSectionsPreviewContentView ()
@property (nonatomic, strong) ApolloSubredditSectionsPreviewView *currentPreviewView;
@property (nonatomic, strong) UIViewPropertyAnimator *previewAnimator;
@property (nonatomic) NSUInteger previewTransitionGeneration;
@property (nonatomic) BOOL previewRefreshPending;
@property (nonatomic, strong) ApolloSubredditSectionsPreviewState *previewTransitionFromState;
@property (nonatomic, strong) ApolloSubredditSectionsPreviewState *previewTransitionToState;
@end

@implementation ApolloSubredditSectionsPreviewContentView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    // A growing rendering must not spill below the card mid-spring.
    self.clipsToBounds = YES;
    self.userInteractionEnabled = NO;
    return self;
}

// The rendering's height does not depend on the card width (fixed-height
// bands and rows), only on the current settings.
+ (CGFloat)heightForCardWidth:(__unused CGFloat)width {
    return ApolloSubredditSectionsCurrentPreviewState().previewHeight;
}

- (void)apollo_layoutAlongside {
    if (self.layoutAlongside) self.layoutAlongside();
}

- (ApolloSubredditSectionsPreviewView *)apollo_previewViewForState:(ApolloSubredditSectionsPreviewState *)state {
    ApolloSubredditSectionsPreviewView *preview = [[ApolloSubredditSectionsPreviewView alloc] initWithFrame:CGRectZero];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.previewState = state;
    [preview apollo_configurePreview];
    return preview;
}

- (void)apollo_addPreviewView:(ApolloSubredditSectionsPreviewView *)preview height:(CGFloat)height {
    [self addSubview:preview];
    [NSLayoutConstraint activateConstraints:@[
        [preview.topAnchor constraintEqualToAnchor:self.topAnchor],
        [preview.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [preview.heightAnchor constraintEqualToConstant:height]
    ]];
}

- (void)apollo_finishPreviewTransition {
    UIViewPropertyAnimator *animator = self.previewAnimator;
    if (!animator) return;
    [animator stopAnimation:NO];
    [animator finishAnimationAtPosition:UIViewAnimatingPositionEnd];
}

- (void)apollo_replacePreviewImmediately:(ApolloSubredditSectionsPreviewView *)preview
                                   state:(ApolloSubredditSectionsPreviewState *)state {
    [self apollo_finishPreviewTransition];
    for (UIView *subview in self.subviews) [subview removeFromSuperview];
    [self apollo_addPreviewView:preview height:state.previewHeight];
    preview.alpha = 1.0;
    self.currentPreviewView = preview;
    [UIView performWithoutAnimation:^{
        [self layoutIfNeeded];
        [self apollo_layoutAlongside];
    }];
}

// Re-render for the current settings. Animated: the new rendering is laid
// out on top of the old one and every block is matched by key — survivors
// slide from their old spot to their new one (a pixel-identical twin swaps in
// silently; a restyled one cross-fades on the way), newcomers scale-fade in,
// leavers scale-fade out — while the card's height (and the form below it)
// springs to the new size. A refresh landing mid-animation is queued and
// replayed once the animation completes.
- (void)apollo_refreshPreviewAnimated:(BOOL)animated {
    if (animated && self.previewAnimator.state == UIViewAnimatingStateActive) {
        ApolloSubredditSectionsPreviewState *requested = ApolloSubredditSectionsCurrentPreviewState();
        BOOL atSource = ApolloPreviewStatesEqual(requested, self.previewTransitionFromState);
        BOOL atTarget = ApolloPreviewStatesEqual(requested, self.previewTransitionToState);
        if (atSource || atTarget) {
            // Reverse the running timeline, preserving its current visual position.
            self.previewRefreshPending = NO;
            self.previewAnimator.reversed = atSource;
        } else {
            // Coalesce different controls/order changes into the latest state.
            self.previewRefreshPending = YES;
        }
        return;
    }
    [self apollo_finishPreviewTransition];

    ApolloSubredditSectionsPreviewState *state = ApolloSubredditSectionsCurrentPreviewState();
    ApolloSubredditSectionsPreviewView *incoming = [self apollo_previewViewForState:state];
    ApolloSubredditSectionsPreviewView *outgoing = self.currentPreviewView;
    if (!animated || UIAccessibilityIsReduceMotionEnabled() || !outgoing || !self.window) {
        [self apollo_replacePreviewImmediately:incoming state:state];
        return;
    }

    self.previewTransitionFromState = outgoing.previewState;
    self.previewTransitionToState = state;
    [self layoutIfNeeded];
    [self apollo_addPreviewView:incoming height:state.previewHeight];
    [self layoutIfNeeded];
    [incoming layoutIfNeeded];
    self.currentPreviewView = incoming;

    NSDictionary<NSString *, UIView *> *oldItems = outgoing.itemViewsByKey;
    NSDictionary<NSString *, UIView *> *newItems = incoming.itemViewsByKey;
    NSMutableArray<UIView *> *departingItems = [NSMutableArray array]; // gone: scale-fade out in place
    NSMutableArray<UIView *> *restyledItems = [NSMutableArray array];  // old look of a survivor: fade out in place
    NSMutableArray<UIView *> *slidingRows = [NSMutableArray array];
    NSMutableArray<void (^)(void)> *slideAnimations = [NSMutableArray array];
    NSMutableArray<UIView *> *slidingIncomingRows = [NSMutableArray array];
    for (NSString *key in newItems) {
        UIView *newItem = newItems[key];
        UIView *oldItem = oldItems[key];
        if (!oldItem) {
            newItem.alpha = 0.0;
            newItem.transform = CGAffineTransformMakeScale(0.88, 0.88);
            continue;
        }
        CGRect oldFrame = [oldItem convertRect:oldItem.bounds toView:self];
        CGRect newFrame = [newItem convertRect:newItem.bounds toView:self];
        newItem.transform = CGAffineTransformMakeTranslation(CGRectGetMidX(oldFrame) - CGRectGetMidX(newFrame),
                                                              CGRectGetMidY(oldFrame) - CGRectGetMidY(newFrame));
        BOOL sameLook = [outgoing.itemSignaturesByKey[key] isEqualToString:incoming.itemSignaturesByKey[key]];
        if (sameLook) {
            oldItem.alpha = 0.0; // the twin takes over from the very first frame
        } else if ([key hasPrefix:@"row."]) {
            // Animate each piece inside a resizing clip. This keeps names visible
            // while icons slide sideways and descriptions slide below the row.
            UIView *clip = [[UIView alloc] initWithFrame:oldFrame];
            clip.clipsToBounds = YES;
            [self addSubview:clip];
            [slidingRows addObject:clip];
            [slidingIncomingRows addObject:newItem];
            [slideAnimations addObject:^{ clip.frame = newFrame; }];
            for (NSInteger tag = 101; tag <= 105; tag++) {
                UIView *oldPart = [oldItem viewWithTag:tag];
                UIView *newPart = [newItem viewWithTag:tag];
                BOOL hadPart = oldPart && !oldPart.hidden;
                BOOL hasPart = newPart && !newPart.hidden;
                if (!hadPart && !hasPart) continue;
                UIView *source = hasPart ? newPart : oldPart;
                // These are plain labels/images. Render their layers directly:
                // snapshotViewAfterScreenUpdates:YES flushes the partially staged
                // preview to the screen, exposing duplicate/missing rows for a frame.
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                    initWithSize:source.bounds.size];
                UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [source.layer renderInContext:context.CGContext];
                }];
                UIView *snapshot = [[UIImageView alloc] initWithImage:image];
                CGRect start = hadPart ? [oldPart convertRect:oldPart.bounds toView:oldItem]
                                       : [newPart convertRect:newPart.bounds toView:newItem];
                CGRect end = hasPart ? [newPart convertRect:newPart.bounds toView:newItem] : start;
                if (!hadPart) {
                    if (tag == 101) start.origin.x = -CGRectGetWidth(start);
                    else start.origin.y = CGRectGetHeight(oldFrame);
                }
                if (!hasPart) {
                    if (tag == 101) end.origin.x = -CGRectGetWidth(end);
                    else end.origin.y = CGRectGetHeight(newFrame);
                }
                snapshot.frame = start;
                [clip addSubview:snapshot];
                [slideAnimations addObject:^{ snapshot.frame = end; }];
            }
            oldItem.alpha = 0.0;
            // Hidden arranged subviews collapse in UIStackView. Keep the real
            // row in layout while its clipped snapshot supplies the visuals.
            newItem.alpha = 0.0;
        } else {
            newItem.alpha = 0.0;
            [restyledItems addObject:oldItem];
        }
    }
    for (NSString *key in oldItems) {
        if (!newItems[key]) [departingItems addObject:oldItems[key]];
    }

    NSUInteger generation = ++self.previewTransitionGeneration;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.88];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.34
                                                                      timingParameters:timing];
    __weak typeof(self) weakSelf = self;
    __weak UIViewPropertyAnimator *weakAnimator = animator;
    [animator addAnimations:^{
        for (UIView *item in newItems.allValues) {
            if (![slidingIncomingRows containsObject:item]) item.alpha = 1.0;
            item.transform = CGAffineTransformIdentity;
        }
        for (UIView *item in departingItems) {
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.88, 0.88);
        }
        for (void (^slide)(void) in slideAnimations) slide();
        for (UIView *item in restyledItems) item.alpha = 0.0;
        [weakSelf apollo_layoutAlongside];
    }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
        for (UIView *row in slidingIncomingRows) row.alpha = 1.0;
        for (UIView *clip in slidingRows) [clip removeFromSuperview];
        if (finalPosition == UIViewAnimatingPositionStart) {
            [incoming removeFromSuperview];
            for (UIView *item in oldItems.allValues) {
                item.alpha = 1.0;
                item.transform = CGAffineTransformIdentity;
            }
            weakSelf.currentPreviewView = outgoing;
            [UIView performWithoutAnimation:^{
                [weakSelf layoutIfNeeded];
                [weakSelf apollo_layoutAlongside];
            }];
        } else {
            [outgoing removeFromSuperview];
            incoming.alpha = 1.0;
        }
        if (weakSelf.previewTransitionGeneration == generation &&
            weakSelf.previewAnimator == weakAnimator) {
            weakSelf.previewAnimator = nil;
        }
        if (weakSelf.previewRefreshPending) {
            weakSelf.previewRefreshPending = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf apollo_refreshPreviewAnimated:YES];
            });
        }
    }];
    self.previewAnimator = animator;
    [animator startAnimation];
}

@end

// Native reorder chrome is disabled: the redesign's snapshot gesture below
// owns the handle, row movement and card-shaped shadow.
@interface ApolloSectionOrderCell : UITableViewCell
@end
@implementation ApolloSectionOrderCell
- (void)setShowsReorderControl:(BOOL)showsReorderControl {
    [super setShowsReorderControl:NO];
}
@end

#pragma mark - The screen

@interface ApolloSubredditSectionsViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) ApolloPinnedPreviewHost *previewHost;
// Card width the spacer row was last measured for (0 = only the table's own
// section inset was available), from the shared layout pass.
@property (nonatomic) CGFloat previewCardWidth;
@property (nonatomic, strong) UILongPressGestureRecognizer *accountReorderGesture;
@property (nonatomic, strong, nullable) UIView *accountReorderWrapper;
@property (nonatomic, strong, nullable) UIView *accountReorderBackground;
@property (nonatomic, strong, nullable) UIView *accountReorderSnapshot;
@property (nonatomic, weak, nullable) UITableViewCell *accountReorderCell;
@property (nonatomic, strong, nullable) NSArray<NSString *> *rowsBeforeAccountReorder;
@property (nonatomic) NSInteger accountReorderOriginalRow;
@property (nonatomic) NSInteger accountReorderCurrentRow;
@property (nonatomic) CGFloat accountReorderTouchOffsetY;
@property (nonatomic) CGRect accountReorderCardFrame;
@property (nonatomic) CGFloat accountReorderCornerRadius;
@property (nonatomic) CGPoint accountReorderLatestPoint;
@property (nonatomic) NSInteger accountReorderDirection;
@property (nonatomic) BOOL accountReorderActive;
@property (nonatomic) BOOL accountReorderLanding;
@property (nonatomic, strong) NSTimer *accountReorderScrollTimer;
@property (nonatomic) BOOL accountReorderTransitioning;
@property (nonatomic) BOOL accountReorderFinishPending;
@property (nonatomic) BOOL accountReorderFinishCancelled;
@property (nonatomic, strong, nullable) UISelectionFeedbackGenerator *accountReorderFeedback;
@end

static BOOL ApolloSubredditSectionsPreviewPinnedPreference(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeySubredditSectionsPreviewPinned];
    return stored ? [stored boolValue] : YES;
}

@implementation ApolloSubredditSectionsViewController

- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    // The spacer row must stay invisible whatever the theme pass does to cells.
    if ([cell isKindOfClass:[ApolloPinnedPreviewSpacerCell class]]) {
        ApolloPinnedPreviewClearSpacerCell(cell);
        return;
    }
    [super apollo_applyThemeToCell:cell];
    if ([cell isKindOfClass:ApolloSectionOrderCell.class]) {
        cell.editingAccessoryView.tintColor = UIColor.tertiaryLabelColor;
    }
}

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyThemeToPreviewHost];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self finishAccountReorderCancelled:YES];
    [self.previewContentView apollo_finishPreviewTransition];
    [super viewWillDisappear:animated];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    BOOL appearanceChanged = !previousTraitCollection ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection];
    BOOL contentSizeChanged = !previousTraitCollection ||
        ![self.traitCollection.preferredContentSizeCategory
            isEqualToString:previousTraitCollection.preferredContentSizeCategory];
    if (!appearanceChanged && !contentSizeChanged) return;
    // The rendering resolves its theme colours when it is built.
    [self applyThemeToPreviewHost];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf.previewContentView apollo_refreshPreviewAnimated:NO];
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Subreddit List Sections";

    // The pinned preview: shared layout pass on the table (the subclass adds no
    // ivars, so isa-swizzling the existing table view is safe) + the host as a
    // direct subview of it, never a cell, so it survives every reload.
    if (![self.tableView isKindOfClass:[ApolloPinnedPreviewTableView class]]) {
        object_setClass(self.tableView, [ApolloPinnedPreviewTableView class]);
    }
    ApolloPinnedPreviewHost *host = [[ApolloPinnedPreviewHost alloc] initWithFrame:CGRectZero];
    ApolloSubredditSectionsPreviewContentView *content =
        [[ApolloSubredditSectionsPreviewContentView alloc] initWithFrame:CGRectZero];
    host.contentView = content;
    __weak typeof(self) weakSelf = self;
    content.layoutAlongside = ^{
        // Re-read the spacer row's height block (the card follows the row
        // rect on the table's next layout pass, inside the same animation).
        UITableView *table = weakSelf.tableView;
        if (!table.window) return;
        [table performBatchUpdates:nil completion:nil];
        [table layoutIfNeeded];
    };
    host.spacerIndexPath = ^NSIndexPath * {
        return [weakSelf indexPathForRowID:@"sections.preview"];
    };
    host.cardWidthDidChange = ^(CGFloat width) {
        [weakSelf previewCardWidthDidChange:width];
    };
    host.pinned = ApolloSubredditSectionsPreviewPinnedPreference();
    host.pinDidChange = ^(BOOL pinned) {
        [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:UDKeySubredditSectionsPreviewPinned];
        ApolloLog(@"[SubredditSections] preview %@", pinned ? @"pinned" : @"unpinned");
        // Slide the block into (or out of) its pinned spot instead of snapping:
        // the table's layout pass computes the new frames inside the animation.
        UITableView *table = weakSelf.tableView;
        [table setNeedsLayout];
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ [table layoutIfNeeded]; }
                         completion:nil];
    };
    self.previewHost = host;
    ApolloPinnedPreviewAttachHost(self.tableView, host);
    [self applyThemeToPreviewHost];

    // Match the account-switcher redesign’s snapshot reorder interaction.
    self.tableView.estimatedRowHeight = 0.0;
    self.tableView.estimatedSectionHeaderHeight = 0.0;
    self.tableView.estimatedSectionFooterHeight = 0.0;
    [self.tableView setEditing:YES animated:NO];
    self.accountReorderGesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleAccountReorderGesture:)];
    self.accountReorderGesture.minimumPressDuration = 0.16;
    self.accountReorderGesture.cancelsTouchesInView = YES;
    self.accountReorderGesture.delegate = self;
    [self.tableView addGestureRecognizer:self.accountReorderGesture];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    // --- Preview (the spacer row the pinned card sits on) ---
    // Escape hatch (custom row): a transparent placeholder — the pinned host
    // draws the card on top of (or, once scrolled, instead of) this slot. Its
    // height is the rendering's height for the current settings.
    ApolloSettingsRow *preview =
        [ApolloSettingsRow customRowWithID:@"sections.preview"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            ApolloPinnedPreviewSpacerCell *cell =
                [[ApolloPinnedPreviewSpacerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloPinnedPreviewClearSpacerCell(cell);
            cell.isAccessibilityElement = NO;
            return cell;
        }
                                  onSelect:nil];
    preview.height = ^CGFloat {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return 0.0;
        return [ApolloSubredditSectionsPreviewContentView
            heightForCardWidth:[strongSelf previewCardWidthForTable:strongSelf.tableView]];
    };
    ApolloSettingsSection *previewSection =
        [ApolloSettingsSection sectionWithTitle:@"Preview" footer:nil rows:@[ preview ]];

    // --- Options: every toggle the preview demonstrates, together ---
    ApolloSettingsRow *showIcons =
        [ApolloSettingsRow switchRowWithID:@"sections.showIcons" title:@"Show Subreddit Icons"
            isOn:^BOOL {
                id value = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyShowSubredditIconsInSubredditList];
                return value ? [value boolValue] : YES;
            } onToggle:^(UISwitch *sender) {
                [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyShowSubredditIconsInSubredditList];
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditListIconsChangedNotification object:nil];
                [weakSelf apollo_refreshPreviewAnimated:YES];
            }];
    ApolloSettingsRow *separateFollowing =
        [ApolloSettingsRow switchRowWithID:@"sections.separateFollowing"
                                     title:@"Separate Followed Users"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf separateFollowedUsersToggled:sender]; }];
    ApolloSettingsRow *hideMultiredditDescriptions =
        [ApolloSettingsRow switchRowWithID:@"sections.hideMultiredditDescriptions"
                                     title:@"Hide Multireddit Descriptions"
                                      isOn:^BOOL { return sHideMultiredditDescriptions; }
                                  onToggle:^(UISwitch *sender) { [weakSelf hideMultiredditDescriptionsToggled:sender]; }];
    ApolloSettingsRow *enhancements =
        [ApolloSettingsRow switchRowWithID:@"sections.enhancements"
                                     title:@"Subreddit List Enhancements"
                                      isOn:^BOOL { return sSubredditListEnhancements || ApolloDuoRequiresSubredditEnhancements(); }
                                  onToggle:^(UISwitch *sender) { [weakSelf listEnhancementsToggled:sender]; }];
    ApolloSettingsRow *modernDividers =
        [ApolloSettingsRow switchRowWithID:@"sections.modernDividers"
                                     title:@"Modern Subreddit Dividers"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyModernSubredditDividers]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf modernDividersToggled:sender]; }];
    enhancements.visible = ^BOOL { return !ApolloDuoRequiresSubredditEnhancements(); };
    modernDividers.visible = ^BOOL { return sSubredditListEnhancements || ApolloDuoRequiresSubredditEnhancements(); };
    ApolloSettingsSection *optionsSection =
        [ApolloSettingsSection sectionWithTitle:@"Options"
                                         footer:@"Subreddit List Enhancements make the alphabet index and favorite stars easier to tap, and improve spacing around icons and the index."
                                           rows:@[ showIcons, separateFollowing, hideMultiredditDescriptions, enhancements, modernDividers ]];

    // --- Section order (drag to reorder) ---
    NSMutableArray<ApolloSettingsRow *> *orderRows = [NSMutableArray arrayWithCapacity:4];
    NSArray<NSString *> *sectionOrder = sApolloSubredditSectionsPreviewDraftOrder
        ?: ApolloSubredditSectionsResolvedOrder();
    for (NSString *token in sectionOrder) {
        ApolloSettingsRow *row = [self orderRowForToken:token];
        if ([token isEqualToString:ApolloSubredditSectionTokenFollowing]) {
            row.visible = ^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers]; };
        }
        [orderRows addObject:row];
    }
    ApolloSettingsSection *orderSection =
        [ApolloSettingsSection sectionWithTitle:@"Section Order"
                                         footer:nil
                                           rows:orderRows];

    return @[ previewSection, optionsSection, orderSection ];
}

- (ApolloSettingsRow *)orderRowForToken:(NSString *)token {
    __weak typeof(self) weakSelf = self;
    NSString *rowID = [@"order." stringByAppendingString:token];
    ApolloSettingsRow *row =
        [ApolloSettingsRow customRowWithID:rowID
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *r) {
        static NSString *reuseID = @"Cell_SectionOrder";
        ApolloSectionOrderCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
        if (!cell) {
            cell = [[ApolloSectionOrderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        UIImageView *handle = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.horizontal.3"]];
        handle.tintColor = UIColor.tertiaryLabelColor;
        handle.contentMode = UIViewContentModeCenter;
        handle.frame = CGRectMake(0, 0, 28, 28);
        cell.accessoryView = handle;
        cell.showsReorderControl = NO;
        [weakSelf apollo_applyPrimaryTextColorToCell:cell];
        cell.textLabel.text = ApolloSubredditSectionDisplayName(token);
        return cell;
    }
                                  onSelect:nil];
    return row;
}

#pragma mark Pinned preview plumbing

- (ApolloSubredditSectionsPreviewContentView *)previewContentView {
    return (ApolloSubredditSectionsPreviewContentView *)self.previewHost.contentView;
}

- (void)apollo_refreshPreviewAnimated:(BOOL)animated {
    [self.previewContentView apollo_refreshPreviewAnimated:animated];
}

// Card chrome follows the same theme walk as before (the Subreddits list's own
// background, so the miniature reads as that list; section corner radius;
// table background for the stuck backdrop; accent for the pin glyph), and the
// rendering is rebuilt for the theme's ink.
- (void)applyThemeToPreviewHost {
    ApolloPinnedPreviewHost *host = self.previewHost;
    if (!host) return;
    host.card.backgroundColor = ApolloThemeSubredditListBackgroundColor()
        ?: [self apollo_themeCellBackgroundColor];
    host.card.layer.cornerRadius = ApolloPinnedPreviewSectionCornerRadius(self.tableView);
    UIColor *tableBackground = self.tableView.backgroundColor;
    UIColor *resolved = [tableBackground resolvedColorWithTraitCollection:self.tableView.traitCollection];
    if (!resolved || CGColorGetAlpha(resolved.CGColor) < 0.99) {
        tableBackground = [UIColor systemGroupedBackgroundColor];
    }
    host.backdropColor = tableBackground;
    host.accentColor = [self apollo_themeAccentColor];
    [self.previewContentView apollo_refreshPreviewAnimated:NO];
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    [self applyThemeToPreviewHost];
}

// Width the spacer row's height is derived from: the measured cell width once
// the layout pass has seen a real cell, else the table's reported section inset.
- (CGFloat)previewCardWidthForTable:(UITableView *)tableView {
    if (self.previewCardWidth > 0) return self.previewCardWidth;
    UIEdgeInsets inset = ApolloPinnedPreviewSectionContentInset(tableView);
    CGFloat width = CGRectGetWidth(tableView.bounds) - inset.left - inset.right;
    if (width <= 0.0) width = CGRectGetWidth(UIScreen.mainScreen.bounds) - inset.left - inset.right;
    return MAX(0.0, width);
}

- (void)previewCardWidthDidChange:(CGFloat)width {
    if (width <= 0 || fabs(width - self.previewCardWidth) <= 0.5) return;
    CGFloat oldHeight = [ApolloSubredditSectionsPreviewContentView
        heightForCardWidth:[self previewCardWidthForTable:self.tableView]];
    self.previewCardWidth = width;
    CGFloat newHeight = [ApolloSubredditSectionsPreviewContentView heightForCardWidth:width];
    ApolloLog(@"[SubredditSections] card width %.1f → spacer row %.1f → %.1f", width, oldHeight, newHeight);
    if (fabs(newHeight - oldHeight) <= 0.5) return;
    [UIView performWithoutAnimation:^{
        [self reloadRowWithID:@"sections.preview"];
    }];
}

// Non-scrolling view the lifted order row floats in while it is dragged (it
// must not ride the table's content offset while the edge auto-scroll runs).
- (UIView *)apollo_reorderOverlayView {
    return self.navigationController.view ?: self.view;
}

#pragma mark Toggles

- (void)separateFollowedUsersToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySeparateFollowedUsers];
    [self visibilityDidChange]; // the Following order row appears/disappears
    [self apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditSectionsChangedNotification object:nil];
}

- (void)hideMultiredditDescriptionsToggled:(UISwitch *)sender {
    sHideMultiredditDescriptions = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sHideMultiredditDescriptions forKey:UDKeyHideMultiredditDescriptions];
    [self apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloHideMultiredditDescriptionsChangedNotification object:nil];
}

- (void)listEnhancementsToggled:(UISwitch *)sender {
    BOOL wasOn = sSubredditListEnhancements;
    sSubredditListEnhancements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sSubredditListEnhancements forKey:UDKeySubredditListEnhancements];
    if (sSubredditListEnhancements != wasOn) [self visibilityDidChange]; // the Modern Dividers row
    [self apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

- (void)modernDividersToggled:(UISwitch *)sender {
    sModernSubredditDividers = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sModernSubredditDividers forKey:UDKeyModernSubredditDividers];
    [self apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

#pragma mark Section-order reordering (drag & drop)

// The order rows' section index, derived by identity (never hardcoded).
- (NSInteger)orderSectionIndex {
    NSIndexPath *anyOrderRow = [self indexPathForRowID:[@"order." stringByAppendingString:ApolloSubredditSectionTokenFavorites]];
    return anyOrderRow ? anyOrderRow.section : NSNotFound;
}

- (BOOL)indexPathIsOrderRow:(NSIndexPath *)indexPath {
    return indexPath && indexPath.section == [self orderSectionIndex];
}

// The visible order rows, top to bottom, as tokens.
- (NSArray<NSString *> *)visibleOrderTokens {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    BOOL separate = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers];
    NSArray<NSString *> *sectionOrder = sApolloSubredditSectionsPreviewDraftOrder
        ?: ApolloSubredditSectionsResolvedOrder();
    for (NSString *token in sectionOrder) {
        if (!separate && [token isEqualToString:ApolloSubredditSectionTokenFollowing]) continue;
        [tokens addObject:token];
    }
    return tokens;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
    if (![self indexPathIsOrderRow:fromIndexPath] || ![self indexPathIsOrderRow:toIndexPath]) return;

    NSMutableArray<NSString *> *visible = [[self visibleOrderTokens] mutableCopy];
    if (fromIndexPath.row < 0 || fromIndexPath.row >= (NSInteger)visible.count ||
        toIndexPath.row < 0 || toIndexPath.row >= (NSInteger)visible.count) return;
    NSString *moved = visible[(NSUInteger)fromIndexPath.row];
    [visible removeObjectAtIndex:(NSUInteger)fromIndexPath.row];
    [visible insertObject:moved atIndex:(NSUInteger)toIndexPath.row];

    // Splice any hidden token (Following while separation is off) back into
    // the stored order at its old relative position (kept at the end).
    NSMutableArray<NSString *> *stored = [visible mutableCopy];
    NSArray<NSString *> *previousOrder = sApolloSubredditSectionsPreviewDraftOrder
        ?: ApolloSubredditSectionsResolvedOrder();
    for (NSString *token in previousOrder) {
        if (![stored containsObject:token]) [stored addObject:token];
    }
    sApolloSubredditSectionsPreviewDraftOrder = [stored copy];
    // Keep the declarative snapshot in step with UIKit without rebuilding the
    // entire form for every row the drag crosses. The draft is committed only
    // after a successful drop.
    [self noteRowMovedFromIndexPath:fromIndexPath toIndexPath:toIndexPath];

    // Keep the preview synchronized with each animated position change.
    [self apollo_refreshPreviewAnimated:YES];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.accountReorderGesture || !self.tableView.isEditing ||
        self.accountReorderActive || self.accountReorderLanding) return NO;
    CGPoint point = [gestureRecognizer locationInView:self.tableView];
    // A stuck card covers the rows scrolled beneath it: a press on the card
    // is the card's, never a lift of the order row hidden under it.
    ApolloPinnedPreviewHost *previewHost = self.previewHost;
    if (previewHost && !previewHost.hidden && previewHost.superview == self.tableView &&
        CGRectContainsPoint(previewHost.frame, point)) return NO;
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    UITableViewCell *cell = indexPath ? [self.tableView cellForRowAtIndexPath:indexPath] : nil;
    if (!cell || ![self indexPathIsOrderRow:indexPath]) return NO;
    CGPoint cellPoint = [gestureRecognizer locationInView:cell];
    BOOL rightToLeft = cell.effectiveUserInterfaceLayoutDirection ==
        UIUserInterfaceLayoutDirectionRightToLeft;
    return rightToLeft ? cellPoint.x <= 52.0
                       : cellPoint.x >= CGRectGetWidth(cell.bounds) - 52.0;
}

- (void)updateAccountReorderSnapshotCorners {
    UIView *wrapper = self.accountReorderWrapper;
    UIView *background = self.accountReorderBackground;
    UIView *snapshot = self.accountReorderSnapshot;
    if (!wrapper || !background || !snapshot) return;
    NSInteger row = self.accountReorderCurrentRow;
    NSInteger last = (NSInteger)[self visibleOrderTokens].count - 1;
    UIRectCorner corners = 0;
    if (row == 0) {
        corners |= UIRectCornerTopLeft | UIRectCornerTopRight;
    }
    if (row == last) {
        corners |= UIRectCornerBottomLeft | UIRectCornerBottomRight;
    }

    CGRect cardFrame = self.accountReorderCardFrame;
    CGFloat radius = self.accountReorderCornerRadius;
    UIBezierPath *cardPath = corners
        ? [UIBezierPath bezierPathWithRoundedRect:cardFrame
                                byRoundingCorners:corners
                                      cornerRadii:CGSizeMake(radius, radius)]
        : [UIBezierPath bezierPathWithRect:cardFrame];
    CAShapeLayer *snapshotMask = [CAShapeLayer layer];
    snapshotMask.frame = snapshot.bounds;
    snapshotMask.path = cardPath.CGPath;

    CGRect localBackgroundBounds = background.bounds;
    UIBezierPath *backgroundPath = corners
        ? [UIBezierPath bezierPathWithRoundedRect:localBackgroundBounds
                                byRoundingCorners:corners
                                      cornerRadii:CGSizeMake(radius, radius)]
        : [UIBezierPath bezierPathWithRect:localBackgroundBounds];
    CAShapeLayer *backgroundMask = [CAShapeLayer layer];
    backgroundMask.frame = localBackgroundBounds;
    backgroundMask.path = backgroundPath.CGPath;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    snapshot.layer.mask = snapshotMask;
    background.layer.mask = backgroundMask;
    wrapper.layer.shadowPath = cardPath.CGPath;
    [CATransaction commit];
}

// Scroll the actual visible list viewport, excluding the pinned preview and
// navigation/tab bars. The lifted row stays attached to the finger in the host.
- (void)scrollAccountReorderAtEdge {
    if (!self.accountReorderActive || self.accountReorderFinishPending) return;
    UIView *host = [self apollo_reorderOverlayView];
    UITableView *table = self.tableView;
    // The table runs under the bars; its own safe area is the visible list.
    CGRect viewport = [table convertRect:UIEdgeInsetsInsetRect(table.bounds, table.safeAreaInsets)
                                  toView:host];
    CGFloat top = CGRectGetMinY(viewport);
    CGFloat bottom = CGRectGetMaxY(viewport);
    ApolloPinnedPreviewHost *previewHost = self.previewHost;
    if (previewHost.stuck && !previewHost.hidden) {
        CGRect preview = [previewHost convertRect:previewHost.bounds toView:host];
        top = MAX(top, CGRectGetMaxY(preview));
    }
    CGFloat edge = MIN(48.0, MAX(0.0, (bottom - top) / 3.0));
    if (edge <= 0.0) return;
    CGFloat y = self.accountReorderLatestPoint.y;
    CGFloat strength = y < top + edge ? -MIN(1.0, (top + edge - y) / edge)
        : y > bottom - edge ? MIN(1.0, (y - bottom + edge) / edge) : 0.0;
    CGFloat minimum = -table.adjustedContentInset.top;
    CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height
                                   + table.adjustedContentInset.bottom);
    CGFloat offset = MAX(minimum, MIN(maximum, table.contentOffset.y + strength * 4.0));
    if (fabs(offset - table.contentOffset.y) < 0.01) return;
    self.accountReorderDirection = offset > table.contentOffset.y ? 1 : -1;
    [table setContentOffset:CGPointMake(table.contentOffset.x, offset) animated:NO];
    [self evaluateAccountReorderDestination];
}

- (void)finishAccountReorderCancelled:(BOOL)cancelled {
    [self.accountReorderScrollTimer invalidate];
    self.accountReorderScrollTimer = nil;
    if (!self.accountReorderActive) return;
    if (self.accountReorderTransitioning) {
        self.accountReorderFinishPending = YES;
        self.accountReorderFinishCancelled = cancelled;
        return;
    }

    NSInteger destination = self.accountReorderCurrentRow;
    if (cancelled) {
        sApolloSubredditSectionsPreviewDraftOrder = nil;
        [self rebuildForm];
        [self apollo_refreshPreviewAnimated:YES];
        destination = self.accountReorderOriginalRow;
        self.accountReorderCurrentRow = destination;
        [self updateAccountReorderSnapshotCorners];
    } else {
        NSArray<NSString *> *committedOrder = sApolloSubredditSectionsPreviewDraftOrder
            ?: self.rowsBeforeAccountReorder;
        sApolloSubredditSectionsPreviewDraftOrder = nil;
        if (committedOrder && ![committedOrder isEqualToArray:self.rowsBeforeAccountReorder]) {
            [[NSUserDefaults standardUserDefaults] setObject:committedOrder
                                                     forKey:UDKeySubredditSectionOrder];
            ApolloLog(@"[SubredditSections] order -> %@",
                      [committedOrder componentsJoinedByString:@", "]);
            [[NSNotificationCenter defaultCenter]
                postNotificationName:ApolloSubredditSectionsChangedNotification object:nil];
        }
    }

    NSIndexPath *destinationPath = [NSIndexPath indexPathForRow:destination inSection:[self orderSectionIndex]];
    [self.tableView layoutIfNeeded];
    UITableViewCell *landingCell = [self.tableView cellForRowAtIndexPath:destinationPath];
    CGRect tableFrame = landingCell ? [landingCell convertRect:landingCell.bounds toView:self.tableView]
        : [self.tableView rectForRowAtIndexPath:destinationPath];
    CGRect destinationFrame = [self.tableView convertRect:tableFrame toView:[self apollo_reorderOverlayView]];
    UIView *wrapper = self.accountReorderWrapper;
    UITableViewCell *destinationCell = [self.tableView cellForRowAtIndexPath:destinationPath];
    UITableViewCell *draggedCell = self.accountReorderCell;
    destinationCell.hidden = YES;
    self.accountReorderLanding = YES;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.18
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        wrapper.transform = CGAffineTransformIdentity;
        wrapper.frame = destinationFrame;
    } completion:^(__unused BOOL finished) {
        destinationCell.hidden = NO;
        draggedCell.hidden = NO;
        [wrapper removeFromSuperview];
        self.accountReorderLanding = NO;
    }];

    self.accountReorderWrapper = nil;
    self.accountReorderBackground = nil;
    self.accountReorderSnapshot = nil;
    self.accountReorderCell = nil;
    self.rowsBeforeAccountReorder = nil;
    self.accountReorderFeedback = nil;
    self.accountReorderActive = NO;
    self.accountReorderFinishPending = NO;
}

- (void)evaluateAccountReorderDestination {
    if (!self.accountReorderActive || self.accountReorderTransitioning) return;
    UIView *wrapper = self.accountReorderWrapper;
    CGRect dragFrame = [[self apollo_reorderOverlayView] convertRect:wrapper.frame toView:self.tableView];
    NSInteger current = self.accountReorderCurrentRow;
    NSInteger destination = current;
    NSInteger last = (NSInteger)[self visibleOrderTokens].count - 1;

    // Resolve the furthest crossed row in one pass. The previous version
    // queued one table animation per row, so a quick two-row movement visibly
    // lagged behind the floating cell while waiting for the first completion.
    for (NSInteger row = current + 1; self.accountReorderDirection > 0 && row <= last; row++) {
        CGRect candidate = [self.tableView rectForRowAtIndexPath:
            [NSIndexPath indexPathForRow:row inSection:[self orderSectionIndex]]];
        CGFloat boundary = CGRectGetMinY(candidate) + CGRectGetHeight(candidate) * 0.30;
        if (CGRectGetMaxY(dragFrame) < boundary) break;
        destination = row;
    }
    if (destination == current && self.accountReorderDirection < 0) {
        for (NSInteger row = current - 1; row >= 0; row--) {
            CGRect candidate = [self.tableView rectForRowAtIndexPath:
                [NSIndexPath indexPathForRow:row inSection:[self orderSectionIndex]]];
            CGFloat boundary = CGRectGetMaxY(candidate) - CGRectGetHeight(candidate) * 0.30;
            if (CGRectGetMinY(dragFrame) > boundary) break;
            destination = row;
        }
    }
    if (destination == current) return;

    [self tableView:self.tableView
        moveRowAtIndexPath:[NSIndexPath indexPathForRow:current inSection:[self orderSectionIndex]]
               toIndexPath:[NSIndexPath indexPathForRow:destination inSection:[self orderSectionIndex]]];
    self.accountReorderCurrentRow = destination;
    [self updateAccountReorderSnapshotCorners];
    self.accountReorderTransitioning = YES;
    [self.accountReorderFeedback selectionChanged];
    [self.accountReorderFeedback prepare];

    NSIndexPath *from = [NSIndexPath indexPathForRow:current inSection:[self orderSectionIndex]];
    NSIndexPath *to = [NSIndexPath indexPathForRow:destination inSection:[self orderSectionIndex]];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.25
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseOut
                     animations:^{
        [self.tableView performBatchUpdates:^{
            [self.tableView moveRowAtIndexPath:from toIndexPath:to];
        } completion:nil];
    } completion:^(__unused BOOL finished) {
        self.accountReorderTransitioning = NO;
        if (self.accountReorderFinishPending) {
            [self finishAccountReorderCancelled:self.accountReorderFinishCancelled];
        } else {
            [self evaluateAccountReorderDestination];
        }
    }];
}

- (void)handleAccountReorderGesture:(UILongPressGestureRecognizer *)gestureRecognizer {
    CGPoint tablePoint = [gestureRecognizer locationInView:self.tableView];
    switch (gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan: {
            NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:tablePoint];
            UITableViewCell *cell = indexPath ? [self.tableView cellForRowAtIndexPath:indexPath] : nil;
            if (!cell) return;
            UIView *snapshot = [cell snapshotViewAfterScreenUpdates:NO];
            if (!snapshot) return;

            CGRect frame = [cell convertRect:cell.bounds toView:[self apollo_reorderOverlayView]];
            UIView *wrapper = [[UIView alloc] initWithFrame:frame];
            wrapper.backgroundColor = UIColor.clearColor;
            wrapper.layer.shadowColor = UIColor.blackColor.CGColor;
            wrapper.layer.shadowOpacity = 0.18;
            wrapper.layer.shadowRadius = 8.0;
            wrapper.layer.shadowOffset = CGSizeMake(0.0, 3.0);
            UIView *cellBackground = cell.backgroundView;
            CGRect cardFrame = cellBackground
                ? [cellBackground convertRect:cellBackground.bounds toView:cell]
                : cell.bounds;
            if (CGRectIsEmpty(cardFrame) || !CGRectContainsRect(cell.bounds, cardFrame)) {
                cardFrame = cell.bounds;
            }
            CGFloat cornerRadius = cellBackground.layer.cornerRadius;
            if (cornerRadius <= 0.0) {
                NSIndexPath *edgePath = [NSIndexPath indexPathForRow:0 inSection:[self orderSectionIndex]];
                UITableViewCell *edgeCell = [self.tableView cellForRowAtIndexPath:edgePath];
                cornerRadius = edgeCell.backgroundView.layer.cornerRadius;
            }
            if (cornerRadius <= 0.0) cornerRadius = 20.0;

            // A snapshot preserves the source row's transparent rounded
            // pixels. Fill beneath it so a top/bottom source can become a
            // square middle row, then mask both layers to the destination's
            // actual inset-grouped card geometry.
            // Capture a tiny blank patch from the row's rendered card and
            // stretch it beneath the snapshot. On device, Apollo can render
            // the card through private UIKit layers whose reported
            // backgroundColor differs from the pixels on screen; sampling the
            // rendered surface keeps this temporary morph fill exact in every
            // stock/custom theme.
            CGRect sampleRect = CGRectMake(CGRectGetMaxX(cardFrame) - 8.0,
                                           CGRectGetMidY(cardFrame) - 1.0,
                                           2.0, 2.0);
            UIView *background = [cell resizableSnapshotViewFromRect:sampleRect
                                                   afterScreenUpdates:NO
                                                        withCapInsets:UIEdgeInsetsZero];
            if (!background) {
                background = [[UIView alloc] initWithFrame:cardFrame];
                background.backgroundColor = ApolloThemeCardBackgroundColor()
                    ?: cellBackground.backgroundColor
                    ?: UIColor.secondarySystemGroupedBackgroundColor;
            }
            background.frame = cardFrame;
            [wrapper addSubview:background];
            snapshot.frame = wrapper.bounds;
            snapshot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [wrapper addSubview:snapshot];
            [[self apollo_reorderOverlayView] addSubview:wrapper];

            CGPoint viewPoint = [gestureRecognizer locationInView:[self apollo_reorderOverlayView]];
            self.accountReorderWrapper = wrapper;
            self.accountReorderBackground = background;
            self.accountReorderSnapshot = snapshot;
            self.accountReorderCell = cell;
            self.rowsBeforeAccountReorder = ApolloSubredditSectionsResolvedOrder();
            sApolloSubredditSectionsPreviewDraftOrder = self.rowsBeforeAccountReorder;
            self.accountReorderOriginalRow = indexPath.row;
            self.accountReorderCurrentRow = indexPath.row;
            self.accountReorderTouchOffsetY = CGRectGetMidY(frame) - viewPoint.y;
            self.accountReorderCardFrame = cardFrame;
            self.accountReorderCornerRadius = cornerRadius;
            self.accountReorderLatestPoint = viewPoint;
            self.accountReorderDirection = 0;
            self.accountReorderActive = YES;
            self.accountReorderFeedback = [UISelectionFeedbackGenerator new];
            [self.accountReorderFeedback prepare];
            [self.accountReorderFeedback selectionChanged];
            __weak typeof(self) weakSelf = self;
            self.accountReorderScrollTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES
                block:^(__unused NSTimer *timer) { [weakSelf scrollAccountReorderAtEdge]; }];
            [[NSRunLoop mainRunLoop] addTimer:self.accountReorderScrollTimer forMode:NSRunLoopCommonModes];
            cell.hidden = YES;
            [self updateAccountReorderSnapshotCorners];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.accountReorderActive) return;
            CGPoint viewPoint = [gestureRecognizer locationInView:[self apollo_reorderOverlayView]];
            CGFloat delta = viewPoint.y - self.accountReorderLatestPoint.y;
            if (fabs(delta) > 0.1) self.accountReorderDirection = delta > 0 ? 1 : -1;
            self.accountReorderLatestPoint = viewPoint;
            CGPoint center = self.accountReorderWrapper.center;
            center.y = viewPoint.y + self.accountReorderTouchOffsetY;
            self.accountReorderWrapper.center = center;
            [self evaluateAccountReorderDestination];
            break;
        }
        case UIGestureRecognizerStateEnded:
            [self finishAccountReorderCancelled:NO];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self finishAccountReorderCancelled:YES];
            break;
        default:
            break;
    }
}


- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self indexPathIsOrderRow:indexPath];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    // The declarative form owns the cells. Keep its switches visible while
    // the table exposes native reorder handles only for the order rows.
    cell.editingAccessoryView = cell.accessoryView;
    cell.hidden = self.accountReorderActive && [self indexPathIsOrderRow:indexPath]
        && indexPath.row == self.accountReorderCurrentRow;
    return cell;
}

@end
