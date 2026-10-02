#import "settings/ApolloActionMenuSettingsViewController.h"

#import "ApolloActionMenuLayout.h"
#import "ApolloCommon.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloSettingsForm.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsPinnedPreview.h"

#import <objc/runtime.h>

// The live preview is hosted by the shared pinned-preview machinery
// (ApolloSettingsPinnedPreview.h): the "Preview" section holds one transparent
// spacer row and the card itself is a direct subview of the table that sits on
// that row at rest and locks under the nav bar — with a copy of the section
// title — once the row would scroll away, so the item list is rearranged with
// the menu in view. Tap the card to pin/unpin it (remembered per screen).
//
// The preview is a miniature of the selected ••• menu as the saved layout
// leaves it: the visible items in order, drawn the way this device draws the
// menu (a Liquid Glass UIMenu, or Apollo's accent-tinted sheet before it),
// capped at a handful of rows with a "+N more" line. Every row carries a KEY
// (its item) and a SIGNATURE (its look): on a refresh a row that survived
// slides from its old place to its new one, a hidden row scale-fades out, a
// re-shown one scale-fades in, and the spacer row (hence the card) springs to
// the new height alongside.

#pragma mark - Preview model

NSString *const ApolloActionMenuEditorAllMenus = @"all";

static NSString *const kApolloAMPreviewKeyCaption = @"caption";
static NSString *const kApolloAMPreviewKeyPanel = @"panel";
static NSString *const kApolloAMPreviewKeyMore = @"more";
static NSString *const kApolloAMPreviewRowKeyPrefix = @"row.";

static const CGFloat kApolloAMPreviewTopPadding = 10.0;      // centres the caption on the pin glyph
static const CGFloat kApolloAMPreviewBottomPadding = 12.0;
static const CGFloat kApolloAMPreviewSidePadding = 14.0;
static const CGFloat kApolloAMPreviewCaptionHeight = 14.0;
static const CGFloat kApolloAMPreviewCaptionSpacing = 10.0;
static const CGFloat kApolloAMPreviewPanelPadding = 5.0;
static const CGFloat kApolloAMPreviewRowHeight = 30.0;
static const CGFloat kApolloAMPreviewPanelMaxWidth = 250.0;
static const CGFloat kApolloAMPreviewMoreHeight = 18.0;
static const NSUInteger kApolloAMPreviewMaxRows = 8;

@interface ApolloAMPreviewState : NSObject
@property (nonatomic, copy) ApolloActionMenuContext context;
@property (nonatomic, copy) NSArray<ApolloActionMenuItem *> *visibleItems;   // saved order, hidden removed
@property (nonatomic) BOOL glass;
@property (nonatomic) CGFloat previewHeight;
@end

#pragma mark - Action Menu hub

static NSString *ApolloAMMenuSummary(NSString *context) {
    if ([context isEqualToString:ApolloActionMenuEditorAllMenus]) {
        NSMutableSet<NSString *> *hiddenActions = [NSMutableSet set];
        for (NSString *menuContext in ApolloActionMenuAllContexts()) {
            [hiddenActions unionSet:ApolloActionMenuHiddenItemIDs(menuContext)];
        }
        NSUInteger hidden = hiddenActions.count;
        if (hidden == 0) return nil;
        return [NSString stringWithFormat:@"%lu action%@ hidden",
                (unsigned long)hidden, hidden == 1 ? @"" : @"s"];
    }

    BOOL order = ApolloActionMenuHasCustomOrder(context);
    NSUInteger hidden = ApolloActionMenuHiddenItemIDs(context).count;
    if (!order && hidden == 0) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (order) [parts addObject:@"Custom order"];
    if (hidden > 0) {
        [parts addObject:[NSString stringWithFormat:@"%lu action%@ hidden",
                          (unsigned long)hidden, hidden == 1 ? @"" : @"s"]];
    }
    return [parts componentsJoinedByString:@" · "];
}

@implementation ApolloActionMenuSettingsViewController {
    BOOL _appeared;
    NSMutableDictionary<NSString *, NSNumber *> *_menuRowHeights;
    UITableViewCell *_measuringMenuCell;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Customize Action Menus";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_appeared) [self refreshSummaries];
    _appeared = YES;
}

- (void)refreshSummaries {
    NSArray<NSString *> *contexts = [@[ ApolloActionMenuEditorAllMenus ]
        arrayByAddingObjectsFromArray:ApolloActionMenuAllContexts()];
    for (NSString *context in contexts) {
        UITableViewCell *cell = [self cellForRowID:[@"menu." stringByAppendingString:context]];
        if (cell) cell.detailTextLabel.text = ApolloAMMenuSummary(context);
    }
    [UIView performWithoutAnimation:^{
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
        [self.tableView layoutIfNeeded];
    }];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    [super tableView:tableView willDisplayHeaderView:view forSection:section];
    if (![view isKindOfClass:UITableViewHeaderFooterView.class] || (section != 1 && section != 2)) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    UILabel *label = header.textLabel;
    NSString *imageName = section == 1 ? @"option-more" : @"option-moderator";
    NSString *title = section == 1 ? @"Menus" : @"Moderator Menus";
    if (@available(iOS 18.0, *)) {} else title = title.uppercaseString;
    UIImage *image = [[UIImage imageNamed:imageName inBundle:NSBundle.mainBundle
            compatibleWithTraitCollection:view.traitCollection]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!image || !label) return;
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    CGFloat iconWidth = label.font.capHeight * 1.8;
    attachment.bounds = CGRectMake(0.0, section == 1 ? 2.0 : -2.5,
                                   iconWidth, iconWidth / (image.size.width / image.size.height));
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:title]]];
    label.attributedText = text;
    NSString *accessibilityTitle = section == 1 ? @"Action Menus" : @"Moderator Action Menus";
    label.accessibilityLabel = accessibilityTitle;
    header.isAccessibilityElement = YES;
    header.accessibilityLabel = accessibilityTitle;
}

