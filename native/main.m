//  牛马鼓励器 · 桌面小组件原生壳
//  Objective-C + WebKit，无 Xcode 依赖（仅需 Command Line Tools）
//  - 无边框透明悬浮窗，常驻桌面（可跨 Space）
//  - JS ←→ 原生 状态持久化 / 拖拽 / 尺寸切换 / 打开控制台

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <CoreGraphics/CGWindowLevel.h>

static NSString *const kAppDirName = @"NiuMaWidget";
/* 卡片四周留给阴影的透明边距，与 CSS --pad 一致。
   8.5 = 系统桌面小组件的内缩量：窗口 360×180 里真正画出来的卡片是 343×163，
   照这个数做，本组件才能和旁边那些系统小组件严丝合缝地对齐。 */
static const CGFloat kPad = 8.5;

typedef NS_ENUM(NSInteger, NMWCardKind) {
    NMWCardKindSmall = 0,
    NMWCardKindMedium = 1,
    NMWCardKindLarge = 2
};

static NSSize NMWCardSize(NMWCardKind kind) {
    switch (kind) {
        // 按系统桌面小组件的实测卡片尺寸来（窗口 180/360/360 减去两侧各 8.5 的内缩）：
        // 隔壁那些系统组件画出来的卡片就是 343×163、343×343，跟它们必须在同一档
        case NMWCardKindSmall:  return NSMakeSize(163, 163);   // 小：正方形
        case NMWCardKindMedium: return NSMakeSize(343, 163);   // 中：横向长方形
        case NMWCardKindLarge:  return NSMakeSize(343, 343);   // 大：大正方形
    }
    return NSMakeSize(343, 163);
}

// 与 CSS --r-card 对齐：small 24px，其余 28px（系统组件实测圆角）
static CGFloat NMWCardRadius(NMWCardKind kind) {
    return (kind == NMWCardKindSmall) ? 24.0 : 28.0;
}

// 生成圆角遮罩，让 NSVisualEffectView 只在卡片范围内磨砂（不含阴影外扩的透明边）
static NSImage *NMWRoundedMask(NSSize size, CGFloat radius, CGFloat inset) {
    if (size.width <= inset * 2.0 + 4.0 || size.height <= inset * 2.0 + 4.0) return nil;
    NSImage *img = [[NSImage alloc] initWithSize:size];
    [img lockFocus];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    NSRect r = NSMakeRect(inset, inset, size.width - inset * 2.0, size.height - inset * 2.0);
    [[NSColor blackColor] set];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
    [img unlockFocus];
    return img;
}

#pragma mark - 状态存储

static NSString *NMWStateFilePath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSURL *> *urls = [[NSFileManager defaultManager]
            URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
        NSURL *dir = [urls.firstObject URLByAppendingPathComponent:kAppDirName isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        path = [[dir URLByAppendingPathComponent:@"state.json"] path];
    });
    return path;
}

