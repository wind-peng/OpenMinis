// PhoneControlBridge.m — "eyes + hands" for the Minis agent, ported from MiniPaw
// v1.0.2 (which was ported from PhoneAgent v56). Function bodies are kept as
// close to the MiniPaw originals as possible; only the app-specific wiring
// (no HTTP API, no token, port 8310, no UI of its own) is different.
// Rules carried over from PhoneAgent/MiniPaw:
//  - While the broadcast is alive, ONLY broadcast frames may be used for
//    screenshots — the private IOSurface methods together with ReplayKit can
//    crash a system process.
//  - Text input is clipboard paste, never per-character typing.
//  - Vision OCR is pinned to Revision 1 / Fast: Revision 3 crashes on iOS 16.1
//    ("Semaphore object deallocated while in use").
//  - loadHID/loadShot MUST be called at startup (v1.0.2 lesson: a NULL gClient
//    makes the first tap call a NULL function pointer and crash the app).

#import "PhoneControlBridge.h"
#import "PhoneControlShared.h"
#import <Vision/Vision.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <signal.h>
#import <mach/mach.h>
#import <ReplayKit/ReplayKit.h>

#define MODEL_W 780
#define MODEL_H 1688

static void addLog(NSString *m);
static NSString *loadHID(void);
static NSString *loadShot(void);
static BOOL agPasteText(NSString *text, double x, double y, NSString *backHint, NSString **note);
static void doLongPress(double x, double y, int ms);
static NSString *bundleForAppName(NSString *name, NSString **info);

#pragma mark - 触摸注入 (IOHID)

typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;

static IOHIDEventSystemClientRef (*pClientCreate)(CFAllocatorRef);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventRef (*pCreateDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                         uint32_t, uint32_t, double, double, double, double, double,
                                         Boolean, Boolean, uint32_t);
static IOHIDEventRef (*pCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                      double, double, double, double, double,
                                      Boolean, Boolean, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int64_t);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pSetFloat)(IOHIDEventRef, uint32_t, double);
static IOHIDEventRef (*pCreateKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
static IOHIDEventSystemClientRef gClient;
static int gSwipeMode = 0; // 0 基础;1 +触点半径;2 +半径且移动事件带 Touch;3 +半径、慢速并在起止停顿;4 = 3 + 移动事件带 Range|Touch

static NSString *loadHID(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return @"dlopen IOKit 失败";
#define LOAD(var, name) var = dlsym(h, name); if (!var) return @"缺少符号 " name;
    LOAD(pClientCreate, "IOHIDEventSystemClientCreate")
    LOAD(pDispatch, "IOHIDEventSystemClientDispatchEvent")
    LOAD(pCreateDigitizer, "IOHIDEventCreateDigitizerEvent")
    LOAD(pCreateFinger, "IOHIDEventCreateDigitizerFingerEvent")
    LOAD(pAppend, "IOHIDEventAppendEvent")
    LOAD(pSetInt, "IOHIDEventSetIntegerValue")
    LOAD(pSetSender, "IOHIDEventSetSenderID")
    pSetFloat = dlsym(h, "IOHIDEventSetFloatValue");           // 可选
    pCreateKeyboard = dlsym(h, "IOHIDEventCreateKeyboardEvent"); // 可选(Home 键用)
    gClient = pClientCreate(kCFAllocatorDefault);
    if (!gClient) return @"IOHIDEventSystemClientCreate 返回空";
    return nil;
}

BOOL PCHIDReady(void) { return gClient != NULL; }

// phase: 0=按下 1=移动 2=抬起;nx/ny 是 0~1 的归一化坐标
static void sendFinger(double nx, double ny, int phase) {
    uint64_t t = mach_absolute_time();
    BOOL touching = (phase != 2);
    uint32_t mask = (phase == 1) ? 0x4 : 0x3;
    if (phase == 1) { if (gSwipeMode == 2) mask = 0x6; else if (gSwipeMode == 4) mask = 0x7; }
    IOHIDEventRef hand = pCreateDigitizer(kCFAllocatorDefault, t, 3, 0, 0, mask, 0,
                                          nx, ny, 0, 0, 0, touching, touching, 0);
    pSetInt(hand, 0xb0019, 1);
    IOHIDEventRef finger = pCreateFinger(kCFAllocatorDefault, t, 1, 2, mask, nx, ny, 0,
                                         touching ? 1.0 : 0.0, 0, touching, touching, 0);
    if (gSwipeMode >= 1 && pSetFloat) { pSetFloat(finger, 0xb0014, 0.04); pSetFloat(finger, 0xb0015, 0.04); } // 触点半径
    pAppend(hand, finger, 0);
    CFRelease(finger);
    pSetSender(hand, 0x8000000817319372ULL);
    pDispatch(gClient, hand);
    CFRelease(hand);
}

static CGSize screenSize(void) { return UIScreen.mainScreen.bounds.size; } // pt

static void doTap(double x, double y) {
    CGSize s = screenSize();
    sendFinger(x / s.width, y / s.height, 0);
    usleep(60 * 1000);
    sendFinger(x / s.width, y / s.height, 2);
}

static void doSwipe(double x1, double y1, double x2, double y2, int steps, int ms) {
    CGSize s = screenSize();
    if (gSwipeMode >= 3) { if (steps < 40) steps = 40; if (ms < 700) ms = 700; }
    if (steps < 2) steps = 2;
    sendFinger(x1 / s.width, y1 / s.height, 0);
    if (gSwipeMode >= 3) usleep(80 * 1000);
    for (int i = 1; i <= steps; i++) {
        double k = (double)i / steps;
        usleep(ms * 1000 / steps);
        sendFinger((x1 + (x2 - x1) * k) / s.width, (y1 + (y2 - y1) * k) / s.height, 1);
    }
    if (gSwipeMode >= 3) usleep(80 * 1000);
    sendFinger(x2 / s.width, y2 / s.height, 2);
}

// 硬件键盘快捷键:按住左 Command(0xE3)+ 一个字母键(键盘页 0x07):A=0x04,V=0x19
static BOOL doCmdKey(uint32_t usage) {
    if (!pCreateKeyboard || !gClient) return NO;
    uint32_t seq[4][2] = {{0xE3, 1}, {usage, 1}, {usage, 0}, {0xE3, 0}};
    for (int i = 0; i < 4; i++) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x07, seq[i][0], seq[i][1] ? true : false, 0);
        if (!e) return NO;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(60 * 1000);
    }
    return YES;
}

// 发一对"按下/抬起"键盘事件(无修饰键)
static BOOL sendRawKey(uint32_t usage) {
    if (!pCreateKeyboard || !gClient) return NO;
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x07, usage, down ? true : false, 0);
        if (!e) return NO;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(60 * 1000);
    }
    return YES;
}

// 用 HID 的"Home 键"(消费者页 Menu)回主屏幕;返回是否发出了事件
static BOOL doHomeKey(void) {
    if (!pCreateKeyboard || !gClient) return NO;
    for (int down = 1; down >= 0; down--) {
        IOHIDEventRef e = pCreateKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x0C, 0x40, down ? true : false, 0);
        if (!e) return NO;
        pSetSender(e, 0x8000000817319372ULL);
        pDispatch(gClient, e);
        CFRelease(e);
        usleep(80 * 1000);
    }
    return YES;
}

static void doLongPress(double x, double y, int ms) {
    CGSize s = screenSize();
    sendFinger(x / s.width, y / s.height, 0);
    usleep(ms * 1000);
    sendFinger(x / s.width, y / s.height, 2);
}

// 模型坐标(780x1688)换算成屏幕 pt;超范围(>780+20 或 >1688+20)拒绝,返回 NO
static BOOL modelToPt(double mx, double my, double *outX, double *outY) {
    if (mx < -20 || mx > MODEL_W + 20 || my < -20 || my > MODEL_H + 20) return NO;
    if (mx < 0) mx = 0; if (mx > MODEL_W) mx = MODEL_W;
    if (my < 0) my = 0; if (my > MODEL_H) my = MODEL_H;
    CGSize s = screenSize();
    *outX = mx * s.width / MODEL_W;
    *outY = my * s.height / MODEL_H;
    return YES;
}

