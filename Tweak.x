#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

@interface YTSingleVideoController : NSObject
- (BOOL)isMuted;
- (void)setMuted:(BOOL)muted;
@end

@interface YTPlayerViewController : UIViewController
- (NSString *)currentVideoID;
- (CGFloat)currentVideoMediaTime;
- (YTSingleVideoController *)activeVideo;
- (id)activeVideoPlayerOverlay;
- (BOOL)isPlayingAd;
@end

@interface MLCaptionSegment : NSObject
- (NSString *)text;
@end

@interface MLCaption : NSObject
- (CGFloat)startTime;
- (CGFloat)endTime;
- (NSArray<MLCaptionSegment *> *)segments;
@end

@interface YTIntervalTree : NSObject
- (void)enumerateAllIntervalsWithBlock:(void (^)(id interval))block;
@end

@interface MLFormat3Captions : NSObject
- (YTIntervalTree *)captions;
@end

#define BT_FORCE_HIDDEN_CAPTIONS 1
#define BT_MAX_WINDOWS 8192

static const NSTimeInterval kBTTick = 0.04;
static const NSTimeInterval kBTRefresh = 2.0;
static const double kBTLead = 0.10;
static const double kBTTail = 0.14;
static const double kBTMinWindow = 0.30;
static const double kBTMaxWindow = 1.15;

typedef struct { double start; double end; } BTWindow;
static BTWindow gWindows[BT_MAX_WINDOWS];
static NSUInteger gWindowCount = 0;
static YTPlayerViewController *gPlayer = nil;
static NSTimer *gTimer = nil;
static NSString *gVideoID = nil;
static NSTimeInterval gLastRefresh = 0;
static NSTimeInterval gLastCaptionAttempt = 0;
static NSUInteger gCaptionAttempts = 0;
static BOOL gBleeping = NO;
static BOOL gWasMuted = NO;
static AVAudioPlayer *gBleepPlayer = nil;

static NSSet<NSString *> *BTProfanity(void) {
    static NSSet<NSString *> *words;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        words = [NSSet setWithArray:@[
            @"fuck", @"fucks", @"fucked", @"fucker", @"fuckers", @"fucking",
            @"motherfucker", @"motherfuckers", @"motherfucking",
            @"shit", @"shits", @"shitty", @"bullshit", @"bullshitting",
            @"bitch", @"bitches", @"bitchy", @"cunt", @"cunts",
            @"asshole", @"assholes", @"arsehole", @"arseholes",
            @"dick", @"dicks", @"dickhead", @"dickheads", @"cock", @"cocks",
            @"prick", @"pricks", @"bastard", @"bastards",
            @"piss", @"pissed", @"pissing", @"wank", @"wanker", @"wankers", @"wanking",
            @"twat", @"twats", @"crap", @"damn", @"damned", @"hell"
        ]];
    });
    return words;
}

static BOOL BTLooksCensored(NSString *token) {
    if (token.length < 2) return NO;
    NSUInteger markers = 0;
    for (NSUInteger i = 0; i < token.length; i++) {
        unichar c = [token characterAtIndex:i];
        if (c == '*' || c == '_') markers++;
    }
    return markers >= 2;
}