- (CGFloat)menuRowHeightWithSubtitle:(BOOL)subtitle {
    UITableView *table = self.tableView;
    CGFloat width = CGRectGetWidth(table.bounds);
    if (width <= 0.0) return UITableViewAutomaticDimension;
    NSString *key = [NSString stringWithFormat:@"%d|%.0f|%@", subtitle, width,
                     table.traitCollection.preferredContentSizeCategory ?: @""];
    NSNumber *cached = _menuRowHeights[key];
    if (cached) return cached.doubleValue;
    if (!_measuringMenuCell) {
        _measuringMenuCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    }
    UITableViewCell *cell = _measuringMenuCell;
    cell.textLabel.text = @"Post";
    cell.detailTextLabel.text = subtitle ? @"Custom order · 2 actions hidden" : nil;
    cell.bounds = CGRectMake(0.0, 0.0, width, 100.0);
    ApolloSettingsApplyCellTypography(cell);
    [cell setNeedsLayout];
    [cell layoutIfNeeded];
    CGFloat height = ceil([cell systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                  withHorizontalFittingPriority:UILayoutPriorityRequired
                                        verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    if (height <= 0.0) return UITableViewAutomaticDimension;
    if (!_menuRowHeights) _menuRowHeights = [NSMutableDictionary dictionary];
    _menuRowHeights[key] = @(height);
    return height;
}

- (ApolloSettingsRow *)menuRowForContext:(NSString *)context title:(NSString *)title {
    ApolloSettingsRow *row =
        [ApolloSettingsRow disclosureRowWithID:[@"menu." stringByAppendingString:context]
                                         title:title
                                        detail:^NSString * { return ApolloAMMenuSummary(context); }
                                          push:^UIViewController * {
            return [[ApolloActionMenuEditorViewController alloc] initWithContext:context];
        }];
    row.detailAsSubtitle = YES;
    __weak __typeof(self) weakSelf = self;
    row.height = ^CGFloat {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return UITableViewAutomaticDimension;
        return [strongSelf menuRowHeightWithSubtitle:ApolloAMMenuSummary(context).length > 0];
    };
    return row;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    NSMutableArray<ApolloSettingsRow *> *regular = [NSMutableArray array];
    NSMutableArray<ApolloSettingsRow *> *moderator = [NSMutableArray array];
    for (ApolloActionMenuContext context in ApolloActionMenuAllContexts()) {
        BOOL mod = ApolloActionMenuContextIsModerator(context);
        [(mod ? moderator : regular) addObject:[self menuRowForContext:context
                                                                 title:ApolloActionMenuContextTitle(context)]];
    }
    ApolloSettingsRow *all = [self menuRowForContext:ApolloActionMenuEditorAllMenus title:@"All Menus"];
    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Show or hide actions across every menu at once."
                                           rows:@[ all ]],
        [ApolloSettingsSection sectionWithTitle:@"Menus"
                                         footer:nil
                                           rows:regular],
        [ApolloSettingsSection sectionWithTitle:@"Moderator Menus"
                                         footer:@"Shown in subreddits you moderate."
                                           rows:moderator],
    ];
}

@end

@implementation ApolloAMPreviewState
@end

static ApolloAMPreviewState *ApolloAMCurrentPreviewState(ApolloActionMenuContext context) {
    ApolloAMPreviewState *state = [ApolloAMPreviewState new];
    state.context = context;
    NSArray<ApolloActionMenuItem *> *visibleItems = ApolloActionMenuPreviewItems(context);
    if (!ApolloNativeActionMenusActive()) {
        NSMutableArray<ApolloActionMenuItem *> *nativeItems = [NSMutableArray array];
        NSMutableArray<ApolloActionMenuItem *> *tweakItems = [NSMutableArray array];
        for (ApolloActionMenuItem *item in visibleItems) {
            [(item.isTweakRow ? tweakItems : nativeItems) addObject:item];
        }
        visibleItems = [nativeItems arrayByAddingObjectsFromArray:tweakItems];
    }
    state.visibleItems = visibleItems;
    state.glass = IsLiquidGlass();
    return state;
}

// The feed's locked Submit Post row is drawn as the quick new-post buttons
// (Photo/Link/Text/Poll) on Liquid Glass while the Polls feature is on —
// ApolloSubmitPostTypesMenu swaps the plain row for them — and the mock
// follows suit, so the preview matches what that menu actually shows.
static BOOL ApolloAMItemDrawsAsPalette(ApolloActionMenuItem *item, BOOL glass) {
    return glass && item.locked && [item.kinds containsObject:@51] && ApolloPollsFeatureEnabled();
}

#pragma mark - Preview view

@interface ApolloAMPreviewView : UIView
@property (nonatomic, strong) ApolloAMPreviewState *previewState;
@property (nonatomic, strong) UIColor *accentColor;
// The rendered blocks and their signatures, keyed — what the content view's
// refresh diffs against the previous rendering.
@property (nonatomic, copy) NSDictionary<NSString *, UIView *> *itemViewsByKey;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *itemSignaturesByKey;
- (void)apollo_configurePreview;
- (CGFloat)apollo_heightForWidth:(CGFloat)width;
@end

@implementation ApolloAMPreviewView {
    UILabel *_captionLabel;
    UIView *_panelView;
    NSArray<UIView *> *_rowViews;
    UILabel *_moreLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    return self;
}

- (UIColor *)apollo_accent {
    return self.accentColor ?: ApolloThemeAccentColor() ?: self.tintColor;
}

- (NSUInteger)apollo_shownRowCount {
    return MIN(self.previewState.visibleItems.count, kApolloAMPreviewMaxRows);
}

- (NSUInteger)apollo_moreCount {
    NSUInteger visible = self.previewState.visibleItems.count;
    return visible > kApolloAMPreviewMaxRows ? visible - kApolloAMPreviewMaxRows : 0;
}

- (CGFloat)apollo_panelHeight {
    return 2.0 * kApolloAMPreviewPanelPadding + (CGFloat)[self apollo_shownRowCount] * kApolloAMPreviewRowHeight;
}

- (CGFloat)apollo_heightForWidth:(__unused CGFloat)width {
    CGFloat height = kApolloAMPreviewTopPadding + kApolloAMPreviewCaptionHeight + kApolloAMPreviewCaptionSpacing
        + [self apollo_panelHeight] + kApolloAMPreviewBottomPadding;
    if ([self apollo_moreCount] > 0) height += kApolloAMPreviewMoreHeight;
    return ceil(height);
}

// One menu row: icon + title, drawn like this device's menu draws it — label
// ink on the glass UIMenu, the accent on Apollo's classic sheet — with a
// hairline under every row but the last.
- (UIView *)apollo_rowViewForItem:(ApolloActionMenuItem *)item last:(BOOL)last {
    BOOL glass = self.previewState.glass;
    if (ApolloAMItemDrawsAsPalette(item, glass)) return [self apollo_paletteRowViewLast:last];
    BOOL moderator = ApolloActionMenuContextIsModerator(self.previewState.context) ||
        [item.itemID isEqualToString:@"moderator"];
    BOOL destructive = [item.title hasPrefix:@"Delete"] || [item.title hasPrefix:@"Remove"];
    UIColor *rowColor = destructive ? UIColor.systemRedColor
        : (moderator ? ApolloModeratorColor() : (glass ? UIColor.labelColor : [self apollo_accent]));
    UIView *row = [UIView new];
    row.backgroundColor = UIColor.clearColor;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[item icon]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = rowColor;
    icon.tag = 1;
    [row addSubview:icon];

    UILabel *title = [UILabel new];
    title.text = item.title;
    title.font = [UIFont systemFontOfSize:13.0];
    title.textColor = rowColor;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.tag = 2;
    [row addSubview:title];

    if (!last) {
        UIView *separator = [UIView new];
        separator.backgroundColor = [(ApolloThemeSeparatorColor() ?: UIColor.separatorColor) colorWithAlphaComponent:0.6];
        separator.tag = 3;
        [row addSubview:separator];
    }
    return row;
}