#pragma mark - 截屏(多种方法依次尝试,并记录每种的结果)

static void (*pCARender)(uint32_t, CFStringRef, void *, int, int);
static void *(*pSurfCreate)(CFDictionaryRef);
static int (*pSurfLock)(void *, uint32_t, uint32_t *);
static int (*pSurfUnlock)(void *, uint32_t, uint32_t *);
static void *(*pSurfBase)(void *);
static size_t (*pSurfRowBytes)(void *);
static size_t (*pSurfW)(void *);
static size_t (*pSurfH)(void *);
static CGImageRef (*pUIGetScreenImage)(void);
static NSString *gShotMethod = @"";

static NSString *loadShot(void) {
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    void *is = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!qc || !is) return @"dlopen QuartzCore/IOSurface 失败";
#define LOADQ(var, h, name) var = dlsym(h, name); if (!var) return @"缺少符号 " name;
    LOADQ(pCARender, qc, "CARenderServerRenderDisplay")
    LOADQ(pSurfCreate, is, "IOSurfaceCreate")
    LOADQ(pSurfLock, is, "IOSurfaceLock")
    LOADQ(pSurfUnlock, is, "IOSurfaceUnlock")
    LOADQ(pSurfBase, is, "IOSurfaceGetBaseAddress")
    LOADQ(pSurfRowBytes, is, "IOSurfaceGetBytesPerRow")
    LOADQ(pSurfW, is, "IOSurfaceGetWidth")
    LOADQ(pSurfH, is, "IOSurfaceGetHeight")
    pUIGetScreenImage = dlsym(RTLD_DEFAULT, "UIGetScreenImage"); // 可能不存在,不算失败
    return nil;
}

// 把 BGRA 的 IOSurface 拷出来做成 UIImage;note 写失败原因
static UIImage *imageFromSurface(void *surf, NSString **note) {
    pSurfLock(surf, 1, NULL);
    size_t w = pSurfW(surf), h = pSurfH(surf), rb = pSurfRowBytes(surf);
    uint8_t *base = pSurfBase(surf);
    if (!base || !w || !h || !rb) {
        pSurfUnlock(surf, 1, NULL);
        if (note) *note = [NSString stringWithFormat:@"surface 无效(%zux%zu rb=%zu)", w, h, rb];
        return nil;
    }
    NSData *data = [NSData dataWithBytes:base length:rb * h];
    pSurfUnlock(surf, 1, NULL);
    const uint8_t *bytes = data.bytes;
    BOOL allZero = YES;
    for (int i = 0; i < 600 && allZero; i++) {
        size_t off = (((size_t)i * 7919) % (w * h)) * 4;
        size_t row = off / (w * 4), col = (off % (w * 4));
        size_t o = row * rb + col;
        if (bytes[o] || bytes[o + 1] || bytes[o + 2]) allZero = NO;
    }
    if (allZero) { if (note) *note = @"画面全黑"; return nil; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef cg = CGImageCreate(w, h, 8, 32, rb, cs,
                                  kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                  dp, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(dp);
    if (!cg) { if (note) *note = @"CGImageCreate 失败"; return nil; }
    UIImage *img = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

// 方法 A: +[UIWindow createScreenIOSurface]
static UIImage *shotA(NSString **note) {
    SEL sel = NSSelectorFromString(@"createScreenIOSurface");
    if (![UIWindow respondsToSelector:sel]) { *note = @"UIWindow 没有 createScreenIOSurface"; return nil; }
    void *surf = ((void *(*)(id, SEL))objc_msgSend)(UIWindow.class, sel);
    if (!surf) { *note = @"createScreenIOSurface 返回空"; return nil; }
    UIImage *img = imageFromSurface(surf, note);
    CFRelease(surf);
    return img;
}

// 方法 B: UIGetScreenImage()
static UIImage *shotB(NSString **note) {
    if (!pUIGetScreenImage) { *note = @"没有 UIGetScreenImage 符号"; return nil; }
    CGImageRef cg = pUIGetScreenImage();
    if (!cg) { *note = @"UIGetScreenImage 返回空"; return nil; }
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

// 方法 C: 自己 IOSurfaceCreate,再让 CARenderServer 渲染进去
static UIImage *shotC(NSString **note) {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    size_t w = (size_t)px.width, h = (size_t)px.height;
    size_t bpr = ((w * 4) + 63) & ~(size_t)63;
    NSDictionary *full = @{@"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
                           @"IOSurfaceBytesPerElement": @4, @"IOSurfaceBytesPerRow": @(bpr),
                           @"IOSurfacePixelFormat": @(0x42475241), @"IOSurfaceAllocSize": @(bpr * h)};
    void *surf = pSurfCreate((__bridge CFDictionaryRef)full);
    if (!surf) { *note = @"IOSurfaceCreate 失败"; return nil; }
    pCARender(0, CFSTR("LCD"), surf, 0, 0);
    UIImage *img = imageFromSurface(surf, note);
    CFRelease(surf);
    return img;
}

// 方法 D: 用 CVPixelBuffer 创建带 IOSurface 的缓冲,再让 CARenderServer 渲染进去
static UIImage *shotD(NSString **note) {
    CGSize px = UIScreen.mainScreen.nativeBounds.size;
    size_t w = (size_t)px.width, h = (size_t)px.height;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &pb);
    if (r != kCVReturnSuccess || !pb) { *note = [NSString stringWithFormat:@"CVPixelBufferCreate 失败(%d)", (int)r]; return nil; }
    void *surf = (void *)CVPixelBufferGetIOSurface(pb);
    if (!surf) { CVPixelBufferRelease(pb); *note = @"CVPixelBuffer 没有 IOSurface"; return nil; }
    pCARender(0, CFSTR("LCD"), surf, 0, 0);
    UIImage *img = imageFromSurface(surf, note);
    CVPixelBufferRelease(pb);
    return img;
}

// 广播帧缓存(由 ReplayKit 扩展经 /frame 推送)
static NSObject *gLock;
static NSData *gFrame, *gNV12;
static uint32_t gNW, gNH, gNFmt;
static int gExtIS = -2;
static CFAbsoluteTime gFrameT, gHbT;
static NSMutableArray *gLog;             // 最近的日志,最多 50 条
static volatile BOOL gBroadcastStopRequested; // 任务结束时请扩展关闭录屏
static NSString *gLastApp;               // 最近一次成功打开的 App(/open 记录;写剪贴板后回到它用)

BOOL PCBroadcastAlive(void) {
    @synchronized (gLock) { return gHbT > 0 && CFAbsoluteTimeGetCurrent() - gHbT < 6; }
}

// 方法 R: 用 ReplayKit 广播扩展送来的最新一帧
static UIImage *shotR(NSString **note) {
    NSData *d; CFAbsoluteTime hb;
    @synchronized (gLock) { d = gFrame; hb = gHbT; }
    if (!d) { *note = @"还没收到广播画面(广播没开?)"; return nil; }
    if (hb <= 0 || CFAbsoluteTimeGetCurrent() - hb > 6) { *note = @"广播已停止"; return nil; }
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL);
    if (!src) { *note = @"广播 JPEG 解码器创建失败"; return nil; }
    NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    NSNumber *w = props[(NSString *)kCGImagePropertyPixelWidth];
    NSNumber *h = props[(NSString *)kCGImagePropertyPixelHeight];
    if (!w || !h || w.unsignedIntegerValue == 0 || h.unsignedIntegerValue == 0 ||
        w.unsignedIntegerValue > 8192 || h.unsignedIntegerValue > 8192) {
        CFRelease(src);
        *note = @"广播 JPEG 尺寸无效";
        return nil;
    }
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) { *note = @"广播帧解码失败"; return nil; }
    UIImage *img = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

// 依次尝试 R→A→B→C→D;全部失败时 err 里列出每种方法的原因
static UIImage *takeScreenshot(NSString **err) {
    // 广播开启时禁止调用 A-D 的私有 IOSurface 截图接口。
    // 这些接口与 ReplayKit 同时工作时可能触发系统进程级崩溃，必须只使用广播帧。
    if (PCBroadcastAlive()) return shotR(err);
    typedef UIImage *(*ShotFn)(NSString **);
    ShotFn fns[5] = {shotR, shotA, shotB, shotC, shotD};
    NSString *names[5] = {@"R", @"A", @"B", @"C", @"D"};
    NSMutableString *report = [NSMutableString string];
    for (int i = 0; i < 5; i++) {
        NSString *note = nil;
        UIImage *img = fns[i](&note);
        if (img) { gShotMethod = names[i]; return img; }
        [report appendFormat:@"%@:%@; ", names[i], note ?: @"?"];
    }
    if (err) *err = report;
    return nil;
}

static UIImage *resizeToWidth(UIImage *img, CGFloat width) {
    if (width <= 0 || width >= img.size.width) return img;
    CGFloat k = width / img.size.width;
    CGSize ns = CGSizeMake(width, img.size.height * k);
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ns format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    }];
}