static BOOL BTIsProfane(NSString *token) {
    if (!token.length) return NO;
    NSString *lower = token.lowercaseString;
    if ([BTProfanity() containsObject:lower] || BTLooksCensored(lower)) return YES;

    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *clean = [[lower componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@""];
    if ([BTProfanity() containsObject:clean]) return YES;

    if ([lower hasPrefix:@"f"] && [lower containsString:@"*"] && lower.length >= 4) return YES;
    if ([lower hasPrefix:@"sh"] && [lower containsString:@"*"] && lower.length >= 3) return YES;
    return NO;
}

static NSData *BTBleepWAV(void) {
    const int rate = 44100;
    const double seconds = 1.0;
    const int samplesCount = (int)(rate * seconds);
    const int dataBytes = samplesCount * 2;
    const int totalBytes = 44 + dataBytes;
    NSMutableData *data = [NSMutableData dataWithLength:totalBytes];
    uint8_t *b = data.mutableBytes;

    void (^put16)(int, uint16_t) = ^(int o, uint16_t v) {
        b[o] = (uint8_t)(v & 0xff); b[o + 1] = (uint8_t)((v >> 8) & 0xff);
    };
    void (^put32)(int, uint32_t) = ^(int o, uint32_t v) {
        b[o] = (uint8_t)(v & 0xff); b[o + 1] = (uint8_t)((v >> 8) & 0xff);
        b[o + 2] = (uint8_t)((v >> 16) & 0xff); b[o + 3] = (uint8_t)((v >> 24) & 0xff);
    };

    memcpy(b, "RIFF", 4); put32(4, (uint32_t)(totalBytes - 8)); memcpy(b + 8, "WAVE", 4);
    memcpy(b + 12, "fmt ", 4); put32(16, 16); put16(20, 1); put16(22, 1);
    put32(24, rate); put32(28, rate * 2); put16(32, 2); put16(34, 16);
    memcpy(b + 36, "data", 4); put32(40, dataBytes);

    int16_t *samples = (int16_t *)(b + 44);
    for (int i = 0; i < samplesCount; i++) {
        double t = (double)i / rate;
        double edge = fmin(1.0, fmin(t / 0.012, (seconds - t) / 0.020));
        double s = sin(2.0 * M_PI * 1050.0 * t) * 0.38 * fmax(0.0, edge);
        samples[i] = (int16_t)(s * 32767.0);
    }
    return data;
}

static void BTPrepareBleep(void) {
    if (gBleepPlayer) return;
    NSError *error = nil;
    gBleepPlayer = [[AVAudioPlayer alloc] initWithData:BTBleepWAV() error:&error];
    if (gBleepPlayer) {
        gBleepPlayer.volume = 0.85;
        [gBleepPlayer prepareToPlay];
    } else {
        NSLog(@"[BleepTube] Could not prepare bleep: %@", error);
    }
}

static void BTStartBleepSound(void) {
    BTPrepareBleep();
    [gBleepPlayer stop];
    gBleepPlayer.currentTime = 0;
    [gBleepPlayer play];
}

static void BTStopBleepSound(void) {
    [gBleepPlayer stop];
    gBleepPlayer.currentTime = 0;
}

static id BTSafeValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSString *BTCaptionText(MLCaption *caption) {
    NSMutableString *result = [NSMutableString string];
    NSArray *segments = nil;
    @try { segments = [caption segments]; } @catch (__unused NSException *e) {}
    for (id segment in segments) {
        NSString *piece = nil;
        @try { piece = [segment text]; } @catch (__unused NSException *e) {}
        if (piece.length) [result appendString:piece];
    }
    return result;
}

static void BTAddWindow(double start, double end) {
    if (gWindowCount >= BT_MAX_WINDOWS || !isfinite(start) || !isfinite(end) || end <= start) return;
    start = MAX(0, start);
    double duration = end - start;
    if (duration < kBTMinWindow) {
        double mid = (start + end) * 0.5;
        start = MAX(0, mid - kBTMinWindow * 0.5);
        end = mid + kBTMinWindow * 0.5;
    } else if (duration > kBTMaxWindow) {
        double mid = (start + end) * 0.5;
        start = MAX(0, mid - kBTMaxWindow * 0.5);
        end = mid + kBTMaxWindow * 0.5;
    }
    gWindows[gWindowCount++] = (BTWindow){start, end};
}

static int BTCompareWindows(const void *a, const void *b) {
    const BTWindow *wa = a, *wb = b;
    return wa->start < wb->start ? -1 : (wa->start > wb->start ? 1 : 0);
}

static void BTMergeWindows(void) {
    if (gWindowCount < 2) return;
    qsort(gWindows, gWindowCount, sizeof(BTWindow), BTCompareWindows);
    NSUInteger out = 0;
    for (NSUInteger i = 0; i < gWindowCount; i++) {
        if (out == 0 || gWindows[i].start > gWindows[out - 1].end + 0.03) {
            gWindows[out++] = gWindows[i];
        } else {
            gWindows[out - 1].end = MAX(gWindows[out - 1].end, gWindows[i].end);
        }
    }
    gWindowCount = out;
}

static void BTScanCaption(MLCaption *caption) {
    NSString *text = BTCaptionText(caption);
    if (!text.length) return;

    double start = 0, end = 0;
    @try { start = [caption startTime]; end = [caption endTime]; }
    @catch (__unused NSException *e) { return; }
    if (end <= start) return;

    NSString *lower = text.lowercaseString;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{N}_*'’-]+|\\[\\s*[_*]+\\s*\\]" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:lower options:0 range:NSMakeRange(0, lower.length)];
    double duration = end - start;

    for (NSTextCheckingResult *match in matches) {
        NSString *token = [lower substringWithRange:match.range];
        if (!BTIsProfane(token)) continue;
        double relStart = (double)match.range.location / MAX((double)lower.length, 1.0);
        double relEnd = (double)NSMaxRange(match.range) / MAX((double)lower.length, 1.0);
        BTAddWindow(start + duration * relStart - kBTLead,
                    start + duration * relEnd + kBTTail);
    }
}

static id BTCaptionController(YTPlayerViewController *player) {
    id overlay = nil;
    @try { overlay = [player activeVideoPlayerOverlay]; } @catch (__unused NSException *e) {}
    return BTSafeValue(overlay, @"_captionOverlayViewController");
}

static BOOL BTRebuildWindows(YTPlayerViewController *player) {
    gWindowCount = 0;
    id cvc = BTCaptionController(player);
    if (!cvc) return NO;
    id captions = BTSafeValue(cvc, @"_currentCaptions");
    if (!captions) return NO;

#if BT_FORCE_HIDDEN_CAPTIONS
    if ([cvc isKindOfClass:[UIViewController class]]) {
        UIView *view = [(UIViewController *)cvc view];
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
    }
#endif

    YTIntervalTree *tree = nil;
    @try { tree = [captions captions]; } @catch (__unused NSException *e) {}
    if (!tree) return NO;

    @try {
        [tree enumerateAllIntervalsWithBlock:^(id interval) {
            if (gWindowCount < BT_MAX_WINDOWS) BTScanCaption((MLCaption *)interval);
        }];
    } @catch (NSException *e) {
        NSLog(@"[BleepTube] Caption enumeration failed: %@", e);
        gWindowCount = 0;
        return NO;
    }
    BTMergeWindows();
    NSLog(@"[BleepTube] %lu censor windows for %@", (unsigned long)gWindowCount, gVideoID ?: @"<video>");
    return YES;
}

#if BT_FORCE_HIDDEN_CAPTIONS
static BOOL BTCaptionLabel(NSString *s) {
    if (!s.length) return NO;
    NSString *v = s.lowercaseString;
    return [v containsString:@"caption"] || [v containsString:@"subtitle"] || [v isEqualToString:@"cc"];
}

static UIControl *BTFindCC(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UIControl class]] &&
        (BTCaptionLabel(root.accessibilityLabel) || BTCaptionLabel(root.accessibilityIdentifier))) {
        return (UIControl *)root;
    }
    for (UIView *sub in root.subviews) {
        UIControl *found = BTFindCC(sub);
        if (found) return found;
    }
    return nil;
}