// The quick new-post buttons: the four glyphs the glass menu's small-element
// section shows (the bundled custom symbols, with the same stock fallbacks),
// spread evenly across the row, under the full-width hairline that section has.
- (UIView *)apollo_paletteRowViewLast:(BOOL)last {
    UIView *row = [UIView new];
    row.backgroundColor = UIColor.clearColor;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightRegular];
    NSArray<NSArray<NSString *> *> *glyphs = @[ @[ @"custom.photo.badge.plus", @"photo" ],
                                               @[ @"custom.link.badge.plus", @"link" ],
                                               @[ @"custom.text.page.badge.plus", @"text.alignleft" ],
                                               @[ @"custom.chart.bar.horizontal.page.fill.badge.plus", @"chart.bar" ] ];
    for (NSArray<NSString *> *glyph in glyphs) {
        UIImage *image = ApolloPollComposeSymbol(glyph[0]) ?: [UIImage systemImageNamed:glyph[1]];
        image = [[image imageByApplyingSymbolConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIImageView *icon = [[UIImageView alloc] initWithImage:image];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.tintColor = UIColor.labelColor;
        icon.tag = 4;
        [row addSubview:icon];
    }
    if (!last) {
        UIView *separator = [UIView new];
        separator.backgroundColor = [(ApolloThemeSeparatorColor() ?: UIColor.separatorColor) colorWithAlphaComponent:0.6];
        separator.tag = 3;
        [row addSubview:separator];
    }
    return row;
}

- (void)apollo_configurePreview {
    for (UIView *view in self.subviews) [view removeFromSuperview];
    ApolloAMPreviewState *state = self.previewState;
    if (!state) return;

    NSMutableDictionary<NSString *, UIView *> *viewsByKey = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *signaturesByKey = [NSMutableDictionary dictionary];
    UIColor *accent = [self apollo_accent];
    NSString *accentKey = [NSString stringWithFormat:@"%p", accent];

    UILabel *caption = [UILabel new];
    caption.text = [[NSString stringWithFormat:@"%@ menu", ApolloActionMenuContextTitle(state.context)] uppercaseString];
    caption.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    caption.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    [self addSubview:caption];
    _captionLabel = caption;
    viewsByKey[kApolloAMPreviewKeyCaption] = caption;
    signaturesByKey[kApolloAMPreviewKeyCaption] = [@"caption|" stringByAppendingString:caption.text];

    // The menu surface, drawn under the rows (the rows are siblings, not
    // children, so each animates on its own).
    UIView *panel = [UIView new];
    panel.backgroundColor = state.glass
        ? [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.55]
        : [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.7];
    panel.layer.cornerRadius = state.glass ? 18.0 : 12.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    panel.layer.borderColor = [[(ApolloThemeSeparatorColor() ?: UIColor.separatorColor) colorWithAlphaComponent:0.5] resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    [self addSubview:panel];
    _panelView = panel;
    viewsByKey[kApolloAMPreviewKeyPanel] = panel;
    signaturesByKey[kApolloAMPreviewKeyPanel] = [NSString stringWithFormat:@"panel|%d|%lu", state.glass,
                                                 (unsigned long)[self apollo_shownRowCount]];

    NSUInteger shown = [self apollo_shownRowCount];
    NSMutableArray<UIView *> *rows = [NSMutableArray arrayWithCapacity:shown];
    for (NSUInteger i = 0; i < shown; i++) {
        ApolloActionMenuItem *item = state.visibleItems[i];
        BOOL last = (i + 1 == shown);
        UIView *row = [self apollo_rowViewForItem:item last:last];
        [self addSubview:row];
        [rows addObject:row];
        NSString *key = [kApolloAMPreviewRowKeyPrefix stringByAppendingString:item.itemID];
        viewsByKey[key] = row;
        BOOL moderator = ApolloActionMenuContextIsModerator(state.context) || [item.itemID isEqualToString:@"moderator"];
        BOOL destructive = [item.title hasPrefix:@"Delete"] || [item.title hasPrefix:@"Remove"];
        signaturesByKey[key] = [NSString stringWithFormat:@"%@|%@|%d|%d|%@|%d|%d",
                                ApolloAMItemDrawsAsPalette(item, state.glass) ? @"palette" : @"row",
                                item.title, state.glass, last, accentKey, moderator, destructive];
    }
    _rowViews = rows;

    NSUInteger more = [self apollo_moreCount];
    if (more > 0) {
        UILabel *moreLabel = [UILabel new];
        moreLabel.text = [NSString stringWithFormat:@"+%lu more", (unsigned long)more];
        moreLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
        moreLabel.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
        moreLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:moreLabel];
        _moreLabel = moreLabel;
        viewsByKey[kApolloAMPreviewKeyMore] = moreLabel;
        signaturesByKey[kApolloAMPreviewKeyMore] = [@"more|" stringByAppendingString:moreLabel.text];
    } else {
        _moreLabel = nil;
    }

    self.itemViewsByKey = viewsByKey;
    self.itemSignaturesByKey = signaturesByKey;
    [self setNeedsLayout];
}

// Frame-based: this is a plain settings mock, not a Texture hook, and the
// keyed diff needs every block's frame the moment the rendering is laid out.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    if (width <= 0.0) return;

    CGFloat y = kApolloAMPreviewTopPadding;
    _captionLabel.frame = CGRectMake(kApolloAMPreviewSidePadding, y,
                                     MAX(0.0, width - 2.0 * kApolloAMPreviewSidePadding - 48.0), kApolloAMPreviewCaptionHeight);
    y += kApolloAMPreviewCaptionHeight + kApolloAMPreviewCaptionSpacing;

    CGFloat panelWidth = MIN(kApolloAMPreviewPanelMaxWidth, width - 2.0 * kApolloAMPreviewSidePadding);
    CGFloat panelX = round((width - panelWidth) / 2.0);
    CGFloat panelHeight = [self apollo_panelHeight];
    _panelView.frame = CGRectMake(panelX, y, panelWidth, panelHeight);

    CGFloat rowY = y + kApolloAMPreviewPanelPadding;
    for (UIView *row in _rowViews) {
        row.frame = CGRectMake(panelX, rowY, panelWidth, kApolloAMPreviewRowHeight);
        UIView *icon = [row viewWithTag:1];
        UIView *title = [row viewWithTag:2];
        UIView *separator = [row viewWithTag:3];
        CGFloat iconSide = 18.0;
        CGFloat iconY = round((kApolloAMPreviewRowHeight - iconSide) / 2.0);
        icon.frame = CGRectMake(14.0, iconY, iconSide, iconSide);
        CGFloat titleX = 14.0 + iconSide + 10.0;
        title.frame = CGRectMake(titleX, 0.0, MAX(0.0, panelWidth - titleX - 12.0), kApolloAMPreviewRowHeight);
        // A new-post buttons row (no icon/title, tag-4 glyphs instead): spread
        // the glyphs evenly and run its hairline the full width, as the menu does.
        NSMutableArray<UIView *> *glyphs = [NSMutableArray array];
        for (UIView *subview in row.subviews) {
            if (subview.tag == 4) [glyphs addObject:subview];
        }
        CGFloat slot = glyphs.count > 0 ? panelWidth / (CGFloat)glyphs.count : 0.0;
        for (NSUInteger g = 0; g < glyphs.count; g++) {
            glyphs[g].frame = CGRectMake(round(slot * (CGFloat)g + (slot - iconSide) / 2.0), iconY, iconSide, iconSide);
        }
        CGFloat hairline = 1.0 / UIScreen.mainScreen.scale;
        CGFloat separatorX = glyphs.count > 0 ? 0.0 : titleX;
        separator.frame = CGRectMake(separatorX, kApolloAMPreviewRowHeight - hairline, MAX(0.0, panelWidth - separatorX), hairline);
        rowY += kApolloAMPreviewRowHeight;
    }
    y += panelHeight;
    if (_moreLabel) {
        _moreLabel.frame = CGRectMake(panelX, y, panelWidth, kApolloAMPreviewMoreHeight);
    }
}

