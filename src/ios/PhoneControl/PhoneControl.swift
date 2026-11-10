// PhoneControl.swift — Swift wrapper around PhoneControlBridge (Obj-C, ported from
// MiniPaw v1.0.2 + v1.0.3 close flow and PhoneAgent v56's safety rules).
// The agent tools (phone_screen / phone_act) call into this; the bridge does the
// actual touch injection, screenshots and OCR.
import Foundation
import UIKit

/// "Eyes + hands" for the Minis agent — see src/ios/PhoneControl/PhoneControlBridge.m.
enum PhoneControl {

    // MARK: - Safety brakes (copied from PhoneAgent v56)

    /// Words that mean the screen is about to take money or a password.
    /// If any of them appears in the screen text, the agent must stop the task
    /// and hand it to the user — never tap through it.
    static let dangerWords = [
        "立即支付", "确认支付", "去支付", "付款", "提交订单", "立即购买",
        "去结算", "结算", "确认付款", "支付密码", "免密支付",
    ]

    /// First word of `dangerWords` found in `text`, or nil.
    static func dangerHit(in text: String) -> String? {
        for word in dangerWords where text.contains(word) { return word }
        return nil
    }

    /// First danger word found near the point (model coords 780x1688, radius ~90px),
    /// using the OCR items from the last capture — or nil.
    static func dangerNear(x: Double, y: Double) -> String? {
        guard let items = PCLastOCRItems() as? [[String: Any]] else { return nil }
        let kx = 780.0 / UIScreen.main.bounds.width
        let ky = 1688.0 / UIScreen.main.bounds.height
        for item in items {
            guard let text = item["text"] as? String,
                  let px = item["x"] as? Double, let py = item["y"] as? Double,
                  let w = item["w"] as? Double, let h = item["h"] as? Double else { continue }
            let mx = px * kx, my = py * ky, mw = w * kx, mh = h * ky
            let dx = max(0, abs(x - mx) - mw / 2), dy = max(0, abs(y - my) - mh / 2)
            if dx < 90 && dy < 90, let hit = dangerHit(in: text) { return hit }
        }
        return nil
    }

    // MARK: - Stuck-screen detection (4 unchanged screens → stop)

    private static var lastSignature: String?
    private static var unchangedCount = 0

    /// Feed the signature of the latest capture; returns how many consecutive
    /// captures have been identical. The agent loop stops the task at 4.
    static func noteFrameSignature(_ signature: String) -> Int {
        if signature == lastSignature { unchangedCount += 1 } else { unchangedCount = 0 }
        lastSignature = signature
        return unchangedCount
    }

    static func resetStuckDetection() {
        lastSignature = nil
        unchangedCount = 0
    }

    // MARK: - Task lifecycle (task start = auto-start broadcast, task end = close it)
    //
    // One runAgentLoop invocation = one task. The loop calls beginTask() at the
    // start and endTask() on every exit (defer, so finish / error / cancel all
    // count). The phone tool handlers set phoneUsedThisTask; endTask() closes
    // the recording only when the task actually used the phone tools.
    //
    // The auto-start is attempted at most once per task (plus one retry if the
    // broadcast was alive and then died mid-task, e.g. closed by a helper).
    // A failed attempt is NOT retried every call: re-popping the system panel
    // after the user dismissed it would be worse than asking once.

    private static let stateLock = NSLock()
    private static var autoStartAttemptedThisTask = false
    private static var broadcastSeenAliveThisTask = false
    private static var phoneUsedThisTask = false

    /// Called by runAgentLoop at task start. Resets the auto-start budget;
    /// phoneUsedThisTask is left alone so a resumed run keeps the flag from
    /// the part before the interruption (endTask always clears it).
    static func beginTask() {
        stateLock.lock(); defer { stateLock.unlock() }
        autoStartAttemptedThisTask = false
        broadcastSeenAliveThisTask = false
        resetStuckDetection()
    }