static UIImage *prepareOCRImage(UIImage *src) {
    UIImage *scaled = resizeToWidth(src, 1400);
    CIImage *input = [[CIImage alloc] initWithImage:scaled];
    if (!input) return scaled;
    CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
    [filter setValue:input forKey:kCIInputImageKey];
    [filter setValue:@0.0 forKey:kCIInputSaturationKey];
    [filter setValue:@1.18 forKey:kCIInputContrastKey];
    [filter setValue:@0.02 forKey:kCIInputBrightnessKey];
    CIContext *ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
    CGImageRef cg = [ctx createCGImage:filter.outputImage fromRect:filter.outputImage.extent];
    if (!cg) return scaled;
    UIImage *out = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return out;
}

// 把截图缩放到固定的 780x1688(正好是屏幕 pt 尺寸的 2 倍),并叠加每 100 像素一条的
// 红色网格和边缘数字,帮助视觉模型把"看到的位置"换算成坐标。(PhoneAgent renderForModel)
static UIImage *renderForModel(UIImage *src) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(MODEL_W, MODEL_H) format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [src drawInRect:CGRectMake(0, 0, MODEL_W, MODEL_H)];
        CGContextRef c = ctx.CGContext;
        CGContextSetLineWidth(c, 1);
        CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:1 green:0 blue:0 alpha:0.35].CGColor);
        NSDictionary *attrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
                                NSForegroundColorAttributeName: UIColor.redColor,
                                NSBackgroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75]};
        for (int x = 100; x < MODEL_W; x += 100) {
            CGContextMoveToPoint(c, x, 0); CGContextAddLineToPoint(c, x, MODEL_H); CGContextStrokePath(c);
            NSString *t = [NSString stringWithFormat:@"%d", x];
            [t drawAtPoint:CGPointMake(x + 2, 2) withAttributes:attrs];
            [t drawAtPoint:CGPointMake(x + 2, MODEL_H - 22) withAttributes:attrs];
        }
        for (int y = 100; y < MODEL_H; y += 100) {
            CGContextMoveToPoint(c, 0, y); CGContextAddLineToPoint(c, MODEL_W, y); CGContextStrokePath(c);
            NSString *t = [NSString stringWithFormat:@"%d", y];
            [t drawAtPoint:CGPointMake(2, y + 2) withAttributes:attrs];
            [t drawAtPoint:CGPointMake(MODEL_W - 46, y + 2) withAttributes:attrs];
        }
    }];
}

#pragma mark - OCR (Vision)

// 返回 [{text,x,y,w,h}],坐标是屏幕点(pt),x/y 为中心点。
// iOS 16.1 的 Vision Revision 3 模型在本项目环境中会触发
// "Semaphore object deallocated while in use"，因此固定使用稳定的 Revision 1/Fast。
static NSArray *ocrWithHandler(VNImageRequestHandler *h, NSString **err) {
    if (!h) { if (err) *err = @"Vision 请求处理器为空"; return nil; }
    CGSize s = screenSize();
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.revision = VNRecognizeTextRequestRevision1;
    req.recognitionLevel = VNRequestTextRecognitionLevelFast;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = NO;
    req.usesCPUOnly = YES;
    NSError *e = nil;
    BOOL ok = NO;
    @try { ok = [h performRequests:@[req] error:&e]; }
    @catch (NSException *ex) {
        if (err) *err = [NSString stringWithFormat:@"Vision 异常:%@", ex.reason ?: @"未知异常"];
        return nil;
    }
    if (!ok) {
        if (err) *err = e.localizedDescription ?: @"Vision 识别失败";
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (VNRecognizedTextObservation *o in req.results) {
        VNRecognizedText *t = [[o topCandidates:1] firstObject];
        if (!t.string.length) continue;
        CGRect bb = o.boundingBox;
        [out addObject:@{
            @"text": t.string,
            @"x": @((int)round((bb.origin.x + bb.size.width / 2) * s.width)),
            @"y": @((int)round((1 - bb.origin.y - bb.size.height / 2) * s.height)),
            @"w": @((int)round(bb.size.width * s.width)),
            @"h": @((int)round(bb.size.height * s.height))}];
    }
    return out;
}

// 用广播扩展送来的原始 NV12 数据建一个"不带 IOSurface"的 CVPixelBuffer 直接交给 Vision
static NSArray *ocrNV12(NSString **err) {
    NSData *nv; uint32_t w, h, fmt;
    @synchronized (gLock) { nv = gNV12; w = gNW; h = gNH; fmt = gNFmt; }
    if (!nv.length || !w || !h) { if (err) *err = @"没有 NV12 数据"; return nil; }
    if (w > 8192 || h > 8192 || (w & 1) || (h & 1)) {
        if (err) *err = [NSString stringWithFormat:@"NV12 尺寸无效(%ux%u)", w, h];
        return nil;
    }
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        if (err) *err = [NSString stringWithFormat:@"不支持的 NV12 格式(0x%x)", fmt];
        return nil;
    }
    size_t expected = (size_t)w * h + (size_t)w * h / 2;
    if (nv.length != expected) {
        if (err) *err = [NSString stringWithFormat:@"NV12 长度无效(%lu,应为%lu)",
                         (unsigned long)nv.length, (unsigned long)expected];
        return nil;
    }
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &pb);
    if (r != kCVReturnSuccess || !pb) {
        if (err) *err = [NSString stringWithFormat:@"建 CVPixelBuffer 失败(%d)", (int)r];
        return nil;
    }
    r = CVPixelBufferLockBaseAddress(pb, 0);
    if (r != kCVReturnSuccess) {
        CVPixelBufferRelease(pb);
        if (err) *err = [NSString stringWithFormat:@"锁定 NV12 缓冲失败(%d)", (int)r];
        return nil;
    }
    size_t yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1);
    uint8_t *yd = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *cd = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    if (!yw || !yh || !cw || !ch || !yd || !cd || nv.length != yw * yh + cw * 2 * ch) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = @"NV12 平面或数据长度无效";
        return nil;
    }
    const uint8_t *src = nv.bytes;
    size_t yrb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    if (yrb < yw) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = @"NV12 Y 平面行宽无效";
        return nil;
    }
    for (size_t i = 0; i < yh; i++) memcpy(yd + i * yrb, src + i * yw, yw);
    src += yw * yh;
    size_t crb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    if (crb < cw * 2) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CVPixelBufferRelease(pb);
        if (err) *err = @"NV12 UV 平面行宽无效";
        return nil;
    }
    for (size_t i = 0; i < ch; i++) memcpy(cd + i * crb, src + i * cw * 2, cw * 2);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    VNImageRequestHandler *h2 = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
    NSArray *out = ocrWithHandler(h2, err);
    CVPixelBufferRelease(pb);
    return out;
}