@end

#pragma mark - Preview content view (fills the pinned card)

// The host's contentView: owns the current rendering, replaces it with an
// animated keyed diff when the layout changes, and knows how tall the card
// must be for a given state (what the spacer row's height block asks).
@interface ApolloAMPreviewContentView : UIView
@property (nonatomic, strong) ApolloAMPreviewView *currentPreviewView;
@property (nonatomic, strong) UIColor *accentColor;
@property (nonatomic, strong) UIViewPropertyAnimator *previewAnimator;
@property (nonatomic) NSUInteger previewTransitionGeneration;
@property (nonatomic) BOOL previewRefreshPending;
@property (nonatomic, copy) ApolloActionMenuContext pendingContext;
+ (CGFloat)heightForState:(ApolloAMPreviewState *)state;
- (void)apollo_refreshForContext:(ApolloActionMenuContext)context width:(CGFloat)width animated:(BOOL)animated;
- (void)apollo_finishPreviewTransition;
@end

@implementation ApolloAMPreviewContentView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;
    return self;
}

+ (CGFloat)heightForState:(ApolloAMPreviewState *)state {
    ApolloAMPreviewView *probe = [[ApolloAMPreviewView alloc] initWithFrame:CGRectZero];
    probe.previewState = state;
    return [probe apollo_heightForWidth:0.0];
}

- (ApolloAMPreviewView *)apollo_previewViewForState:(ApolloAMPreviewState *)state width:(CGFloat)width {
    ApolloAMPreviewView *preview = [[ApolloAMPreviewView alloc] initWithFrame:CGRectZero];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.accentColor = self.accentColor;
    preview.previewState = state;
    [preview apollo_configurePreview];
    state.previewHeight = [preview apollo_heightForWidth:width];
    return preview;
}

- (void)apollo_addPreviewView:(ApolloAMPreviewView *)preview height:(CGFloat)height {
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

- (void)apollo_replacePreviewImmediately:(ApolloAMPreviewView *)preview state:(ApolloAMPreviewState *)state {
    [self apollo_finishPreviewTransition];
    for (UIView *subview in self.subviews) [subview removeFromSuperview];
    [self apollo_addPreviewView:preview height:state.previewHeight];
    preview.alpha = 1.0;
    self.currentPreviewView = preview;
    [UIView performWithoutAnimation:^{ [self layoutIfNeeded]; }];
}

// Re-render for the context's current layout. Animated: the new rendering is
// laid out over the old one and each block is matched by key — a row that
// survived slides from its old spot to its new one (a pixel-identical twin
// swaps in silently; a restyled one cross-fades on the way), a hidden row
// scale-fades out, a re-shown one scale-fades in. The screen springs the
// spacer row (and so the card) to the new height alongside. A refresh landing
// mid-animation is queued and replayed once the animation completes.
- (void)apollo_refreshForContext:(ApolloActionMenuContext)context width:(CGFloat)width animated:(BOOL)animated {
    if (animated && self.previewAnimator.state == UIViewAnimatingStateActive) {
        self.previewRefreshPending = YES;
        self.pendingContext = context;
        return;
    }
    [self apollo_finishPreviewTransition];

    ApolloAMPreviewState *state = ApolloAMCurrentPreviewState(context);
    ApolloAMPreviewView *incoming = [self apollo_previewViewForState:state width:width];
    ApolloAMPreviewView *outgoing = self.currentPreviewView;
    if (!animated || UIAccessibilityIsReduceMotionEnabled() || !outgoing) {
        [self apollo_replacePreviewImmediately:incoming state:state];
        return;
    }

    [self layoutIfNeeded];
    [self apollo_addPreviewView:incoming height:state.previewHeight];
    [incoming layoutIfNeeded];
    self.currentPreviewView = incoming;

    NSDictionary<NSString *, UIView *> *oldItems = outgoing.itemViewsByKey;
    NSDictionary<NSString *, UIView *> *newItems = incoming.itemViewsByKey;
    NSMutableArray<UIView *> *departingItems = [NSMutableArray array]; // gone: scale-fade out in place
    NSMutableArray<UIView *> *restyledItems = [NSMutableArray array];  // old look of a survivor: fade out in place
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
        // Top-aligned slide: the panel grows/shrinks from its top edge, and a
        // row keeps its own height, so anchoring on the top keeps a moving
        // row's icon and title on one straight path.
        newItem.transform = CGAffineTransformMakeTranslation(CGRectGetMinX(oldFrame) - CGRectGetMinX(newFrame),
                                                              CGRectGetMinY(oldFrame) - CGRectGetMinY(newFrame));
        BOOL sameLook = [outgoing.itemSignaturesByKey[key] isEqualToString:incoming.itemSignaturesByKey[key]];
        if (sameLook) {
            oldItem.alpha = 0.0; // the twin takes over from the very first frame
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
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.34 timingParameters:timing];
    __weak __typeof(self) weakSelf = self;
    __weak UIViewPropertyAnimator *weakAnimator = animator;
    [animator addAnimations:^{
        for (UIView *item in newItems.allValues) {
            item.alpha = 1.0;
            item.transform = CGAffineTransformIdentity;
        }
        for (UIView *item in departingItems) {
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.88, 0.88);
        }
        for (UIView *item in restyledItems) item.alpha = 0.0;
    }];
    [animator addCompletion:^(__unused UIViewAnimatingPosition finalPosition) {
        [outgoing removeFromSuperview];
        incoming.alpha = 1.0;
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.previewTransitionGeneration == generation && strongSelf.previewAnimator == weakAnimator) {
            strongSelf.previewAnimator = nil;
        }
        if (strongSelf.previewRefreshPending) {
            strongSelf.previewRefreshPending = NO;
            ApolloActionMenuContext pending = strongSelf.pendingContext ?: context;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.previewTransitionGeneration != generation) return;
                [weakSelf apollo_refreshForContext:pending width:CGRectGetWidth(weakSelf.bounds) animated:YES];
            });
        }
    }];
    self.previewAnimator = animator;
    [animator startAnimation];
}

@end

#pragma mark - Item row cell