static BOOL BTTryLoadCaptions(YTPlayerViewController *player) {
    if (!player || gCaptionAttempts >= 2) return NO;
    id overlay = nil;
    @try { overlay = [player activeVideoPlayerOverlay]; } @catch (__unused NSException *e) {}
    UIView *root = nil;
    if ([overlay isKindOfClass:[UIViewController class]]) root = [(UIViewController *)overlay view];
    else if ([overlay isKindOfClass:[UIView class]]) root = (UIView *)overlay;
    if (!root) root = player.view;

    UIControl *cc = BTFindCC(root);
    if (!cc) return NO;
    gCaptionAttempts++;
    [cc sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSLog(@"[BleepTube] Requested captions, attempt %lu", (unsigned long)gCaptionAttempts);
    return YES;
}
#endif

static BOOL BTInsideWindow(double t) {
    for (NSUInteger i = 0; i < gWindowCount; i++) {
        if (t < gWindows[i].start) return NO;
        if (t <= gWindows[i].end) return YES;
    }
    return NO;
}

static void BTStopAndRestore(void) {
    if (!gBleeping) return;
    YTSingleVideoController *video = nil;
    @try { video = [gPlayer activeVideo]; } @catch (__unused NSException *e) {}
    if (video && !gWasMuted) {
        @try { [video setMuted:NO]; } @catch (__unused NSException *e) {}
    }
    BTStopBleepSound();
    gBleeping = NO;
}

static void BTResetVideo(NSString *videoID) {
    BTStopAndRestore();
    gWindowCount = 0;
    gVideoID = [videoID copy];
    gLastRefresh = 0;
    gLastCaptionAttempt = 0;
    gCaptionAttempts = 0;
}

static void BTTickNow(void) {
    YTPlayerViewController *player = gPlayer;
    if (!player) return;

    NSString *videoID = nil;
    @try { videoID = [player currentVideoID]; } @catch (__unused NSException *e) {}
    if (!videoID.length) return;
    if (!gVideoID || ![gVideoID isEqualToString:videoID]) BTResetVideo(videoID);

    BOOL ad = NO;
    @try { ad = [player isPlayingAd]; } @catch (__unused NSException *e) {}
    if (ad) { BTStopAndRestore(); return; }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastRefresh >= kBTRefresh) {
        BOOL gotCaptions = BTRebuildWindows(player);
        gLastRefresh = now;
#if BT_FORCE_HIDDEN_CAPTIONS
        if (!gotCaptions && now - gLastCaptionAttempt >= 2.5) {
            if (BTTryLoadCaptions(player)) gLastCaptionAttempt = now;
        }
#endif
    }

    double t = 0;
    @try { t = [player currentVideoMediaTime]; } @catch (__unused NSException *e) { return; }
    BOOL shouldBleep = BTInsideWindow(t);

    YTSingleVideoController *video = nil;
    @try { video = [player activeVideo]; } @catch (__unused NSException *e) {}
    if (!video) return;

    if (shouldBleep && !gBleeping) {
        @try { gWasMuted = [video isMuted]; } @catch (__unused NSException *e) { gWasMuted = NO; }
        @try { [video setMuted:YES]; } @catch (__unused NSException *e) {}
        BTStartBleepSound();
        gBleeping = YES;
    } else if (!shouldBleep && gBleeping) {
        BTStopAndRestore();
    }
}

static void BTEnsureTimer(void) {
    if (gTimer) return;
    gTimer = [NSTimer timerWithTimeInterval:kBTTick repeats:YES block:^(__unused NSTimer *timer) {
        @autoreleasepool { BTTickNow(); }
    }];
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    gPlayer = self;
    BTEnsureTimer();
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gPlayer = self;
    BTEnsureTimer();
}

%end

%hook YTReelPlayerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    id p = BTSafeValue(self, @"_player");
    if (!p) p = BTSafeValue(self, @"player");
    if ([p isKindOfClass:%c(YTPlayerViewController)]) {
        gPlayer = (YTPlayerViewController *)p;
        BTEnsureTimer();
    }
}

%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        BTPrepareBleep();
        BTEnsureTimer();
        NSLog(@"[BleepTube] Loaded");
    });
}