static NSArray *ocrImage(UIImage *img, NSString **err) {
    if (!img.CGImage) { if (err) *err = @"截图没有有效图像"; return nil; }
    UIImage *ocrImg = prepareOCRImage(img);
    NSMutableString *notes = [NSMutableString string];
    NSString *e2 = nil;
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:ocrImg.CGImage options:@{}];
    NSArray *r = ocrWithHandler(h, &e2);
    if (r) return r;
    [notes appendFormat:@"[图片路径]%@", e2];
    // JPEG OCR 失败时，才尝试经过完整校验的 NV12；失败只作为普通错误返回。
    if ([gShotMethod isEqualToString:@"R"]) {
        NSString *e1 = nil;
        NSArray *nv = ocrNV12(&e1);
        if (nv) return nv;
        [notes appendFormat:@" [NV12路径]%@", e1 ?: @"失败"];
    }
    if (err) *err = [NSString stringWithFormat:@"OCR 全部失败 %@", notes];
    return nil;
}

#pragma mark - 打开 App

static BOOL openApp(NSString *bid) {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) return NO;
    id ws = ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace"));
    if (!ws) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, NSSelectorFromString(@"openApplicationWithBundleID:"), bid);
}

// 按 App 名称找 bundle id(用系统私有接口列出已安装 App)
static NSString *bundleForAppName(NSString *name, NSString **info) {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) { *info = @"没有 LSApplicationWorkspace"; return nil; }
    id ws = ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"defaultWorkspace"));
    SEL sel = NSSelectorFromString(@"allInstalledApplications");
    if (!ws || ![ws respondsToSelector:sel]) { *info = @"无法列出已安装 App"; return nil; }
    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, sel);
    NSMutableArray *names = [NSMutableArray array], *bids = [NSMutableArray array], *userNames = [NSMutableArray array];
    for (id a in apps) {
        NSString *n = nil, *bid = nil, *type = nil;
        @try { n = [a valueForKey:@"localizedName"]; bid = [a valueForKey:@"applicationIdentifier"]; type = [a valueForKey:@"applicationType"]; }
        @catch (NSException *ex) { continue; }
        if (![n isKindOfClass:NSString.class] || ![bid isKindOfClass:NSString.class] || !n.length) continue;
        [names addObject:n]; [bids addObject:bid];
        if ([type isKindOfClass:NSString.class] && [type isEqualToString:@"User"]) [userNames addObject:n];
    }
    NSString *q = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *exact = nil, *partial = nil;
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *n = names[i];
        if ([n caseInsensitiveCompare:q] == NSOrderedSame) { exact = bids[i]; break; }
        if (!partial && q.length >= 2 && ([n localizedCaseInsensitiveContainsString:q] || (n.length >= 2 && [q localizedCaseInsensitiveContainsString:n]))) partial = bids[i];
    }
    NSString *r = exact ?: partial;
    if (!r) { // 常见 App 别名(只有确实装了才会命中);长的关键词放前面
        NSArray *alias = @[@[@"网易云音乐", @"com.netease.cloudmusic"],
            @[@"哔哩哔哩", @"tv.danmaku.bilianime"],
            @[@"百度地图", @"com.baidu.map"], @[@"腾讯地图", @"com.tencent.sosomap"], @[@"小红书", @"com.xingin.discover"],
            @[@"拼多多", @"com.xunmeng.pinduoduo"], @[@"支付宝", @"com.alipay.iphoneclient"], @[@"高德", @"com.autonavi.amap"],
            @[@"微信", @"com.tencent.xin"], @[@"淘宝", @"com.taobao.taobao4iphone"], @[@"京东", @"com.360buy.jdmobile"],
            @[@"美团", @"com.meituan.imeituan"], @[@"抖音", @"com.ss.iphone.ugc.Aweme"], @[@"微博", @"com.sina.weibo"],
            @[@"钉钉", @"com.laiwang.DingTalk"], @[@"饿了么", @"me.ele.ios.eleme"], @[@"滴滴", @"com.xiaojukeji.didi"],
            @[@"备忘录", @"com.apple.mobilenotes"], @[@"设置", @"com.apple.Preferences"], @[@"相机", @"com.apple.camera"],
            @[@"照片", @"com.apple.mobileslideshow"], @[@"电话", @"com.apple.mobilephone"], @[@"信息", @"com.apple.MobileSMS"],
            @[@"Safari", @"com.apple.mobilesafari"], @[@"QQ", @"com.tencent.mqq"], @[@"地图", @"com.apple.Maps"]];
        for (NSArray *pair in alias)
            if ([q localizedCaseInsensitiveContainsString:pair[0]] && [bids containsObject:pair[1]]) { r = pair[1]; break; }
    }
    if (!r) {
        NSArray *shown = userNames.count > 60 ? [userNames subarrayWithRange:NSMakeRange(0, 60)] : userNames;
        *info = [NSString stringWithFormat:@"没找到名为「%@」的 App。已安装的第三方 App:%@。请改用其中的准确名称重试 open_app。",
                 name, [shown componentsJoinedByString:@"、"]];
    }
    return r;
}

// 当前最前台 App 的 bundle id(SpringBoardServices 私有接口,失败返回 nil)。
// 先在 NSUserDefaults 里打个"可能崩溃"的标记,万一这个接口在本系统上签名不对导致崩溃,下次启动就自动停用。
static NSString *frontmostBundleID(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:@"sbfront_crashed"]) return nil;
    static void *h; static mach_port_t (*getPort)(void); static void (*getFront)(mach_port_t, char *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        if (h) {
            getPort = dlsym(h, "SBSSpringBoardServerPort");
            getFront = dlsym(h, "SBFrontmostApplicationDisplayIdentifier");
        }
    });
    if (!getPort || !getFront) return nil;
    [d setBool:YES forKey:@"sbfront_crashed"]; [d synchronize];
    mach_port_t port = getPort();
    char buf[512]; memset(buf, 0, sizeof buf);
    if (port) getFront(port, buf);
    [d setBool:NO forKey:@"sbfront_crashed"]; [d synchronize];
    return buf[0] ? [NSString stringWithUTF8String:buf] : nil;
}

static UIApplicationState appStateNow(void) {
    __block UIApplicationState st = UIApplicationStateBackground;
    dispatch_sync(dispatch_get_main_queue(), ^{ st = UIApplication.sharedApplication.applicationState; });
    return st;
}

static BOOL waitAppActive(double timeout) {
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + timeout;
    while (CFAbsoluteTimeGetCurrent() < end) {
        if (appStateNow() == UIApplicationStateActive) return YES;
        usleep(200 * 1000);
    }
    return NO;
}

// 写剪贴板。iOS 9 起不允许后台 App 访问剪贴板(写入也会被忽略),而 Minis 平时都在后台操作别的 App,
// 所以这里先把 Minis 切到前台、写入并读回校验,再切回原来的 App。
// 返回 YES 表示写入并校验成功;stranded 为 YES 表示切走后没能自动回去(需要模型用 open_app 回到目标 App)。
static BOOL writeClipboardInForeground(NSString *text, NSString *backHint, NSString **note, BOOL *stranded) {
    *stranded = NO;
    NSString *selfID = NSBundle.mainBundle.bundleIdentifier;
    BOOL switched = NO;
    NSString *back = nil;
    if (appStateNow() != UIApplicationStateActive) {
        back = frontmostBundleID();
        if (!back.length || [back isEqualToString:selfID] || [back isEqualToString:@"com.apple.springboard"])
            back = backHint.length ? backHint : gLastApp;
        if (!openApp(selfID) || !waitAppActive(5)) { *note = @"没能把 Minis 切到前台,无法写剪贴板"; return NO; }
        switched = YES;
        usleep(500 * 1000);
    }
    __block NSString *check = nil; __block NSInteger cc0 = 0, cc1 = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIPasteboard *pb = UIPasteboard.generalPasteboard;
        cc0 = pb.changeCount;
        pb.string = text;
        cc1 = pb.changeCount;
        check = pb.string;
    });
    BOOL ok = [check isEqualToString:text];
    if (!ok) *note = [NSString stringWithFormat:@"剪贴板写入后读回不一致(changeCount %ld→%ld)", (long)cc0, (long)cc1];
    if (switched) {
        if (back.length && ![back isEqualToString:selfID] && ![back isEqualToString:@"com.apple.springboard"]) {
            openApp(back);
            sleep(2);
        } else {
            *stranded = YES;
        }
    }
    return ok;
}