static NSString *NMWLoadStateJSON(void) {
    NSString *s = [NSString stringWithContentsOfFile:NMWStateFilePath()
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
    return (s.length > 0) ? s : @"null";
}

static void NMWSaveStateJSON(NSString *json) {
    if (json.length == 0) return;
    [json writeToFile:NMWStateFilePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSMutableDictionary *NMWLoadStateDict(void) {
    NSData *d = [NMWLoadStateJSON() dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [obj isKindOfClass:[NSDictionary class]] ? [obj mutableCopy] : [NSMutableDictionary dictionary];
}

static NSURL *NMWAppResource(NSString *name) {
    NSURL *res = [[NSBundle mainBundle] resourceURL];
    if (!res) return nil;
    NSURL *u = [[res URLByAppendingPathComponent:@"app"] URLByAppendingPathComponent:name];
    return [[NSFileManager defaultManager] fileExistsAtPath:u.path] ? u : nil;
}

// 诊断日志：写入 /tmp/niuma-widget.log，只为排查窗口可见性问题
static void NMWLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [[NSDate date].description substringWithRange:NSMakeRange(11,8)], msg];
    FILE *f = fopen("/tmp/niuma-widget.log", "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

#pragma mark - 控制器

@interface NMWController : NSObject <WKScriptMessageHandler>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) NSVisualEffectView *glass;
@property (nonatomic, copy) NSString *glassLevel;   // thin / standard / thick
@property (nonatomic, strong) NSWindow *dashWindow;
@property (nonatomic, strong) WKWebView *dashWeb;
@property (nonatomic, assign) NMWCardKind kind;
@property (nonatomic, strong) NSTimer *dragTimer;
@property (nonatomic, assign) NSPoint dragStartMouse;
@property (nonatomic, assign) NSPoint dragStartOrigin;
- (void)toggleVisible;
- (void)setKind:(NMWCardKind)kind;
- (void)openDashboard;
- (void)resetPosition;
- (void)persistUIFrame;
@end

@implementation NMWController

- (instancetype)init {
    self = [super init];
    if (self) {
        _kind = NMWCardKindMedium;
        NSDictionary *state = NMWLoadStateDict();
        _glassLevel = [state[@"glass"] isKindOfClass:[NSString class]] ? state[@"glass"] : @"standard";
        NSDictionary *ui = [state[@"ui"] isKindOfClass:[NSDictionary class]] ? state[@"ui"] : nil;
        if ([ui[@"cardSize"] isKindOfClass:[NSString class]]) {
            NSString *raw = ui[@"cardSize"];
            if ([raw isEqualToString:@"small"]) _kind = NMWCardKindSmall;
            else if ([raw isEqualToString:@"large"]) _kind = NMWCardKindLarge;
        }
        [self buildPanel];
        [self applySizeAnimated:NO];
        BOOL restored = NO;
        if ([ui[@"x"] isKindOfClass:[NSNumber class]] && [ui[@"y"] isKindOfClass:[NSNumber class]]) {
            NSPoint p = NSMakePoint([ui[@"x"] doubleValue], [ui[@"y"] doubleValue]);
            /* 用"这个坐标落在哪块屏"来选屏，而不是 NSScreen.mainScreen
               （它跟鼠标位置走：鼠标在外接屏上启动，卡片就会跳到那块屏的角落）。 */
            NSScreen *host = [NSScreen mainScreen];
            for (NSScreen *s in [NSScreen screens]) {
                if (NSPointInRect(p, s.frame)) { host = s; break; }
            }
            NSRect vf = host.visibleFrame;
            NSRect f = _panel.frame;
            // 保证整张卡片落在可见区域内（换过显示器/窗口尺寸变化后可能越界）
            if (p.x + f.size.width > NSMinX(vf) + 80.0 && p.x < NSMaxX(vf) - 80.0) {
                CGFloat x = MIN(MAX(p.x, NSMinX(vf) + 4.0), NSMaxX(vf) - f.size.width - 4.0);
                CGFloat y = MIN(MAX(p.y, NSMinY(vf) + 4.0), NSMaxY(vf) - f.size.height - 4.0);
                [_panel setFrameOrigin:NSMakePoint(x, y)];
                restored = YES;
            }
        }
        if (!restored) [self resetPosition];
        NMWLog(@"ready frame=%@", NSStringFromRect(_panel.frame));
    }
    return self;
}

- (WKWebViewConfiguration *)makeConfig {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *uc = [[WKUserContentController alloc] init];
    [uc addScriptMessageHandler:self name:@"niuma"];

    NSString *inject = [NSString stringWithFormat:
        @"window.__NIUMA_STATE__ = %@;\nwindow.__NIUMA_NATIVE__ = true;\n",
        NMWLoadStateJSON()];
    [uc addUserScript:[[WKUserScript alloc] initWithSource:inject
                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                         forMainFrameOnly:YES]];
    cfg.userContentController = uc;

    // 允许 file:// 页面读取同目录资源
    if (@available(macOS 10.15, *)) { }
    return cfg;
}

- (void)styleWebView:(WKWebView *)wv {
    @try {
        [wv setValue:@NO forKey:@"drawsBackground"];
    } @catch (NSException *e) { }
    if (@available(macOS 12.0, *)) {
        wv.underPageBackgroundColor = [NSColor clearColor];
    }
}

- (void)buildPanel {
    NSSize card = NMWCardSize(_kind);
    NSRect rect = NSMakeRect(0, 0, card.width + kPad * 2, card.height + kPad * 2);

    _panel = [[NSPanel alloc] initWithContentRect:rect
                                        styleMask:(NSWindowStyleMaskBorderless |
                                                   NSWindowStyleMaskNonactivatingPanel |
                                                   NSWindowStyleMaskFullSizeContentView)
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    _panel.opaque = NO;
    _panel.backgroundColor = [NSColor clearColor];
    _panel.hasShadow = NO;               // 阴影由 CSS 绘制，避免透明窗口怪影
    _panel.level = NSFloatingWindowLevel;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.hidesOnDeactivate = NO;
    _panel.movableByWindowBackground = NO;
    _panel.acceptsMouseMovedEvents = YES;
    _panel.releasedWhenClosed = NO;

    _web = [[WKWebView alloc] initWithFrame:rect configuration:[self makeConfig]];
    [self styleWebView:_web];
    _web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // ---- 玻璃层：真正的系统级背景磨砂（CSS 的 backdrop-filter 拿不到桌面像素）----
    NSView *host = [[NSView alloc] initWithFrame:rect];
    host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _glass = [[NSVisualEffectView alloc] initWithFrame:rect];
    _glass.material = NSVisualEffectMaterialPopover;
    _glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _glass.state = NSVisualEffectStateActive;
    _glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [host addSubview:_glass];
    [host addSubview:_web];

    _panel.contentView = host;
    [self applyGlassAppearance];
    [self updateGlassMask];

    NSURL *url = NMWAppResource(@"widget.html");
    if (url) {
        [_web loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]];
        NMWLog(@"load %@", url.path);
    } else {
        NMWLog(@"widget.html NOT FOUND in %@", [[NSBundle mainBundle] resourceURL].path);
    }
    [_panel orderFrontRegardless];
    // 上次退出时如果是"已固定"，启动就该直接沉在桌面层，而不是先闪一下浮窗
    {
        NSDictionary *st = NMWLoadStateDict();
        NSDictionary *ui0 = [st[@"ui"] isKindOfClass:[NSDictionary class]] ? st[@"ui"] : nil;
        if ([ui0[@"locked"] isKindOfClass:[NSNumber class]] && [ui0[@"locked"] boolValue]) [self applyLockLayer:YES];
    }
    NMWLog(@"panel frame=%@ visible=%d screen=%@ level=%.0f",
           NSStringFromRect(_panel.frame), _panel.isVisible,
           NSStringFromRect([NSScreen mainScreen].visibleFrame), (double)_panel.level);
}

- (void)applySizeAnimated:(BOOL)animated {
    NSSize card = NMWCardSize(_kind);
    NSSize newSize = NSMakeSize(card.width + kPad * 2, card.height + kPad * 2);
    NSRect f = _panel.frame;
    CGFloat topY = NSMaxY(f);
    f.size = newSize;
    f.origin = NSMakePoint(f.origin.x, topY - newSize.height);
    [_panel setFrame:f display:YES animate:animated];
    [self clampToScreen];
    [self updateGlassMask];
    if (animated) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.34 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf updateGlassMask]; });
    }
}

