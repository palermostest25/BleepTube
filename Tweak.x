#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
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

#define BT_FORCE_HIDDEN_CAPTIONS 1
#define BT_MAX_WINDOWS 8192

static const NSTimeInterval kBTTick = 0.025;
static const NSTimeInterval kBTLegacyRefresh = 2.0;
static const NSTimeInterval kBTJSONRetry = 2.5;
static const double kBTLead = 0.085;
static const double kBTTail = 0.060;
static const double kBTMinWindow = 0.24;
static const double kBTMaxWindow = 1.10;

typedef struct { double start; double end; } BTWindow;

static BTWindow gWindows[BT_MAX_WINDOWS];
static NSUInteger gWindowCount = 0;
static YTPlayerViewController *gPlayer = nil;
static NSTimer *gTimer = nil;
static NSString *gVideoID = nil;

static NSTimeInterval gLastLegacyRefresh = 0;
static NSTimeInterval gLastJSONAttempt = 0;
static NSTimeInterval gLastCaptionAttempt = 0;
static NSUInteger gCaptionAttempts = 0;

static BOOL gJSONFetchInFlight = NO;
static BOOL gJSONReady = NO;
static BOOL gBleeping = NO;
static BOOL gWasMuted = NO;
static AVAudioPlayer *gBleepPlayer = nil;

static NSRegularExpression *BTTokenRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{N}_*'’-]+|\\[\\s*[_*]+\\s*\\]"
                                                          options:0
                                                            error:nil];
    });
    return regex;
}

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

static void BTClearWindows(void) {
    gWindowCount = 0;
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
        if (out == 0 || gWindows[i].start > gWindows[out - 1].end + 0.025) {
            gWindows[out++] = gWindows[i];
        } else {
            gWindows[out - 1].end = MAX(gWindows[out - 1].end, gWindows[i].end);
        }
    }
    gWindowCount = out;
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

static void BTScanLegacyCaption(MLCaption *caption) {
    NSString *text = BTCaptionText(caption);
    if (!text.length) return;

    double start = 0, end = 0;
    @try { start = [caption startTime]; end = [caption endTime]; }
    @catch (__unused NSException *e) { return; }
    if (end <= start) return;

    NSString *lower = text.lowercaseString;
    NSArray<NSTextCheckingResult *> *matches = [BTTokenRegex() matchesInString:lower options:0 range:NSMakeRange(0, lower.length)];
    double duration = end - start;

    for (NSTextCheckingResult *match in matches) {
        NSString *token = [lower substringWithRange:match.range];
        if (!BTIsProfane(token)) continue;

        double relStart = (double)match.range.location / MAX((double)lower.length, 1.0);
        double relEnd = (double)NSMaxRange(match.range) / MAX((double)lower.length, 1.0);
        BTAddWindow(start + duration * relStart - 0.12,
                    start + duration * relEnd + 0.14);
    }
}

static id BTCaptionController(YTPlayerViewController *player) {
    id overlay = nil;
    @try { overlay = [player activeVideoPlayerOverlay]; } @catch (__unused NSException *e) {}
    return BTSafeValue(overlay, @"_captionOverlayViewController");
}

static BOOL BTRebuildLegacyWindows(YTPlayerViewController *player) {
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

    id tree = nil;
    @try { tree = [captions valueForKey:@"captions"]; } @catch (__unused NSException *e) {}
    if (!tree || ![tree respondsToSelector:@selector(enumerateAllIntervalsWithBlock:)]) return NO;

    BTClearWindows();
    @try {
        [(YTIntervalTree *)tree enumerateAllIntervalsWithBlock:^(id interval) {
            if (gWindowCount < BT_MAX_WINDOWS) BTScanLegacyCaption((MLCaption *)interval);
        }];
    } @catch (NSException *e) {
        NSLog(@"[BleepTube] Legacy caption enumeration failed: %@", e);
        BTClearWindows();
        return NO;
    }
    BTMergeWindows();
    return YES;
}

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
#if !BT_FORCE_HIDDEN_CAPTIONS
    return NO;
#else
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
#endif
}

static BOOL BTStringLooksLikeTimedTextURL(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 16) return NO;
    NSString *lower = s.lowercaseString;
    return ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) &&
           ([lower containsString:@"timedtext"] ||
            ([lower containsString:@"youtube"] && [lower containsString:@"lang="] && [lower containsString:@"v="]));
}