// One catalogue item: its menu icon, title, accent checkmark and drag grip.
// Tapping flips visibility; a hidden item stays available for re-enabling.
@interface ApolloAMItemCell : UITableViewCell
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, strong, readonly) UIImageView *checkmark;
@property (nonatomic, strong, readonly) UIImageView *grip;
@property (nonatomic) BOOL showsGrip;
@end

static const CGFloat kApolloAMCheckmarkWidth = 22.0;
static const CGFloat kApolloAMGripWidth = 24.0;
static const CGFloat kApolloAMAccessoryGap = 14.0;
static const CGFloat kApolloAMAccessoryHeight = 28.0;

@implementation ApolloAMItemCell {
    UIView *_accessory;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    UIImageSymbolConfiguration *checkConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
    _checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:checkConfiguration]];
    _checkmark.contentMode = UIViewContentModeCenter;
    UIImageSymbolConfiguration *gripConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
    _grip = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.horizontal.3" withConfiguration:gripConfiguration]];
    _grip.tintColor = UIColor.tertiaryLabelColor;
    _grip.contentMode = UIViewContentModeCenter;
    _accessory = [[UIView alloc] initWithFrame:CGRectZero];
    [_accessory addSubview:_checkmark];
    [_accessory addSubview:_grip];
    self.accessoryView = _accessory;
    _showsGrip = YES;
    [self layoutAccessory];
    self.imageView.contentMode = UIViewContentModeCenter;
    self.textLabel.numberOfLines = 1;
    self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    return self;
}

- (void)setShowsGrip:(BOOL)showsGrip {
    if (_showsGrip == showsGrip) return;
    _showsGrip = showsGrip;
    [self layoutAccessory];
}

- (void)layoutAccessory {
    CGFloat width = kApolloAMCheckmarkWidth + (self.showsGrip ? kApolloAMAccessoryGap + kApolloAMGripWidth : 0.0);
    _accessory.bounds = CGRectMake(0.0, 0.0, width, kApolloAMAccessoryHeight);
    self.checkmark.frame = CGRectMake(0.0, 0.0, kApolloAMCheckmarkWidth, kApolloAMAccessoryHeight);
    self.grip.frame = CGRectMake(width - kApolloAMGripWidth, 0.0, kApolloAMGripWidth, kApolloAMAccessoryHeight);
    self.grip.hidden = !self.showsGrip;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect content = self.contentView.bounds;
    // Apollo's option-* art is a mixed bag of shapes; a fixed 28pt box keeps
    // every title on the same column.
    CGRect imageFrame = self.imageView.frame;
    imageFrame.size = CGSizeMake(28.0, 28.0);
    imageFrame.origin.y = round((CGRectGetHeight(content) - 28.0) / 2.0);
    self.imageView.frame = imageFrame;
    CGRect textFrame = self.textLabel.frame;
    textFrame.origin.x = CGRectGetMaxX(imageFrame) + 12.0;
    textFrame.size.width = MAX(0.0, CGRectGetMaxX(content) - 8.0 - CGRectGetMinX(textFrame));
    self.textLabel.frame = textFrame;
    CGRect detailFrame = self.detailTextLabel.frame;
    detailFrame.origin.x = textFrame.origin.x;
    detailFrame.size.width = textFrame.size.width;
    self.detailTextLabel.frame = detailFrame;
    // The theme pass tints every image view in the cell with the accent; the
    // grip is chrome, not content; the checkmark is accent-coloured.
    self.grip.tintColor = UIColor.tertiaryLabelColor;
}

@end

#pragma mark - The screen

@interface ApolloActionMenuEditorViewController () <UITableViewDragDelegate, UITableViewDropDelegate>
@property (nonatomic, copy) ApolloActionMenuContext context;
@property (nonatomic, strong) ApolloPinnedPreviewHost *previewHost;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *itemRowHeights;
@property (nonatomic, strong) ApolloAMItemCell *measuringItemCell;
// Card width the spacer row was last measured for (0 = only the table's own
// section inset was available). Updated from the real cell frame by the pinned
// layout pass, which then asks for a one-row re-measure.
@property (nonatomic) CGFloat previewCardWidth;
@property (nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedback;
@end

static NSString *const kApolloAMRowReset = @"reset";
static NSString *const kApolloAMRowPreview = @"preview";
static NSString *const kApolloAMItemRowPrefix = @"item.";

@implementation ApolloActionMenuEditorViewController

- (instancetype)initWithContext:(NSString *)context {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _context = [context copy];
    }
    return self;
}