- (void)clampToScreen {
    NSScreen *screen = _panel.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSRect f = _panel.frame;
    CGFloat x = MIN(MAX(f.origin.x, NSMinX(vf) + 4.0), NSMaxX(vf) - f.size.width - 4.0);
    CGFloat y = MIN(MAX(f.origin.y, NSMinY(vf) + 4.0), NSMaxY(vf) - f.size.height - 4.0);
    if (x != f.origin.x || y != f.origin.y) {
        [_panel setFrameOrigin:NSMakePoint(x, y)];
    }
}

#pragma mark 玻璃

// 遮罩随尺寸/圆角重算，否则磨砂会溢出到阴影边距里
- (void)updateGlassMask {
    if (!_glass) return;
    _glass.maskImage = NMWRoundedMask(_glass.bounds.size, NMWCardRadius(_kind), kPad);
    _glass.needsDisplay = YES;
}

// 日/夜与浓度档共同决定磨砂层
- (void)applyGlassAppearance {
    if (!_glass) return;
    _glass.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    _glass.material = NSVisualEffectMaterialPopover;

    // 透明度的唯一闸门：alpha=1 时材质自身那层纱是实心的，桌面像素透不上来；
    // 降下来窗口才真正带 alpha。三档浓度因此必须落在这里，光靠 CSS 奶膜改不动观感。
    // 代价是低 alpha 会把「未模糊的桌面」一起放进来，锐利边缘会露出来 ——
    // 这一层由 CSS 的 backdrop-filter 在合成结果上再糊一次兜住（见 widget.html .card）。
    CGFloat a;
    // thin 档已经压到很低：磨砂层只剩一层薄雾，壁纸颜色几乎原样透上来。
    // 再低就会看到未模糊的桌面锐边，也不再像"玻璃"而像"半透明贴纸"。
    // Popover 材质本身是「发白的纱」，alpha 越高越像一块灰白塑料片。
    // 用户壁纸就是蓝紫，卡片要的是「纯透明只看得到壁纸」，所以把纱几乎全部撤掉：
    // 颜色全部来自壁纸 + 那点极淡的顶光，材质只负责磨砂（模糊），不负责上色。
    if ([_glassLevel isEqualToString:@"thin"])        a = 0.06;
    else if ([_glassLevel isEqualToString:@"thick"])  a = 0.34;
    else                                              a = 0.12;
    _glass.alphaValue = a;

    _glass.needsDisplay = YES;
}