    /// Called by runAgentLoop on every exit (defer). If the task used the
    /// phone tools, close the recording by itself (v1.0.3 close flow:
    /// extension ends itself, OCR-locate "好", tap it, back to the chat
    /// window) and clear the per-task state.
    static func endTask() {
        stateLock.lock()
        let used = phoneUsedThisTask
        phoneUsedThisTask = false
        autoStartAttemptedThisTask = false
        broadcastSeenAliveThisTask = false
        stateLock.unlock()
        resetStuckDetection()
        if used { requestBroadcastStop() }
    }

    static func markPhoneUsed() {
        stateLock.lock(); defer { stateLock.unlock() }
        phoneUsedThisTask = true
    }

    /// First phone tool call of the task, when the broadcast is off: try to
    /// start it automatically (blind-tap "开始直播", then dismiss the panel
    /// back to the Minis UI). Returns (attempted, ok, note). When the
    /// broadcast is already on this is a no-op returning (false, true, nil).
    static func ensureBroadcastIfNeeded() -> (attempted: Bool, ok: Bool, note: String?) {
        stateLock.lock()
        if broadcastAlive {
            broadcastSeenAliveThisTask = true
            stateLock.unlock()
            return (false, true, nil)
        }
        if autoStartAttemptedThisTask && !broadcastSeenAliveThisTask {
            stateLock.unlock()
            return (false, false, nil)
        }
        autoStartAttemptedThisTask = true
        broadcastSeenAliveThisTask = false
        stateLock.unlock()
        let (ok, note) = ensureBroadcast()
        if ok {
            stateLock.lock(); broadcastSeenAliveThisTask = true; stateLock.unlock()
        }
        return (true, ok, note)
    }

    // MARK: - Lifecycle

    static func startup() { PCStartup() }
    static var hidReady: Bool { PCHIDReady() }
    static var broadcastAlive: Bool { PCBroadcastAlive() }
    static func appDidEnterBackground() { PCAppDidEnterBackground() }
    static func appDidBecomeActive() { PCAppDidBecomeActive() }

    /// Ask the broadcast extension to finish and dismiss the "直播已停止" prompt
    /// (v1.0.3 close flow, runs in the background). Call when a phone task ends.
    static func requestBroadcastStop() { PCRequestBroadcastStop() }

    /// Start screen recording automatically (blind-tap "开始直播" in the system panel).
    /// Returns (success, note). Manual alternative: Control Center → long-press
    /// Screen Recording → pick Minis → Start Broadcast.
    static func ensureBroadcast() -> (Bool, String) {
        var note: String?
        let ok = PCEnsureBroadcast(&note)
        return (ok, note ?? (ok ? "已自动开启屏幕录制" : "无法自动开启屏幕录制"))
    }

    // MARK: - Capture

    struct ScreenCapture {
        let jpeg: Data
        /// "[1] (x,y) text" lines, model coords 780x1688, max 80 items.
        let ocrText: String
        let items: [[String: Any]]
        let signature: String
        let method: String
    }

    /// One screenshot + OCR, or nil + error message.
    static func capture() -> (ScreenCapture?, String?) {
        var err: NSError?
        guard let dict = PCCaptureScreen(&err) as? [String: Any],
              let jpeg = dict["jpeg"] as? Data,
              let ocrText = dict["ocrText"] as? String,
              let items = dict["items"] as? [[String: Any]],
              let signature = dict["signature"] as? String else {
            return (nil, err?.localizedDescription ?? "截屏失败")
        }
        let method = dict["method"] as? String ?? ""
        return (ScreenCapture(jpeg: jpeg, ocrText: ocrText, items: items,
                              signature: signature, method: method), nil)
    }

    // MARK: - Actions

    /// Execute one phone action (model coords 780x1688, or OCR id).
    /// Returns (success, note or error message).
    static func perform(action: String, params: [String: Any]) -> (Bool, String) {
        var note: String?
        var err: NSError?
        let ok = PCPerformAction(action, params as NSDictionary, &note, &err)
        if ok { return (true, note ?? "已执行") }
        return (false, err?.localizedDescription ?? note ?? "操作失败")
    }
}