- (void)viewDidLoad {
    if (!self.context) self.context = ApolloActionMenuContextPost;
    [super viewDidLoad];
    self.title = self.editingAllMenus ? @"All Menus" : ApolloActionMenuContextTitle(self.context);
    self.selectionFeedback = [[UISelectionFeedbackGenerator alloc] init];

    // Drag & drop powers the item rows' reordering (touch and hold a row, then
    // drag). Scoped hard to that section by the drag delegate + drop proposal;
    // every other row refuses to lift. This keeps the UISwitch accessories
    // fully functional (a persistent editing mode would hide them).
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;

    // All Menus is only a visibility overview; it has no runtime menu to
    // preview and no reorder controls.
    if (self.editingAllMenus) return;

    // The pinned preview: shared layout pass on the table (the subclass adds no
    // ivars, so isa-swizzling the existing table view is safe) + the host as a
    // direct subview of it, never a cell, so it survives every reload.
    if (![self.tableView isKindOfClass:[ApolloPinnedPreviewTableView class]]) {
        object_setClass(self.tableView, [ApolloPinnedPreviewTableView class]);
    }
    ApolloPinnedPreviewHost *host = [[ApolloPinnedPreviewHost alloc] initWithFrame:CGRectZero];
    host.contentView = [[ApolloAMPreviewContentView alloc] initWithFrame:CGRectZero];
    __weak __typeof(self) weakSelf = self;
    host.spacerIndexPath = ^NSIndexPath * {
        return [weakSelf indexPathForRowID:kApolloAMRowPreview];
    };
    host.cardWidthDidChange = ^(CGFloat width) {
        [weakSelf previewCardWidthDidChange:width];
    };
    host.pinned = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyActionMenuPreviewPinned];
    host.pinDidChange = ^(BOOL pinned) {
        [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:UDKeyActionMenuPreviewPinned];
        ApolloLog(@"[ActionMenuSettings] preview %@", pinned ? @"pinned" : @"unpinned");
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
    [self.previewContentView apollo_refreshForContext:self.context
                                                width:[self previewCardWidthForTable:self.tableView]
                                             animated:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
    self.previewContentView.previewRefreshPending = NO;
    self.previewContentView.pendingContext = nil;
    [self.previewContentView apollo_finishPreviewTransition];
    ++self.previewContentView.previewTransitionGeneration;
    [super viewWillDisappear:animated];
}

- (ApolloAMPreviewContentView *)previewContentView {
    return (ApolloAMPreviewContentView *)self.previewHost.contentView;
}

#pragma mark - Form

- (NSString *)itemRowIDForItemID:(NSString *)itemID {
    return [NSString stringWithFormat:@"%@%@.%@", kApolloAMItemRowPrefix, self.context, itemID];
}

- (NSString *)firstItemRowID {
    NSString *first = [self editableItems].firstObject.itemID;
    return first ? [self itemRowIDForItemID:first] : nil;
}

// All is a settings overview, never a runtime menu context. Each tap
// updates only the contexts whose catalogue contains the item. A mixed state
// remains visible in the subtitle; selecting a menu exposes its own override.
- (BOOL)editingAllMenus {
    return [self.context isEqualToString:ApolloActionMenuEditorAllMenus];
}

- (NSArray<ApolloActionMenuItem *> *)editableItems {
    NSMutableArray<ApolloActionMenuItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    NSArray *contexts = self.editingAllMenus ? ApolloActionMenuAllContexts() : @[ self.context ];
    for (ApolloActionMenuContext context in contexts) {
        for (NSString *itemID in ApolloActionMenuResolvedOrder(context)) {
            ApolloActionMenuItem *item = ApolloActionMenuCatalogItem(context, itemID);
            // A locked row (the feed's Submit Post) is not the user's to move or hide.
            if (!item || item.locked || [ids containsObject:itemID]) continue;
            [ids addObject:itemID];
            [items addObject:item];
        }
    }
    if (self.editingAllMenus) {
        [items sortUsingComparator:^NSComparisonResult(ApolloActionMenuItem *a, ApolloActionMenuItem *b) {
            return [a.title localizedStandardCompare:b.title];
        }];
    }
    return items;
}

- (NSArray<NSString *> *)contextsForItem:(NSString *)itemID {
    if (!self.editingAllMenus) return @[ self.context ];
    NSMutableArray *contexts = [NSMutableArray array];
    for (NSString *context in ApolloActionMenuAllContexts()) {
        if (ApolloActionMenuCatalogItem(context, itemID)) [contexts addObject:context];
    }
    return contexts;
}

- (BOOL)itemIsHidden:(NSString *)itemID {
    for (NSString *context in [self contextsForItem:itemID]) {
        if (!ApolloActionMenuIsItemHidden(context, itemID)) return NO;
    }
    return YES;
}

// The selected menu's locked rows are absent from the list; the footer says
// where they are instead (nil when the menu has none).
- (NSString *)lockedItemsNote {
    if (self.editingAllMenus) return nil;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    for (ApolloActionMenuItem *item in ApolloActionMenuCatalog(self.context)) {
        if (!item.locked) continue;
        [notes addObject:ApolloAMItemDrawsAsPalette(item, IsLiquidGlass())
            ? [NSString stringWithFormat:@"The new-post buttons (%@) always stay at the top of this menu and can’t be hidden.", item.title]
            : [NSString stringWithFormat:@"%@ always stays at the top of this menu and can’t be hidden.", item.title]];
    }
    return notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    // ---- Preview (the spacer row the pinned card sits on) ----

    // Escape hatch (custom row): a transparent placeholder — the pinned host
    // draws the card on top of (or, once scrolled, instead of) this slot. Its
    // height is the card's height for the selected menu's current layout.
    ApolloSettingsRow *preview =
        [ApolloSettingsRow customRowWithID:kApolloAMRowPreview
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            ApolloPinnedPreviewSpacerCell *cell =
                [[ApolloPinnedPreviewSpacerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloPinnedPreviewClearSpacerCell(cell);
            cell.isAccessibilityElement = NO;
            return cell;
        }
                                  onSelect:nil];
    preview.height = ^CGFloat {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return 0.0;
        return [ApolloAMPreviewContentView heightForState:ApolloAMCurrentPreviewState(strongSelf.context)];
    };

    // ---- Items (drag to reorder, tap to show/hide) ----

    NSMutableArray<ApolloSettingsRow *> *itemRows = [NSMutableArray array];
    for (ApolloActionMenuItem *item in [self editableItems]) {
        NSString *itemID = item.itemID;
        // Hidden state is read live on every configure and restyled in place.
        ApolloSettingsRow *row =
            [ApolloSettingsRow customRowWithID:[self itemRowIDForItemID:itemID]
                                          cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *r) {
            return [weakSelf itemCellForItem:item
                                      hidden:[weakSelf itemIsHidden:item.itemID]
                                     inTable:tableView];
        }
                                      onSelect:^{ [weakSelf toggleItemWithID:itemID]; }];
        row.height = ^CGFloat {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return UITableViewAutomaticDimension;
            BOOL subtitle = strongSelf.editingAllMenus || !ApolloActionMenuItemWasOffered(strongSelf.context, itemID);
            return [strongSelf itemRowHeightWithSubtitle:subtitle itemID:itemID];
        };
        [itemRows addObject:row];
    }

    // ---- Reset ----

    ApolloSettingsRow *reset =
        [ApolloSettingsRow buttonRowWithID:kApolloAMRowReset
                                     title:self.editingAllMenus ? @"Reset All Menus…" : @"Reset Menu…"
                                    action:^{ [weakSelf presentResetMenuSheet]; }];
    reset.enabled = ^BOOL {
        return weakSelf.editingAllMenus
            ? ApolloActionMenuCustomizedContextCount() > 0
            : ApolloActionMenuContextIsCustomized(weakSelf.context);
    };

    NSString *itemsFooter;
    if (self.editingAllMenus) {
        itemsFooter = @"Tap an action to show or hide it across the menus that support it.";
    } else {
        itemsFooter = @"Tap an action to show or hide it; touch and hold to reorder. The pinned preview shows your current layout; tap it to pin or unpin.";
        NSString *lockedNote = [self lockedItemsNote];
        if (lockedNote) itemsFooter = [itemsFooter stringByAppendingFormat:@" %@", lockedNote];
    }
    if (!self.editingAllMenus && !IsLiquidGlass()) {
        itemsFooter = [itemsFooter stringByAppendingString:@"\n\nOn Classic, Apollo Reborn actions stay below Apollo’s actions and can’t be reordered or hidden."];
    }

    NSMutableArray *sections = [NSMutableArray array];
    if (!self.editingAllMenus) [sections addObject:[ApolloSettingsSection sectionWithTitle:@"Preview" footer:nil rows:@[ preview ]]];
    [sections addObjectsFromArray:@[
        [ApolloSettingsSection sectionWithTitle:nil footer:itemsFooter rows:itemRows],
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[ reset ]],
    ]];
    return sections;
}