// 回主屏幕:先发 Home 键事件;如果还能查到最前台 App 并且不是主屏,再尝试从底部上滑
static BOOL goHome(NSString **note) {
    BOOL sent = doHomeKey();
    sleep(1);
    NSString *f = frontmostBundleID();
    if ([f isEqualToString:@"com.apple.springboard"]) { *note = @"Home 键事件有效"; return YES; }
    if (!f.length) { *note = sent ? @"已发送 Home 键事件(无法确认结果)" : @"没有 Home 键接口,也无法确认结果"; return sent; }
    CGSize sc = screenSize();
    doSwipe(sc.width / 2, sc.height - 2, sc.width / 2, sc.height * 0.55, 12, 180);
    sleep(1);
    f = frontmostBundleID();
    BOOL ok = [f isEqualToString:@"com.apple.springboard"];
    *note = ok ? @"底部上滑有效" : [NSString stringWithFormat:@"Home 键和上滑都没能回到主屏(当前 %@)", f ?: @"未知"];
    return ok;
}

// 等广播画面静止:最近 0.8 秒内没有新帧,说明动画/转场结束了(最多等 maxWait 秒)
static void waitForStableFrame(double maxWait) {
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + maxWait;
    while (CFAbsoluteTimeGetCurrent() < end) {
        CFAbsoluteTime ft;
        @synchronized (gLock) { ft = gFrameT; }
        if (ft > 0 && CFAbsoluteTimeGetCurrent() - ft >= 0.8) return;
        usleep(150 * 1000);
    }
}

// 最近一帧广播画面(原始 JPEG)
static NSData *agLatestJPEG(NSString **err) {
    if (!PCBroadcastAlive()) { *err = @"屏幕广播没开(或已停止)"; return nil; }
    NSData *d;
    @synchronized (gLock) { d = gFrame; }
    if (!d.length) { *err = @"还没收到画面"; return nil; }
    return d;
}

static NSString *agFrameSig(NSData *d) {
    const uint8_t *p = d.bytes; uint64_t h = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < d.length; i += 211) { h ^= p[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%lu-%llx", (unsigned long)d.length, h];
}

// 截一次图并做本地 OCR,在其中找包含 words 之一、且不含 excludes 的文字
static NSDictionary *agFindOnScreen(NSArray *words, NSArray *excludes, NSString **err) {
    waitForStableFrame(2.0);
    UIImage *img = takeScreenshot(err);
    if (!img) return nil;
    NSArray *items = ocrImage(img, err);
    for (NSDictionary *it in items) {
        NSString *t = it[@"text"];
        BOOL hit = NO; for (NSString *w in words) if ([t containsString:w]) { hit = YES; break; }
        if (!hit) continue;
        BOOL bad = NO; for (NSString *x in excludes) if ([t containsString:x]) { bad = YES; break; }
        if (!bad) return it;
    }
    return nil;
}

// 在 (x,y) 的输入框里输入文字:写剪贴板(必须在前台) -> 回到原 App -> 点输入框聚焦
// 方法一:硬件键盘快捷键 Cmd+A(替换旧内容)+ Cmd+V,并自动点掉 iOS 的“允许粘贴”确认框。
// 方法二(方法一看不出效果时):长按输入框 -> (有“全选”就先全选) -> 点“粘贴” -> 点“允许粘贴”。
// 两种都无法确认时也返回 YES,但 note 里写明“没能确认”,让模型看下一张截图自己判断(输入其实经常是成功的)。
static BOOL agPasteText(NSString *text, double x, double y, NSString *backHint, NSString **note) {
    NSString *n = nil; BOOL stranded = NO;
    *note = nil;
    if (!writeClipboardInForeground(text, backHint, &n, &stranded)) { *note = n ?: @"剪贴板写入失败"; return NO; }
    if (stranded) { *note = @"剪贴板已写入,但没能自动回到原来的 App"; return NO; }
    usleep(800 * 1000);
    doTap(x, y);
    usleep(900 * 1000);
    NSString *e = nil;

    BOOL sent = doCmdKey(0x04);                 // Cmd+A:选中旧内容(没有旧内容就什么也不发生)
    usleep(500 * 1000);
    waitForStableFrame(2.0);
    NSData *f1 = agLatestJPEG(&e);
    NSString *sig1 = f1 ? agFrameSig(f1) : @"";
    sent = doCmdKey(0x19) && sent;              // Cmd+V
    usleep(900 * 1000);
    NSDictionary *allow1 = agFindOnScreen(@[@"允许粘贴"], @[@"不允许"], &e);
    if (allow1) { doTap([allow1[@"x"] doubleValue], [allow1[@"y"] doubleValue]); usleep(900 * 1000); }
    waitForStableFrame(2.0);
    NSData *f2 = agLatestJPEG(&e);
    NSString *sig2 = f2 ? agFrameSig(f2) : @"";
    if (sent) {
        if (allow1) return YES;
        if (sig1.length && sig2.length && ![sig1 isEqualToString:sig2]) return YES;
        NSString *flat = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
        NSString *snip = flat.length > 6 ? [flat substringToIndex:6] : flat;
        if (!snip.length) return YES;
        UIImage *img = takeScreenshot(&e);
        NSArray *items = img ? ocrImage(img, &e) : nil;
        for (NSDictionary *it in items) if ([it[@"text"] containsString:snip]) return YES;
    }

    doLongPress(x, y, 1100);
    NSDictionary *all = agFindOnScreen(@[@"全选"], @[], &e);
    if (all) { doTap([all[@"x"] doubleValue], [all[@"y"] doubleValue]); usleep(800 * 1000); }
    NSDictionary *paste = agFindOnScreen(@[@"粘贴"], @[@"允许", @"不允许", @"并"], &e);
    if (!paste) { *note = @"没能确认文字是否输入成功(键盘快捷键没有明显效果,也没找到“粘贴”菜单)"; return YES; }
    doTap([paste[@"x"] doubleValue], [paste[@"y"] doubleValue]);
    usleep(900 * 1000);
    NSDictionary *allow = agFindOnScreen(@[@"允许粘贴"], @[@"不允许"], &e);
    if (allow) { doTap([allow[@"x"] doubleValue], [allow[@"y"] doubleValue]); usleep(900 * 1000); }
    return YES;
}

#pragma mark - 保活音频(后台留活)

static AVAudioPlayer *gKeepPlayer;
static void setKeepAlive(BOOL on);
static void resumeKeepAlive(void);

static void setKeepAlive(BOOL on) {
    @try {
        AVAudioSession *s = AVAudioSession.sharedInstance;
        [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [s setActive:YES error:nil];
        if (on) {
            if (!gKeepPlayer) {
                NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"silence.wav"]];
                if (!NSFileManager.defaultManager.fileExistsAtPath) {}
                if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
                    int sr = 8000, dur = 60, n = sr * dur;
                    uint32_t dsz = n * 2, riff = 36 + dsz;
                    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dsz];
                    [d appendBytes:"RIFF" length:4]; [d appendBytes:&riff length:4]; [d appendBytes:"WAVE" length:4];
                    [d appendBytes:"fmt " length:4]; uint32_t sz = 16; [d appendBytes:&sz length:4];
                    uint16_t fmt = 1, ch = 1, blk = 2, bits = 16; uint32_t br = 16000;
                    [d appendBytes:&fmt length:2]; [d appendBytes:&ch length:2]; [d appendBytes:&sr length:4];
                    [d appendBytes:&br length:4]; [d appendBytes:&blk length:2]; [d appendBytes:&bits length:2];
                    [d appendBytes:"data" length:4]; [d appendBytes:&dsz length:4];
                    NSMutableData *sil = [NSMutableData dataWithLength:dsz];
                    [d appendData:sil];
                    [d writeToURL:url atomically:YES];
                }
                NSError *e = nil;
                gKeepPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&e];
                if (gKeepPlayer) { gKeepPlayer.numberOfLoops = -1; gKeepPlayer.volume = 0; }
                else addLog([NSString stringWithFormat:@"保活音频创建失败:%@", e.localizedDescription ?: @"?"]);
            }
            if (gKeepPlayer && !gKeepPlayer.playing) [gKeepPlayer play];
            addLog(@"保活音频已开启");
        } else {
            [gKeepPlayer stop];
            addLog(@"保活音频已停止");
        }
    } @catch (NSException *ex) { addLog([NSString stringWithFormat:@"保活音频异常:%@", ex.reason ?: @"?"]); }
}