static NSString *BTNormalizeURLString(NSString *s) {
    if (!s.length) return nil;
    NSString *v = [s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    v = [v stringByReplacingOccurrencesOfString:@"\\u0026" withString:@"&"];
    return v;
}

static NSString *BTFindURLInDescription(id obj) {
    NSString *desc = nil;
    @try { desc = [obj description]; } @catch (__unused NSException *e) {}
    if (!desc.length) return nil;

    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\\\"'<>]+"
                                                                        options:0
                                                                          error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:desc options:0 range:NSMakeRange(0, desc.length)]) {
        NSString *candidate = BTNormalizeURLString([desc substringWithRange:m.range]);
        if (BTStringLooksLikeTimedTextURL(candidate)) return candidate;
    }
    return nil;
}

static NSString *BTFindTimedTextURLRecursive(id obj, int depth, NSMutableSet<NSValue *> *visited) {
    if (!obj || depth < 0) return nil;

    if ([obj isKindOfClass:[NSURL class]]) {
        NSString *s = [(NSURL *)obj absoluteString];
        return BTStringLooksLikeTimedTextURL(s) ? BTNormalizeURLString(s) : nil;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        return BTStringLooksLikeTimedTextURL(s) ? BTNormalizeURLString(s) : nil;
    }

    NSValue *pointerKey = [NSValue valueWithPointer:(__bridge const void *)(obj)];
    if ([visited containsObject:pointerKey]) return nil;
    [visited addObject:pointerKey];

    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)obj allValues]) {
            NSString *found = BTFindTimedTextURLRecursive(value, depth - 1, visited);
            if (found) return found;
        }
        return nil;
    }

    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        for (id value in obj) {
            NSString *found = BTFindTimedTextURLRecursive(value, depth - 1, visited);
            if (found) return found;
        }
        return nil;
    }

    for (NSString *key in @[@"baseUrl", @"baseURL", @"url", @"URL", @"captionUrl", @"captionURL",
                             @"timedTextUrl", @"timedTextURL", @"trackUrl", @"trackURL"]) {
        id value = BTSafeValue(obj, key);
        if (value) {
            NSString *found = BTFindTimedTextURLRecursive(value, depth - 1, visited);
            if (found) return found;
        }
    }

    if (depth == 0) return BTFindURLInDescription(obj);

    Class cls = [obj class];
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(obj, ivar); } @catch (__unused NSException *e) {}
            if (!value) continue;
            NSString *found = BTFindTimedTextURLRecursive(value, depth - 1, visited);
            if (found) {
                free(ivars);
                return found;
            }
        }
        free(ivars);
    }

    return BTFindURLInDescription(obj);
}

static id BTActiveCaptionTrack(YTPlayerViewController *player) {
    id video = nil;
    @try { video = [player activeVideo]; } @catch (__unused NSException *e) {}
    if (!video) return nil;

    id item = BTSafeValue(video, @"playerItem");
    if (!item) item = BTSafeValue(video, @"_playerItem");
    if (!item) return nil;

    id track = BTSafeValue(item, @"activeCaptionTrack");
    if (track) return track;

    id controller = BTSafeValue(item, @"captionController");
    track = BTSafeValue(controller, @"activeCaptionTrack");
    if (!track) track = BTSafeValue(controller, @"selectedCaptionTrack");
    return track;
}

static NSString *BTCurrentTimedTextURL(YTPlayerViewController *player) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    id track = BTActiveCaptionTrack(player);
    NSString *url = BTFindTimedTextURLRecursive(track, 6, visited);
    if (url) return url;

    id video = nil;
    @try { video = [player activeVideo]; } @catch (__unused NSException *e) {}
    id item = BTSafeValue(video, @"playerItem");
    if (!item) item = BTSafeValue(video, @"_playerItem");
    if (item) {
        [visited removeAllObjects];
        url = BTFindTimedTextURLRecursive(BTSafeValue(item, @"captionController"), 5, visited);
        if (url) return url;

        [visited removeAllObjects];
        url = BTFindTimedTextURLRecursive(item, 4, visited);
        if (url) return url;
    }

    return nil;
}