- (UITableViewCell *)itemCellForItem:(ApolloActionMenuItem *)item hidden:(BOOL)hidden inTable:(UITableView *)tableView {
    static NSString *const reuseID = @"Cell_ActionMenuItem";
    ApolloAMItemCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[ApolloAMItemCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    cell.itemID = item.itemID;
    cell.textLabel.text = item.title;
    cell.imageView.image = [item icon];
    BOOL fixedTweakRow = !self.editingAllMenus && !ApolloNativeActionMenusActive() && item.isTweakRow;
    cell.showsGrip = !self.editingAllMenus && !fixedTweakRow;
    [self styleItemCell:cell forItem:item hidden:hidden];
    return cell;
}

- (CGFloat)itemRowHeightWithSubtitle:(BOOL)subtitle itemID:(NSString *)itemID {
    UITableView *table = self.tableView;
    CGFloat width = CGRectGetWidth(table.bounds) - table.layoutMargins.left - table.layoutMargins.right;
    UITableViewCell *sample = table.visibleCells.firstObject;
    if (sample && sample.superview) width = CGRectGetWidth([sample.superview convertRect:sample.frame toView:table]);
    if (width <= 0.0) return UITableViewAutomaticDimension;
    NSString *key = [NSString stringWithFormat:@"%d|%@|%.0f|%@", subtitle, itemID ?: @"", width,
                     table.traitCollection.preferredContentSizeCategory ?: @""];
    NSNumber *cached = self.itemRowHeights[key];
    if (cached) return cached.doubleValue;
    if (!self.measuringItemCell) {
        self.measuringItemCell = [[ApolloAMItemCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    }
    ApolloAMItemCell *cell = self.measuringItemCell;
    cell.textLabel.text = @"Measure";
    if (!subtitle) cell.detailTextLabel.text = nil;
    else if ([itemID isEqualToString:@"moderator"]) cell.detailTextLabel.text = @"Shown in subreddits you moderate";
    else cell.detailTextLabel.text = @"Shown when relevant";
    cell.imageView.image = [UIImage systemImageNamed:@"square"
                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                                                                   weight:UIImageSymbolWeightRegular]];
    cell.bounds = CGRectMake(0.0, 0.0, width, 100.0);
    [cell setNeedsLayout];
    [cell layoutIfNeeded];
    CGFloat height = ceil([cell systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                  withHorizontalFittingPriority:UILayoutPriorityRequired
                                        verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    if (height <= 0.0) return UITableViewAutomaticDimension;
    if (!self.itemRowHeights) self.itemRowHeights = [NSMutableDictionary dictionary];
    self.itemRowHeights[key] = @(height);
    return height;
}

// Restyle the checkmark, content and accessibility in place so a tap never
// replaces the row or shifts the pinned preview/list under the user's finger.
- (void)styleItemCell:(ApolloAMItemCell *)cell forItem:(ApolloActionMenuItem *)item hidden:(BOOL)hidden {
    // A row Apollo only offers sometimes says so — unless this user's menu
    // offered it last time (a moderator's Moderator row, say).
    BOOL offered = self.editingAllMenus || ApolloActionMenuItemWasOffered(self.context, item.itemID);
    if (offered) cell.detailTextLabel.text = nil;
    else if ([item.itemID isEqualToString:@"moderator"]) cell.detailTextLabel.text = @"Shown in subreddits you moderate";
    else cell.detailTextLabel.text = @"Shown when relevant";
    if (self.editingAllMenus) {
        NSArray *contexts = [self contextsForItem:item.itemID];
        NSMutableArray<NSString *> *hiddenNames = [NSMutableArray array];
        for (NSString *context in contexts) {
            if (!ApolloActionMenuIsItemHidden(context, item.itemID)) continue;
            NSString *name = ApolloActionMenuContextTitle(context);
            if (ApolloActionMenuContextIsModerator(context)) name = [@"Moderator " stringByAppendingString:name];
            [hiddenNames addObject:name];
        }
        if (hiddenNames.count == 0) {
            cell.detailTextLabel.text = nil;
        } else {
            NSString *menuList = hiddenNames.count == 1 ? hiddenNames.firstObject :
                (hiddenNames.count == 2 ? [hiddenNames componentsJoinedByString:@" and "] :
                 [NSString stringWithFormat:@"%@ and %@",
                  [[hiddenNames subarrayWithRange:NSMakeRange(0, hiddenNames.count - 1)] componentsJoinedByString:@", "],
                  hiddenNames.lastObject]);
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Hidden in %@", menuList];
        }
    }
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    // Reuse pool: set BOTH states explicitly. A hidden row's label is disabled
    // (the theme pass leaves disabled labels alone, so the dim survives it);
    // a shown row is re-enabled, reset to the plain label colour and marked
    // for the theme's primary text like every other settings row.
    UIColor *accent = [self apollo_themeAccentColor] ?: ApolloThemeAccentColor() ?: self.view.tintColor;
    cell.checkmark.tintColor = accent;
    cell.checkmark.alpha = hidden ? 0.0 : 1.0;
    cell.imageView.tintColor = hidden ? UIColor.tertiaryLabelColor : accent;
    cell.textLabel.enabled = !hidden;
    cell.textLabel.textColor = hidden ? UIColor.secondaryLabelColor : UIColor.labelColor;
    if (!hidden) [self apollo_applyPrimaryTextColorToCell:cell];
    cell.textLabel.alpha = 1.0;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    cell.accessibilityLabel = offered ? item.title : [NSString stringWithFormat:@"%@, shown when relevant", item.title];
    cell.accessibilityValue = self.editingAllMenus ? (cell.detailTextLabel.text ?: @"Shown") : (hidden ? @"Hidden" : @"Shown");
    cell.accessibilityHint = self.editingAllMenus
        ? (hidden ? @"Double tap to show it in the menus that support it." : @"Double tap to hide it from the menus that support it.")
        : (hidden ? @"Double tap to show it in this menu." : @"Double tap to hide it from this menu.");
}

#pragma mark - Actions

- (void)toggleItemWithID:(NSString *)itemID {
    if (itemID.length == 0) return;
    BOOL hide = ![self itemIsHidden:itemID];
    for (NSString *context in [self contextsForItem:itemID]) {
        ApolloActionMenuSetItemHidden(context, itemID, hide);
    }
    ApolloActionMenuItem *item = nil;
    for (ApolloActionMenuItem *candidate in [self editableItems]) {
        if ([candidate.itemID isEqualToString:itemID]) { item = candidate; break; }
    }
    UITableViewCell *cell = [self cellForRowID:[self itemRowIDForItemID:itemID]];
    if (item && [cell isKindOfClass:[ApolloAMItemCell class]]) {
        BOOL nowHidden = [self itemIsHidden:itemID];
        [UIView animateWithDuration:0.2 animations:^{
            [self styleItemCell:(ApolloAMItemCell *)cell forItem:item hidden:nowHidden];
        }];
    }
    [self reloadRowWithID:kApolloAMRowReset];
    [self animatePreviewStateChange];
}

- (void)presentResetMenuSheet {
    if (self.presentedViewController) return;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:self.editingAllMenus ? @"Reset All Menus" : @"Reset Menu"
                         message:self.editingAllMenus ? @"This restores the default order and visibility in every menu." : nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak __typeof(self) weakSelf = self;
    if (!self.editingAllMenus) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Reset Order Only"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [weakSelf resetCurrentMenuOrderOnly:YES];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:self.editingAllMenus ? @"Reset All Menus" : @"Reset Order and Visibility"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf resetCurrentMenuOrderOnly:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self cellForRowID:kApolloAMRowReset];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)resetCurrentMenuOrderOnly:(BOOL)orderOnly {
    for (NSString *context in (self.editingAllMenus ? ApolloActionMenuAllContexts() : @[ self.context ])) {
        if (orderOnly) ApolloActionMenuResetOrder(context);
        else ApolloActionMenuResetContext(context);
    }
    NSString *firstItemRowID = [self firstItemRowID];
    if (firstItemRowID) {
        [self rebuildSectionContainingRowID:firstItemRowID withRowAnimation:UITableViewRowAnimationFade];
    }
    [self reloadRowWithID:kApolloAMRowReset];
    [self animatePreviewStateChange];
}

#pragma mark - Reordering (drag & drop)

// The item rows' section index, derived by identity (never hardcoded).
- (NSInteger)itemsSectionIndex {
    NSString *firstItemRowID = [self firstItemRowID];
    NSIndexPath *anyItemRow = firstItemRowID ? [self indexPathForRowID:firstItemRowID] : nil;
    return anyItemRow ? anyItemRow.section : NSNotFound;
}

- (BOOL)indexPathIsItemRow:(NSIndexPath *)indexPath {
    return !self.editingAllMenus && indexPath && indexPath.section == [self itemsSectionIndex];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self indexPathIsItemRow:indexPath]) return NO;
    NSArray<ApolloActionMenuItem *> *items = [self editableItems];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)items.count) return NO;
    ApolloActionMenuItem *item = items[(NSUInteger)indexPath.row];
    return ApolloNativeActionMenusActive() || !item.isTweakRow;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
    if (![self indexPathIsItemRow:fromIndexPath] || ![self indexPathIsItemRow:toIndexPath]) return;
    NSMutableArray<NSString *> *order = [[[self editableItems] valueForKey:@"itemID"] mutableCopy];
    if (fromIndexPath.row < 0 || fromIndexPath.row >= (NSInteger)order.count ||
        toIndexPath.row < 0 || toIndexPath.row >= (NSInteger)order.count) return;
    NSString *moved = order[(NSUInteger)fromIndexPath.row];
    [order removeObjectAtIndex:(NSUInteger)fromIndexPath.row];
    [order insertObject:moved atIndex:(NSUInteger)toIndexPath.row];
    ApolloActionMenuSetOrder(self.context, order);
    [self noteRowMovedFromIndexPath:fromIndexPath toIndexPath:toIndexPath];
}