static void resumeKeepAlive(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:@"auto_keepalive"] && ![d boolForKey:@"auto_keepalive"]) return;
    setKeepAlive(YES);
}

#pragma mark - 广播帧接收(/frame,/hb,/bye;端口 8310)

// 读取一行(以 \n 结尾,最多 2048 字节)
static BOOL readLine(int fd, char *buf, int cap) {
    int n = 0;
    while (n < cap - 1) {
        char c;
        ssize_t r = recv(fd, &c, 1, 0);
        if (r <= 0) return NO;
        buf[n++] = c;
        if (c == '\n') break;
    }
    buf[n] = 0;
    return YES;
}

static void handleClient(int fd) {
    char line[2048];
    if (!readLine(fd, line, sizeof line)) return;
    char method[16] = {0}, path[256] = {0};
    sscanf(line, "%15s %255s", method, path);
    int contentLength = 0;
    char hdr[2048];
    while (readLine(fd, hdr, sizeof hdr)) {
        if (strcmp(hdr, "\r\n") == 0 || strcmp(hdr, "\n") == 0) break;
        if (strncasecmp(hdr, "Content-Length:", 15) == 0) contentLength = atoi(hdr + 15);
    }
    if (strcmp(path, "/hb") == 0) {
        @synchronized (gLock) { gHbT = CFAbsoluteTimeGetCurrent(); }
        const char *body = gBroadcastStopRequested ? "{\"cmd\":\"stop\"}" : "{\"cmd\":\"ok\"}";
        char resp[512];
        int n = snprintf(resp, sizeof resp, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", strlen(body), body);
        send(fd, resp, n, 0);
        return;
    }
    if (strcmp(path, "/bye") == 0) {
        @synchronized (gLock) { gHbT = 0; gFrame = nil; gNV12 = nil; }
        const char *body = "{\"ok\":1}";
        char resp[256];
        int n = snprintf(resp, sizeof resp, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", strlen(body), body);
        send(fd, resp, n, 0);
        return;
    }
    if (strcmp(path, "/frame") != 0 || contentLength <= 0 || contentLength > 20000000) return;
    NSMutableData *data = [NSMutableData dataWithLength:contentLength];
    uint8_t *buf = data.mutableBytes;
    int got = 0;
    while (got < contentLength) {
        ssize_t r = recv(fd, buf + got, contentLength - got, 0);
        if (r <= 0) return;
        got += (int)r;
    }
    const char *h = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 8\r\nConnection: close\r\n\r\n{\"ok\":1}";
    send(fd, h, strlen(h), 0);
    if (contentLength < 24 || memcmp(buf, "PAF1", 4) != 0) return;
    uint32_t w, hgt, jl, nl, fmt;
    memcpy(&w, buf + 4, 4); memcpy(&hgt, buf + 8, 4); memcpy(&jl, buf + 12, 4);
    memcpy(&nl, buf + 16, 4); memcpy(&fmt, buf + 20, 4);
    if (jl == 0 || nl == 0 || w == 0 || hgt == 0) return;
    if (24 + jl + nl > (uint32_t)contentLength) return;
    NSData *jpeg = [NSData dataWithBytes:buf + 24 length:jl];
    NSData *nv = [NSData dataWithBytes:buf + 24 + jl length:nl];
    @synchronized (gLock) {
        gFrame = jpeg; gNV12 = nv; gNW = w; gNH = hgt; gNFmt = fmt;
        gFrameT = CFAbsoluteTimeGetCurrent(); gHbT = gFrameT;
        if (gExtIS != 1) { gExtIS = 1; addLog(@"扩展已连接,开始接收画面"); }
    }
}

static void startServer(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { addLog(@"帧服务器 socket 创建失败"); return; }
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof opt);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(PC_PORT);
    if (bind(srv, (struct sockaddr *)&addr, sizeof addr) < 0) {
        addLog([NSString stringWithFormat:@"帧服务器绑定 8310 失败(可能已有进程占用)"]);
        close(srv);
        return;
    }
    if (listen(srv, 8) < 0) { addLog(@"帧服务器监听失败"); close(srv); return; }
    addLog([NSString stringWithFormat:@"帧服务器已启动(127.0.0.1:%d)", PC_PORT]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        while (1) {
            int fd = accept(srv, NULL, NULL);
            if (fd < 0) { usleep(100 * 1000); continue; }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                handleClient(fd);
                close(fd);
            });
        }
    });
}

#pragma mark - 自动开广播(盲点系统面板)

static RPSystemBroadcastPickerView *gPicker;
static UIView *gGuard; // 盲点期间盖住 App 自身 UI,防止误点

static void addGuard(void) {
    __block UIWindow *win = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { win = w; break; }
        if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    });
    if (!win) return;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (gGuard) [gGuard removeFromSuperview];
        gGuard = [[UIView alloc] initWithFrame:win.bounds];
        gGuard.backgroundColor = UIColor.clearColor;
        gGuard.userInteractionEnabled = YES;
        [win addSubview:gGuard];
    });
}

static void removeGuard(void) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [gGuard removeFromSuperview];
        gGuard = nil;
    });
}

static BOOL triggerPicker(void) {
    __block UIButton *btn = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIView *v in gPicker.subviews) if ([v isKindOfClass:UIButton.class]) btn = (UIButton *)v;
    });
    if (!btn) { addLog(@"picker 里找不到按钮"); return NO; }
    dispatch_async(dispatch_get_main_queue(), ^{ [btn sendActionsForControlEvents:UIControlEventTouchUpInside]; });
    return YES;
}