static NSURL *BTJSON3URLFromString(NSString *urlString) {
    if (!urlString.length) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    if (!components) return [NSURL URLWithString:urlString];

    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if (![item.name.lowercaseString isEqualToString:@"fmt"]) [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    return components.URL;
}

static BOOL BTStringContainsProfanity(NSString *text, NSArray<NSTextCheckingResult *> **matchesOut) {
    if (!text.length) return NO;
    NSString *lower = text.lowercaseString;
    NSArray<NSTextCheckingResult *> *matches = [BTTokenRegex() matchesInString:lower
                                                                        options:0
                                                                          range:NSMakeRange(0, lower.length)];
    if (matchesOut) *matchesOut = matches;
    for (NSTextCheckingResult *m in matches) {
        if (BTIsProfane([lower substringWithRange:m.range])) return YES;
    }
    return NO;
}

static void BTAddEstimatedTextWindows(NSString *text, double start, double end) {
    if (!text.length || end <= start) return;
    NSString *lower = text.lowercaseString;
    NSArray<NSTextCheckingResult *> *matches = [BTTokenRegex() matchesInString:lower options:0 range:NSMakeRange(0, lower.length)];
    double duration = end - start;

    for (NSTextCheckingResult *match in matches) {
        NSString *token = [lower substringWithRange:match.range];
        if (!BTIsProfane(token)) continue;

        double relStart = (double)match.range.location / MAX((double)lower.length, 1.0);
        double relEnd = (double)NSMaxRange(match.range) / MAX((double)lower.length, 1.0);
        BTAddWindow(start + duration * relStart - 0.10,
                    start + duration * relEnd + 0.12);
    }
}

static BOOL BTParseJSON3(NSData *data, NSUInteger *preciseOut, NSUInteger *estimatedOut) {
    if (!data.length) return NO;

    NSError *error = nil;
    id rootObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![rootObj isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[BleepTube] JSON3 parse failed: %@", error);
        return NO;
    }

    NSArray *events = rootObj[@"events"];
    if (![events isKindOfClass:[NSArray class]]) return NO;

    BTClearWindows();
    NSUInteger precise = 0;
    NSUInteger estimated = 0;
    BOOL sawCaptionEvent = NO;

    for (NSDictionary *event in events) {
        if (![event isKindOfClass:[NSDictionary class]]) continue;

        NSNumber *startNum = event[@"tStartMs"];
        NSArray *segs = event[@"segs"];
        if (![startNum isKindOfClass:[NSNumber class]] || ![segs isKindOfClass:[NSArray class]] || segs.count == 0) continue;

        sawCaptionEvent = YES;
        double eventStart = startNum.doubleValue / 1000.0;
        double eventDuration = [event[@"dDurationMs"] respondsToSelector:@selector(doubleValue)] ?
                               [event[@"dDurationMs"] doubleValue] / 1000.0 : 2.0;
        eventDuration = MAX(eventDuration, 0.20);
        double eventEnd = eventStart + eventDuration;

        BOOL hasOffsets = NO;
        for (NSDictionary *seg in segs) {
            if ([seg isKindOfClass:[NSDictionary class]] && [seg[@"tOffsetMs"] isKindOfClass:[NSNumber class]]) {
                hasOffsets = YES;
                break;
            }
        }

        if (!hasOffsets) {
            NSMutableString *whole = [NSMutableString string];
            for (NSDictionary *seg in segs) {
                NSString *utf8 = [seg isKindOfClass:[NSDictionary class]] ? seg[@"utf8"] : nil;
                if ([utf8 isKindOfClass:[NSString class]]) [whole appendString:utf8];
            }
            if (BTStringContainsProfanity(whole, NULL)) {
                NSUInteger before = gWindowCount;
                BTAddEstimatedTextWindows(whole, eventStart, eventEnd);
                estimated += (gWindowCount - before);
            }
            continue;
        }

        for (NSUInteger i = 0; i < segs.count; i++) {
            NSDictionary *seg = [segs[i] isKindOfClass:[NSDictionary class]] ? segs[i] : nil;
            NSString *utf8 = [seg[@"utf8"] isKindOfClass:[NSString class]] ? seg[@"utf8"] : nil;
            NSNumber *offsetNum = [seg[@"tOffsetMs"] isKindOfClass:[NSNumber class]] ? seg[@"tOffsetMs"] : nil;
            if (!utf8.length || !offsetNum) continue;

            NSArray<NSTextCheckingResult *> *tokenMatches = nil;
            if (!BTStringContainsProfanity(utf8, &tokenMatches)) continue;

            double segStart = eventStart + offsetNum.doubleValue / 1000.0;
            double segEnd = eventEnd;

            for (NSUInteger j = i + 1; j < segs.count; j++) {
                NSDictionary *nextSeg = [segs[j] isKindOfClass:[NSDictionary class]] ? segs[j] : nil;
                NSNumber *nextOffset = [nextSeg[@"tOffsetMs"] isKindOfClass:[NSNumber class]] ? nextSeg[@"tOffsetMs"] : nil;
                if (nextOffset) {
                    segEnd = eventStart + nextOffset.doubleValue / 1000.0;
                    break;
                }
            }
            if (segEnd <= segStart) segEnd = segStart + 0.45;

            NSString *lower = utf8.lowercaseString;
            NSUInteger lexicalCount = tokenMatches.count;

            for (NSTextCheckingResult *match in tokenMatches) {
                NSString *token = [lower substringWithRange:match.range];
                if (!BTIsProfane(token)) continue;

                if (lexicalCount <= 1) {
                    BTAddWindow(segStart - kBTLead, segEnd + kBTTail);
                    precise++;
                } else {
                    double duration = MAX(segEnd - segStart, 0.24);
                    double relStart = (double)match.range.location / MAX((double)lower.length, 1.0);
                    double relEnd = (double)NSMaxRange(match.range) / MAX((double)lower.length, 1.0);
                    BTAddWindow(segStart + duration * relStart - 0.08,
                                segStart + duration * relEnd + 0.10);
                    estimated++;
                }
            }
        }
    }

    BTMergeWindows();
    if (preciseOut) *preciseOut = precise;
    if (estimatedOut) *estimatedOut = estimated;

    return sawCaptionEvent;
}

static BOOL BTTryFetchJSON3(YTPlayerViewController *player) {
    if (!player || gJSONFetchInFlight || gJSONReady) return NO;

    NSString *urlString = BTCurrentTimedTextURL(player);
    if (!urlString.length) return NO;

    NSURL *url = BTJSON3URLFromString(urlString);
    if (!url) return NO;

    NSString *requestVideoID = [gVideoID copy];
    gJSONFetchInFlight = YES;
    NSLog(@"[BleepTube] Fetching JSON3 word timing");

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:8.0];
    [request setValue:@"application/json,text/plain,*/*" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gJSONFetchInFlight = NO;
            if (!requestVideoID.length || ![requestVideoID isEqualToString:gVideoID]) return;

            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (error || (http && http.statusCode >= 400)) {
                NSLog(@"[BleepTube] JSON3 fetch failed: %@ status=%ld", error, (long)http.statusCode);
                return;
            }

            NSUInteger precise = 0, estimated = 0;
            if (BTParseJSON3(data, &precise, &estimated)) {
                gJSONReady = YES;
                NSLog(@"[BleepTube] JSON3 ready: %lu precise, %lu estimated censor windows",
                      (unsigned long)precise, (unsigned long)estimated);
            } else {
                NSLog(@"[BleepTube] Response was not usable JSON3");
            }
        });
    }];
    [task resume];
    return YES;
}

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
    BTClearWindows();
    gVideoID = [videoID copy];
    gLastLegacyRefresh = 0;
    gLastJSONAttempt = 0;
    gLastCaptionAttempt = 0;
    gCaptionAttempts = 0;
    gJSONFetchInFlight = NO;
    gJSONReady = NO;
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

    if (!gJSONReady && !gJSONFetchInFlight && now - gLastJSONAttempt >= kBTJSONRetry) {
        gLastJSONAttempt = now;
        BTTryFetchJSON3(player);
    }

    if (!gJSONReady && now - gLastLegacyRefresh >= kBTLegacyRefresh) {
        BOOL gotLegacy = BTRebuildLegacyWindows(player);
        gLastLegacyRefresh = now;

#if BT_FORCE_HIDDEN_CAPTIONS
        if (!gotLegacy && now - gLastCaptionAttempt >= 2.5) {
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
        NSLog(@"[BleepTube] Loaded word-timing build");
    });
}