- (void)setKind:(NMWCardKind)kind {
    _kind = kind;
    [self applySizeAnimated:YES];
    [self persistUIFrame];
}

- (void)resetPosition {
    /* 没有记录位置时（首次启动）固定放到主屏右下，不看鼠标在哪块屏 */
    NSScreen *screen = [NSScreen screens].firstObject ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSRect f = _panel.frame;
    [_panel setFrameOrigin:NSMakePoint(NSMaxX(vf) - f.size.width - 16,
                                       NSMinY(vf) + 16)];
}

- (void)toggleVisible {
    if (_panel.isVisible) [_panel orderOut:nil];
    else [_panel orderFrontRegardless];
}

#pragma mark 锁定层级

/* 固定之后这张卡就不再是"浮窗"，而是桌面上的一块：
   层级压到桌面图标之上、所有普通窗口之下，于是任何 App 窗口都会盖住它。
   顺带解决了"白字压在浅色窗口上必糊"——它底下永远只可能是壁纸。
   解除固定则回到 FloatingWindowLevel，方便拖动和交互。 */
- (void)applyLockLayer:(BOOL)locked {
    NSWindowLevel target = locked
        ? (NSWindowLevel)(kCGDesktopIconWindowLevel + 1)
        : NSFloatingWindowLevel;
    if (_panel.level == target) return;
    _panel.level = target;
    // 层级一变，窗口顺序可能被系统重排，重新抬到本层级最前
    [_panel orderFrontRegardless];
    NMWLog(@"locked=%d level=%d", locked, (int)_panel.level);
}

#pragma mark 拖拽