// 任务开始时录屏没开:自动开广播(盲点系统面板里的"开始直播"),再点面板外的空白处
// 把面板收起来回到 Minis 界面。移植自 MiniPaw/PhoneAgent 的 ensureBroadcast:
// 盲点期间用透明的 castGuard 盖住 App 自身 UI,防止点中 Minis 的按钮;
// 先试保存过的按钮位置,再用 OCR 找"开始直播";开始后等扩展心跳确认;
// 最后的空白处点按(PhoneAgent v56 用 y=0.81)也在 guard 保护下进行——面板还在时,
// 点按落在系统面板窗口(在 guard 之上)上把它收起;面板已经自己消失时,点按被 guard 吃掉,
// 不会误点 Minis 的聊天界面。
BOOL PCEnsureBroadcast(NSString **note) {
    if (PCBroadcastAlive()) return YES;
    if (!gPicker) { *note = @"广播选择器未初始化"; return NO; }
    if (!triggerPicker()) { *note = @"无法弹出广播选择器"; return NO; }
    sleep(3);
    waitForStableFrame(2.0);
    CGSize s = screenSize();
    BOOL started = NO;
    // 先用保存过的按钮位置试一次
    double savedY = [NSUserDefaults.standardUserDefaults doubleForKey:@"bcast_btn_y"];
    if (savedY > 0.3 && savedY < 0.85) {
        addGuard();
        doTap(s.width * 0.5, s.height * savedY);
        removeGuard();
        for (int i = 0; i < 15 && !PCBroadcastAlive(); i++) usleep(200 * 1000);
        started = PCBroadcastAlive();
        if (started) addLog(@"已用保存的位置自动开启广播");
    }
    if (!started) {
        // 再用 OCR 在系统面板里找“开始直播”
        NSString *e = nil;
        NSDictionary *item = agFindOnScreen(@[@"开始直播"], @[], &e);
        if (!item) item = agFindOnScreen(@[@"开始"], @[@"停止", @"结束"], &e);
        if (!item) { *note = @"没找到“开始直播”按钮,请手动在控制中心开启屏幕录制并选择 Minis"; return NO; }
        addGuard();
        doTap([item[@"x"] doubleValue], [item[@"y"] doubleValue]);
        removeGuard();
        [NSUserDefaults.standardUserDefaults setDouble:[item[@"y"] doubleValue] / s.height forKey:@"bcast_btn_y"];
        for (int i = 0; i < 20 && !PCBroadcastAlive(); i++) usleep(200 * 1000);
        started = PCBroadcastAlive();
        if (!started) { *note = @"点了“开始直播”但广播仍未启动"; return NO; }
    }
    // 广播已开:点面板外的空白处(PhoneAgent v56 用 y=0.81),把系统面板收起来,回到 Minis 界面
    usleep(1500 * 1000);
    addGuard();
    doTap(s.width * 0.5, s.height * 0.81);
    removeGuard();
    *note = @"已自动开启屏幕录制";
    return YES;
}

void PCRequestBroadcastStop(void) {
    // 任务结束时关闭录屏并点掉系统提示(v1.0.3 的 closeBroadcastAndDismiss):
    // 先让扩展自己结束,再用 OCR 找"好"的真实位置点掉(提示框位置随系统版本/机型会变,
    // 写死坐标点不中);点完再验一次,还在就补点一次;找到的位置记下来,下次先用它。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (!PCBroadcastAlive()) return;
        // 让广播扩展自己结束(扩展调用 finishBroadcastWithError),最多等 10 秒
        gBroadcastStopRequested = YES;
        for (int i = 0; i < 50 && PCBroadcastAlive(); i++) usleep(200 * 1000);
        BOOL still = PCBroadcastAlive();
        gBroadcastStopRequested = NO;
        if (still) { addLog(@"提示:屏幕录制没能自动关闭,请手动关闭"); return; }
        usleep(1700 * 1000); // 等系统弹出"直播已停止"提示
        CGSize sc = screenSize();
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        for (int attempt = 0; attempt < 2; attempt++) {
            NSString *e = nil;
            UIImage *img = takeScreenshot(&e); // 广播已停,这里走 A-D 私有截图接口
            NSArray *items = img ? ocrImage(img, &e) : nil;
            NSDictionary *okBtn = nil;
            for (NSDictionary *it in items ?: @[]) {
                if ([it[@"text"] isEqualToString:@"好"]) { okBtn = it; break; }
            }
            if (!okBtn) {
                for (NSDictionary *it in items ?: @[]) {
                    NSString *t = it[@"text"];
                    if (t.length && [t containsString:@"好"]) { okBtn = it; break; }
                }
            }
            double tx, ty;
            if (okBtn) {
                tx = [okBtn[@"x"] doubleValue]; ty = [okBtn[@"y"] doubleValue];
                [ud setDouble:tx / sc.width forKey:@"stop_ok_x"];
                [ud setDouble:ty / sc.height forKey:@"stop_ok_y"];
            } else {
                double ox = [ud doubleForKey:@"stop_ok_x"], oy = [ud doubleForKey:@"stop_ok_y"];
                if (ox <= 0) ox = 0.327;
                if (oy <= 0) oy = 0.566;
                tx = sc.width * ox; ty = sc.height * oy;
            }
            doTap(tx, ty);
            usleep(1000 * 1000);
            NSString *e2 = nil;
            UIImage *img2 = takeScreenshot(&e2);
            NSArray *items2 = img2 ? ocrImage(img2, &e2) : nil;
            BOOL stillThere = NO;
            for (NSDictionary *it in items2 ?: @[]) {
                if ([it[@"text"] isEqualToString:@"好"]) { stillThere = YES; break; }
            }
            if (!stillThere) { addLog(@"屏幕录制已关闭,提示已点掉"); return; }
            if (attempt == 0) addLog(@"“好”还在,再点一次");
        }
        addLog(@"提示:直播已停止提示没能点掉,请手动点“好”");
    });
}

#pragma mark - 日志与启动

static void addLog(NSString *m) {
    NSLog(@"[PhoneControl] %@", m);
    @synchronized (gLock) {
        if (!gLog) gLog = [NSMutableArray array];
        [gLog addObject:m];
        while (gLog.count > 50) [gLog removeObjectAtIndex:0];
    }
}

__attribute__((constructor)) static void PCInitGlobals(void) {
    gLock = [NSObject new];
    gLog = [NSMutableArray array];
}

void PCStartup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSwipeMode = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"swipe_mode"];
        NSString *e1 = loadHID();
        NSString *e2 = loadShot();
        if (e1) addLog([NSString stringWithFormat:@"loadHID 失败:%@", e1]);
        else addLog(@"HID 已加载");
        if (e2) addLog([NSString stringWithFormat:@"loadShot 失败:%@", e2]);
        else addLog(@"截图接口已加载");
        startServer();
        resumeKeepAlive();
        // 创建隐藏的广播选择器(1x1,几乎透明),供 PCEnsureBroadcast 自动开广播用
        dispatch_async(dispatch_get_main_queue(), ^{
            RPSystemBroadcastPickerView *p = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectMake(2, 2, 1, 1)];
            p.preferredExtension = @"com.openminis.app.MinisBroadcast";
            p.showsMicrophoneButton = NO;
            p.alpha = 0.01;
            UIWindow *win = nil;
            for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { win = w; break; }
            if (!win) win = UIApplication.sharedApplication.windows.firstObject;
            [win addSubview:p];
            gPicker = p;
        });
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) { PCAppDidEnterBackground(); }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { PCAppDidBecomeActive(); }];
        addLog(@"PhoneControl 已启动");
    });
}

void PCAppDidEnterBackground(void) { setKeepAlive(YES); }
void PCAppDidBecomeActive(void) { resumeKeepAlive(); }

#pragma mark - 公共 API

static NSMutableArray *gLastItemsPt; // 最近一次 OCR 的 pt 坐标项 {id,x,y,w,h,text}

NSArray *PCLastOCRItems(void) {
    @synchronized (gLock) { return [gLastItemsPt copy] ?: @[]; }
}

BOOL PCPointForOCRId(NSInteger ocrId, double *outX, double *outY) {
    NSArray *items = PCLastOCRItems();
    for (NSDictionary *it in items) {
        if ([it[@"id"] integerValue] == ocrId) {
            *outX = [it[@"x"] doubleValue];
            *outY = [it[@"y"] doubleValue];
            return YES;
        }
    }
    return NO;
}

