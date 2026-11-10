// PhoneControlBridge.h — C interface between Swift (Minis agent tools) and the
// Obj-C "eyes + hands" ported from MiniPaw (which itself was ported from PhoneAgent).
// All functions are safe to call from the main actor; the bridge does its own
// main-queue hops where UIKit requires it (pasteboard writes).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One-time startup, safe to call repeatedly: loadHID + loadShot, start the
/// broadcast-frame server on 127.0.0.1:8310, create the hidden broadcast picker,
/// and activate the silent keepalive audio in the foreground (if enabled).
/// Call once from MinisApp.init().
void PCStartup(void);

/// Is the IOHID touch-injection client ready (loadHID succeeded)?
BOOL PCHIDReady(void);

/// Is the ReplayKit broadcast extension currently streaming frames (heartbeat < 6s)?
BOOL PCBroadcastAlive(void);

/// Capture the current screen and return a model-ready package, or nil + *err:
///   @"jpeg"      NSData — 780x1688 red-grid JPEG the model looks at
///   @"ocrText"   NSString — "[1] (x,y) text\n..." list in 780x1688 coords (max 80)
///   @"items"     NSArray of @{@"id": NSNumber, @"x": NSNumber, @"y": NSNumber,
///                              @"w": NSNumber, @"h": NSNumber, @"text": NSString}
///                              (model coords; x/y are the centre point)
///   @"signature" NSString — frame signature for stuck-screen detection
///   @"method"    NSString — which screenshot method worked (R/A/B/C/D)
NSDictionary * _Nullable PCCaptureScreen(NSError **err);

/// Execute one phone action. Coordinates in params are MODEL coordinates
/// (780x1688 screenshot space); the bridge converts to screen pt and clamps.
/// action: tap, long_press, swipe, input_text, open_app, press_home, key, wait.
/// params keys: x, y, x2, y2 (NSNumber, model coords), id (NSNumber, OCR id),
/// text (NSString), name (NSString, app name), direction (NSString
/// up/down/left/right), ms (NSNumber), usage (NSNumber or NSString hex),
/// cmd (NSNumber BOOL). On success returns YES and *note describes the result.
/// On refusal/failure returns NO and *err explains why.
BOOL PCPerformAction(NSString *action, NSDictionary *params, NSString * _Nullable * _Nullable note, NSError **err);

/// Resolve an OCR id from the last capture to screen pt coordinates.
BOOL PCPointForOCRId(NSInteger ocrId, double *outX, double *outY);

/// Last capture's OCR items in MODEL coordinates (same shape as PCCaptureScreen items).
NSArray *PCLastOCRItems(void);

/// Start screen recording automatically (blind-tap "开始直播" in the system panel).
/// Returns YES once the broadcast is alive. Manual alternative: Control Center →
/// long-press Screen Recording → pick Minis → Start Broadcast.
BOOL PCEnsureBroadcast(NSString * _Nullable * _Nullable note);

/// Ask the broadcast extension to finish (used when a task ends).
void PCRequestBroadcastStop(void);

/// Background/foreground transitions for the keepalive audio.
void PCAppDidEnterBackground(void);
void PCAppDidBecomeActive(void);

NS_ASSUME_NONNULL_END