- (void)startDrag {
    _dragStartMouse = [NSEvent mouseLocation];
    _dragStartOrigin = _panel.frame.origin;
    [_dragTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _dragTimer = [NSTimer timerWithTimeInterval:1.0 / 120.0 repeats:YES block:^(NSTimer *t) {
        [weakSelf followDrag];
    }];
    // 拖拽期间 runloop 处于 eventTracking 模式，必须加入 common modes
    [[NSRunLoop mainRunLoop] addTimer:_dragTimer forMode:NSRunLoopCommonModes];
}

- (void)followDrag {
    NSPoint m = [NSEvent mouseLocation];
    CGFloat nx = _dragStartOrigin.x + (m.x - _dragStartMouse.x);
    CGFloat ny = _dragStartOrigin.y + (m.y - _dragStartMouse.y);

    NSScreen *screen = _panel.screen ?: [NSScreen mainScreen];
    NSRect vf = screen.visibleFrame;
    NSSize sz = _panel.frame.size;
    nx = MIN(MAX(nx, NSMinX(vf) - sz.width + 90.0), NSMaxX(vf) - 90.0);
    ny = MIN(MAX(ny, NSMinY(vf) - sz.height + 90.0), NSMaxY(vf) - 40.0);
    [_panel setFrameOrigin:NSMakePoint(nx, ny)];
}

- (void)endDrag {
    [_dragTimer invalidate];
    _dragTimer = nil;
    [self persistUIFrame];
}

- (void)persistUIFrame {
    NSMutableDictionary *state = NMWLoadStateDict();
    NSMutableDictionary *ui = [state[@"ui"] isKindOfClass:[NSDictionary class]]
        ? [state[@"ui"] mutableCopy] : [NSMutableDictionary dictionary];
    ui[@"cardSize"] = (_kind == NMWCardKindSmall) ? @"small"
                    : (_kind == NMWCardKindLarge) ? @"large" : @"medium";
    ui[@"x"] = @(_panel.frame.origin.x);
    ui[@"y"] = @(_panel.frame.origin.y);
    state[@"ui"] = ui;
    NSData *d = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (d) NMWSaveStateJSON([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
}

#pragma mark 控制台

- (void)openDashboard {
    if (_dashWindow) {
        [_dashWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    NSURL *url = NMWAppResource(@"dashboard.html");
    if (!url) { NMWLog(@"dashboard.html NOT FOUND"); return; }
    NMWLog(@"opening dashboard %@", url.path);

    NSRect rect = NSMakeRect(0, 0, 1020, 780);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:rect
                                             styleMask:(NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable |
                                                        NSWindowStyleMaskResizable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    w.title = @"牛马鼓励器 · 控制台";
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.releasedWhenClosed = NO;
    w.level = NSFloatingWindowLevel;          // macOS 26 上跨应用激活不可靠，靠层级保证可见
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorFullScreenAuxiliary;
    [w center];

    WKWebView *wv = [[WKWebView alloc] initWithFrame:rect configuration:[self makeConfig]];
    [self styleWebView:wv];
    wv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    w.contentView = wv;
    [wv loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]];

    [w makeKeyAndOrderFront:nil];
    [w orderFrontRegardless];
    [NSApp activateIgnoringOtherApps:YES];
    _dashWindow = w;
    _dashWeb = wv;
    NMWLog(@"dashboard window frame=%@ visible=%d", NSStringFromRect(w.frame), w.isVisible);
}

#pragma mark JS 消息

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    NSString *type = [body[@"type"] isKindOfClass:[NSString class]] ? body[@"type"] : nil;
    if (!type) return;

    if (!message.frameInfo.isMainFrame) return;
    if ([type isEqualToString:@"saveConfig"] ||
        [type isEqualToString:@"adjustWater"] ||
        [type isEqualToString:@"setLocked"]) {
        NSMutableDictionary *state = NMWLoadStateDict();
        if ([type isEqualToString:@"saveConfig"]) {
            NSDictionary *data = body[@"data"];
            if (message.webView != _dashWeb || ![data isKindOfClass:[NSDictionary class]] ||
                ![NSJSONSerialization isValidJSONObject:data]) return;
            NSArray *keys = @[@"hourly", @"payUnit", @"payInput", @"start", @"end",
                @"lunchEnabled", @"lunchStart", @"lunchEnd", @"payday", @"offDays",
                @"hue", @"currency", @"milkTea", @"rewardName", @"rewardUnit", @"glass", @"face",
                @"waterGoal", @"cupMl", @"texts", @"quips"];
            for (NSString *key in keys) {
                if (data[key]) state[key] = data[key];
            }
        } else if ([type isEqualToString:@"setLocked"]) {
            if (message.webView != _web || ![body[@"locked"] isKindOfClass:[NSNumber class]]) return;
            NSMutableDictionary *ui = [state[@"ui"] isKindOfClass:[NSDictionary class]]
                ? [state[@"ui"] mutableCopy] : [NSMutableDictionary dictionary];
            ui[@"locked"] = @([body[@"locked"] boolValue]);
            state[@"ui"] = ui;
        } else {
            if (message.webView != _web && message.webView != _dashWeb) return;
            NSNumber *delta = body[@"delta"];
            if (![delta isKindOfClass:[NSNumber class]] ||
                (delta.doubleValue != 1 && delta.doubleValue != -1)) return;
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSDateComponents *day = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
                                                fromDate:[NSDate date]];
            NSString *key = [NSString stringWithFormat:@"%ld-%ld-%ld", (long)day.year, (long)day.month, (long)day.day];
            NSDictionary *water = [state[@"water"] isKindOfClass:[NSDictionary class]] ? state[@"water"] : @{};
            NSMutableDictionary *log = [state[@"waterLog"] isKindOfClass:[NSDictionary class]]
                ? [state[@"waterLog"] mutableCopy] : [NSMutableDictionary dictionary];
            id previous = [key isEqual:water[@"date"]] ? water[@"cups"] : log[key];
            NSInteger count = [previous isKindOfClass:[NSNumber class]] ? [previous integerValue] : 0;
            count = MAX(0, MIN(99, count));
            NSNumber *cups = @(MAX(0, MIN(99, count + delta.integerValue)));
            state[@"water"] = @{@"date": key, @"cups": cups};
            log[key] = cups;
            if (log.count > 180) {
                NSArray *dates = [[log allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                    return [a compare:b options:NSNumericSearch];
                }];
                for (NSString *date in dates) {
                    if (log.count <= 180) break;
                    if (![date isEqual:key]) [log removeObjectForKey:date];
                }
            }
            state[@"waterLog"] = log;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
        if (!data) return;
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NMWSaveStateJSON(json);
        [_web evaluateJavaScript:[NSString stringWithFormat:@"window.NMW && window.NMW.applyExternal(%@)", json]
               completionHandler:nil];
        [_dashWeb evaluateJavaScript:[NSString stringWithFormat:@"window.NMWD && window.NMWD.setStore(%@)", json]
                   completionHandler:nil];

        if ([type isEqualToString:@"saveConfig"]) {
            self.glassLevel = [state[@"glass"] isKindOfClass:[NSString class]] ? state[@"glass"] : @"standard";
            [self applyGlassAppearance];
        } else if ([type isEqualToString:@"setLocked"]) {
            [self applyLockLayer:[body[@"locked"] boolValue]];
        }
    } else if ([type isEqualToString:@"dragBegin"]) {
        [self startDrag];
    } else if ([type isEqualToString:@"dragEnd"]) {
        [self endDrag];
    } else if ([type isEqualToString:@"openDashboard"]) {
        [self openDashboard];
    } else if ([type isEqualToString:@"resize"]) {
        NSString *s = [body[@"size"] isKindOfClass:[NSString class]] ? body[@"size"] : nil;
        if ([s isEqualToString:@"small"]) [self setKind:NMWCardKindSmall];
        else if ([s isEqualToString:@"medium"]) [self setKind:NMWCardKindMedium];
        else if ([s isEqualToString:@"large"]) [self setKind:NMWCardKindLarge];
    } else if ([type isEqualToString:@"themeChanged"]) {
        // 控制台改了主题 → 让小组件按"当前内存里的 state"重绘即可。
        // 注意不能调 reloadFromStore：它读的是 document 启动时注入的 __NIUMA_STATE__ 快照，
        // 是一份旧数据，会把刚刚 save 进来的新色相覆盖回去（表现为换色后组件不变色）。
        [_web evaluateJavaScript:@"window.NMW && window.NMW.repaint()" completionHandler:nil];
    } else if ([type isEqualToString:@"pullState"]) {
        // 控制台每次获得焦点都拉一次真实状态：它的内存副本是启动时的快照，
        // 不刷新的话，之后一保存就会把小组件上刚点的喝水杯数覆盖掉。
        NSDictionary *cur = NMWLoadStateDict();
        NSData *d = [NSJSONSerialization dataWithJSONObject:cur options:0 error:nil];
        NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
        [_dashWeb evaluateJavaScript:[NSString stringWithFormat:@"window.NMWD && window.NMWD.setStore(%@)", json]
                   completionHandler:nil];
    } else if ([type isEqualToString:@"quit"]) {
        [NSApp terminate:nil];
    }
}

@end

#pragma mark - AppDelegate

@interface NMWAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NMWController *controller;
@property (nonatomic, strong) NSStatusItem *statusItem;
@end

@implementation NMWAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.controller = [[NMWController alloc] init];
    [self buildMenu];

    // 支持 `--dashboard` 直接进控制台（延后到 runloop 起来后再开窗）
    // 也支持用哨兵文件触发，方便从 Finder/脚本启动时打开控制台
    NSString *flag = @"/tmp/niuma-open-dashboard";
    BOOL wantDash = [NSProcessInfo.processInfo.arguments containsObject:@"--dashboard"];
    if (!wantDash && [[NSFileManager defaultManager] fileExistsAtPath:flag]) {
        [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
        wantDash = YES;
    }
    if (wantDash) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.controller openDashboard];
        });
    }
}