- (void)tableView:(UITableView *)tableView dropSessionDidEnd:(id<UIDropSession>)session {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf reloadRowWithID:kApolloAMRowReset];
        [strongSelf animatePreviewStateChange];
    });
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (![self indexPathIsItemRow:sourceIndexPath]) return sourceIndexPath;
    NSInteger itemsSection = [self itemsSectionIndex];
    NSInteger lastRow = MAX([tableView numberOfRowsInSection:itemsSection] - 1, 0);
    if (!ApolloNativeActionMenusActive()) {
        NSArray<ApolloActionMenuItem *> *items = [self editableItems];
        for (NSUInteger i = 0; i < items.count; i++) {
            if (items[i].isTweakRow) {
                if (i == 0) return sourceIndexPath;
                lastRow = (NSInteger)i - 1;
                break;
            }
        }
    }
    if ([self indexPathIsItemRow:proposedDestinationIndexPath]) {
        NSInteger row = MIN(proposedDestinationIndexPath.row, lastRow);
        return [NSIndexPath indexPathForRow:row inSection:itemsSection];
    }
    NSInteger row = proposedDestinationIndexPath.section < itemsSection ? 0 : lastRow;
    return [NSIndexPath indexPathForRow:row inSection:itemsSection];
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    BOOL movable = [self tableView:tableView canMoveRowAtIndexPath:indexPath];
    ApolloLog(@"[ActionMenuSettings] drag begin asked for %ld/%ld (movable: %d)",
              (long)indexPath.section, (long)indexPath.row, movable);
    if (!movable) return @[];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[NSItemProvider new]];
    item.localObject = indexPath;
    return @[ item ];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (session.localDragSession && [self indexPathIsItemRow:destinationIndexPath]) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                               intent:UITableViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    // Local same-table reorders with a .move/insertAtDestination proposal are
    // committed by UIKit through tableView:moveRowAtIndexPath:toIndexPath:
    // before this is called; nothing else can be dropped here.
}

#pragma mark - Pinned preview plumbing

// Card chrome follows the same theme walk as the real cells (cell colour,
// section corner radius, table background for the stuck backdrop, accent for
// the pin glyph), and the mock is re-rendered for the theme's ink.
- (void)applyThemeToPreviewHost {
    ApolloPinnedPreviewHost *host = self.previewHost;
    if (!host) return;
    host.card.backgroundColor = [self apollo_themeCellBackgroundColor];
    host.card.layer.cornerRadius = ApolloPinnedPreviewSectionCornerRadius(self.tableView);
    UIColor *tableBackground = self.tableView.backgroundColor;
    UIColor *resolved = [tableBackground resolvedColorWithTraitCollection:self.tableView.traitCollection];
    if (!resolved || CGColorGetAlpha(resolved.CGColor) < 0.99) {
        tableBackground = [UIColor systemGroupedBackgroundColor];
    }
    host.backdropColor = tableBackground;
    UIColor *accent = ApolloActionMenuContextIsModerator(self.context)
        ? ApolloModeratorColor() : [self apollo_themeAccentColor];
    host.accentColor = accent;
    self.previewContentView.accentColor = accent;
    [self.previewContentView apollo_refreshForContext:self.context
                                                width:[self previewCardWidthForTable:self.tableView]
                                             animated:NO];
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    [self applyThemeToPreviewHost];
}

// The spacer row must stay invisible whatever the theme pass does to cells.
- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    if ([cell isKindOfClass:[ApolloPinnedPreviewSpacerCell class]]) {
        ApolloPinnedPreviewClearSpacerCell(cell);
        return;
    }
    [super apollo_applyThemeToCell:cell];
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
    self.previewCardWidth = width;
    // The mock's height doesn't depend on the width (rows are fixed-height and
    // the panel is capped), so only the rendering needs the real width.
    [self.previewContentView apollo_refreshForContext:self.context width:width animated:NO];
}

// The layout changed: re-render the mock (keyed slide/fade) and spring the
// spacer row — and with it the card and every row beneath — to the new
// height in the same beat. Nothing reloads.
- (void)animatePreviewStateChange {
    if (self.editingAllMenus) return;
    CGFloat width = [self previewCardWidthForTable:self.tableView];
    [self.previewContentView apollo_refreshForContext:self.context width:width animated:YES];
    UITableView *table = self.tableView;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [table performBatchUpdates:nil completion:nil]; // re-reads the spacer's height block
        return;
    }
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [table performBatchUpdates:nil completion:nil]; // re-reads the spacer's height block
        [table layoutIfNeeded];                         // the host follows the new row rect
    }
                     completion:nil];
}

@end