NSDictionary *PCCaptureScreen(NSError **err) {
    NSString *e = nil;
    UIImage *img = takeScreenshot(&e);
    if (!img) {
        if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: e ?: @"截屏失败"}];
        return nil;
    }
    UIImage *model = renderForModel(img);
    NSData *jpeg = UIImageJPEGRepresentation(model, 0.7);
    if (!jpeg) {
        if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"JPEG 编码失败"}];
        return nil;
    }
    NSArray *ocr = ocrImage(img, &e);
    CGSize s = screenSize();
    double kx = MODEL_W / s.width, ky = MODEL_H / s.height;
    NSMutableArray *items = [NSMutableArray array];
    NSMutableString *text = [NSMutableString string];
    NSInteger idx = 1;
    for (NSDictionary *it in ocr) {
        if (idx > 80) break;
        double mx = [it[@"x"] doubleValue] * kx, my = [it[@"y"] doubleValue] * ky;
        double mw = [it[@"w"] doubleValue] * kx, mh = [it[@"h"] doubleValue] * ky;
        [items addObject:@{@"id": @(idx), @"x": @((int)round(mx)), @"y": @((int)round(my)),
                           @"w": @((int)round(mw)), @"h": @((int)round(mh)), @"text": it[@"text"]}];
        [text appendFormat:@"[%ld] (%d,%d) %@\n", (long)idx, (int)round(mx), (int)round(my), it[@"text"]];
        idx++;
    }
    @synchronized (gLock) {
        gLastItemsPt = [NSMutableArray array];
        NSInteger j = 1;
        for (NSDictionary *it in ocr) {
            [gLastItemsPt addObject:@{@"id": @(j), @"x": it[@"x"], @"y": it[@"y"],
                                      @"w": it[@"w"], @"h": it[@"h"], @"text": it[@"text"]}];
            j++;
        }
    }
    return @{@"jpeg": jpeg,
             @"ocrText": text.length ? text : @"(屏幕上没有识别到文字)",
             @"items": items,
             @"signature": agFrameSig(jpeg),
             @"method": gShotMethod ?: @""};
}

BOOL PCPerformAction(NSString *action, NSDictionary *params, NSString **note, NSError **err) {
    if (!gClient) {
        if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:3
                                        userInfo:@{NSLocalizedDescriptionKey: @"触摸注入未初始化(HID 加载失败),无法操作屏幕"}];
        return NO;
    }
    double x = 0, y = 0;
    NSNumber *oid = params[@"id"];
    if (oid) {
        if (!PCPointForOCRId(oid.integerValue, &x, &y)) {
            if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:4
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                       [NSString stringWithFormat:@"OCR 编号 %ld 不存在,请先调用 phone_screen 重新看屏", (long)oid.integerValue]}];
            return NO;
        }
    } else if (params[@"x"] || params[@"y"]) {
        if (!modelToPt([params[@"x"] doubleValue], [params[@"y"] doubleValue], &x, &y)) {
            if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:5
                                            userInfo:@{NSLocalizedDescriptionKey: @"坐标超出屏幕范围(780x1688)"}];
            return NO;
        }
    }

    if ([action isEqualToString:@"tap"]) {
        doTap(x, y);
        *note = [NSString stringWithFormat:@"已点 (%.0f,%.0f)", x, y];
        return YES;
    }
    if ([action isEqualToString:@"long_press"]) {
        int ms = params[@"ms"] ? [params[@"ms"] intValue] : 900;
        doLongPress(x, y, ms);
        *note = [NSString stringWithFormat:@"已长按 (%.0f,%.0f) %d 毫秒", x, y, ms];
        return YES;
    }
    if ([action isEqualToString:@"swipe"]) {
        double x2 = 0, y2 = 0;
        NSString *dir = params[@"direction"];
        if (dir.length) {
            double cx = 390, cy = 844;
            if ([dir isEqualToString:@"up"]) { x = cx; y = 1200; x2 = cx; y2 = 500; }
            else if ([dir isEqualToString:@"down"]) { x = cx; y = 500; x2 = cx; y2 = 1200; }
            else if ([dir isEqualToString:@"left"]) { x = 600; y = cy; x2 = 180; y2 = cy; }
            else if ([dir isEqualToString:@"right"]) { x = 180; y = cy; x2 = 600; y2 = cy; }
            else {
                if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:6
                                                userInfo:@{NSLocalizedDescriptionKey: @"direction 只能是 up/down/left/right"}];
                return NO;
            }
            if (!modelToPt(x, y, &x, &y) || !modelToPt(x2, y2, &x2, &y2)) {
                if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:5
                                                userInfo:@{NSLocalizedDescriptionKey: @"滑动坐标超出屏幕范围"}];
                return NO;
            }
        } else {
            if (!modelToPt([params[@"x2"] doubleValue], [params[@"y2"] doubleValue], &x2, &y2)) {
                if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:5
                                                userInfo:@{NSLocalizedDescriptionKey: @"滑动终点坐标超出屏幕范围"}];
                return NO;
            }
        }
        doSwipe(x, y, x2, y2, 24, 500);
        *note = [NSString stringWithFormat:@"已从 (%.0f,%.0f) 滑到 (%.0f,%.0f)", x, y, x2, y2];
        return YES;
    }
    if ([action isEqualToString:@"input_text"]) {
        NSString *text = params[@"text"];
        if (!text.length) {
            if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:7
                                            userInfo:@{NSLocalizedDescriptionKey: @"input_text 需要 text 参数"}];
            return NO;
        }
        NSString *n = nil;
        BOOL ok = agPasteText(text, x, y, nil, &n);
        *note = n ?: @"已输入文字";
        if (!ok && err) *err = [NSError errorWithDomain:@"PhoneControl" code:8
                                               userInfo:@{NSLocalizedDescriptionKey: n ?: @"输入失败"}];
        return ok;
    }
    if ([action isEqualToString:@"open_app"]) {
        NSString *name = params[@"name"];
        if (!name.length) {
            if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:9
                                            userInfo:@{NSLocalizedDescriptionKey: @"open_app 需要 name 参数(App 名称)"}];
            return NO;
        }
        NSString *info = nil;
        NSString *bid = bundleForAppName(name, &info);
        if (!bid) {
            if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:10
                                            userInfo:@{NSLocalizedDescriptionKey: info ?: @"找不到该 App"}];
            return NO;
        }
        if (!openApp(bid)) {
            if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:11
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"打开 %@ 失败", name]}];
            return NO;
        }
        gLastApp = bid;
        sleep(2);
        *note = [NSString stringWithFormat:@"已打开 %@", name];
        return YES;
    }
    if ([action isEqualToString:@"press_home"]) {
        NSString *n = nil;
        BOOL ok = goHome(&n);
        *note = n ?: @"已回主屏幕";
        return ok;
    }
    if ([action isEqualToString:@"key"]) {
        uint32_t usage = 0;
        id u = params[@"usage"];
        if ([u isKindOfClass:NSNumber.class]) usage = [u unsignedIntValue];
        else if ([u isKindOfClass:NSString.class]) usage = (uint32_t)strtoul([u UTF8String], NULL, 0);
        if (!usage) {
            if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:12
                                            userInfo:@{NSLocalizedDescriptionKey: @"key 需要 usage 参数(键盘 HID 用量码,如回车=0x28)"}];
            return NO;
        }
        BOOL cmd = [params[@"cmd"] boolValue];
        BOOL ok = cmd ? doCmdKey(usage) : sendRawKey(usage);
        *note = ok ? [NSString stringWithFormat:@"已发送按键 0x%x", usage] : @"按键发送失败(键盘接口不可用)";
        if (!ok && err) *err = [NSError errorWithDomain:@"PhoneControl" code:13
                                               userInfo:@{NSLocalizedDescriptionKey: @"按键发送失败"}];
        return ok;
    }
    if ([action isEqualToString:@"wait"]) {
        int ms = params[@"ms"] ? [params[@"ms"] intValue] : 1500;
        usleep(ms * 1000);
        *note = [NSString stringWithFormat:@"已等待 %d 毫秒", ms];
        return YES;
    }
    if ([action isEqualToString:@"stop_cast"]) {
        // 任务结束:请扩展自己结束录屏,再用 OCR 找到"直播已停止"提示上的"好"点掉
        // (MiniPaw v1.0.3 的 closeBroadcastAndDismiss;在后台线程跑,不阻塞调用方)。
        // 点掉提示后,前台本来就是 Minis 的聊天界面,任务窗口自然回到眼前。
        PCRequestBroadcastStop();
        *note = @"正在关闭屏幕录制";
        return YES;
    }
    if (err) *err = [NSError errorWithDomain:@"PhoneControl" code:14
                                    userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"不支持的操作 %@ (可用: tap/long_press/swipe/input_text/open_app/press_home/key/wait)", action]}];
    return NO;
}