- (void)buildMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    NSImage *img = [NSImage imageWithSystemSymbolName:@"figure.walk.motion"
                            accessibilityDescription:@"牛马鼓励器"];
    img.template = YES;
    self.statusItem.button.image = img;

    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *show = [[NSMenuItem alloc] initWithTitle:@"显示 / 隐藏小组件"
                                                  action:@selector(toggleWidget)
                                           keyEquivalent:@"w"];
    show.target = self;
    [menu addItem:show];

    NSMenuItem *dash = [[NSMenuItem alloc] initWithTitle:@"打开控制台…"
                                                  action:@selector(openDash)
                                           keyEquivalent:@","];
    dash.target = self;
    [menu addItem:dash];

    [menu addItem:[NSMenuItem separatorItem]];

    NSArray<NSString *> *sizeTitles = @[@"小组件尺寸：小", @"小组件尺寸：中", @"小组件尺寸：大"];
    for (NSInteger i = 0; i < sizeTitles.count; i++) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:sizeTitles[i]
                                                    action:@selector(pickSize:)
                                             keyEquivalent:@""];
        it.tag = i;
        it.target = self;
        it.state = (i == self.controller.kind) ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *reset = [[NSMenuItem alloc] initWithTitle:@"回到右下角"
                                                   action:@selector(resetPos)
                                            keyEquivalent:@""];
    reset.target = self;
    [menu addItem:reset];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出牛马鼓励器"
                                                  action:@selector(quitApp)
                                           keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)toggleWidget { [self.controller toggleVisible]; }
- (void)openDash { [self.controller openDashboard]; }
- (void)quitApp { [NSApp terminate:nil]; }

- (void)resetPos {
    [self.controller resetPosition];
    [self.controller persistUIFrame];
}

- (void)pickSize:(NSMenuItem *)sender {
    [self.controller setKind:(NMWCardKind)sender.tag];
    for (NSMenuItem *it in sender.menu.itemArray) {
        if (it.action == @selector(pickSize:)) {
            it.state = (it.tag == sender.tag) ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self.controller persistUIFrame];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return NO; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NMWAppDelegate *delegate = [[NMWAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
