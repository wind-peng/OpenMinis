
//
//  ISHKernel.m
//  MinisApp
//
//  STUB — Linux sandbox removed (2026-11-10, user decision).
//
//  The iSH/Alpine sandbox was stripped from this build: no kernel, no
//  rootfs, no guest processes. This file keeps the ISHKernel interface
//  (see ISHKernel.h) compiling so the rest of the app — which still
//  references it from the agent loop, MCP store, sync tracker, diagnostics
//  and the boot sequence — links and runs. Every method is a no-op or
//  returns a safe failure value:
//
//  - isBooted is always NO, so anything that needs the guest (shell
//    execution, MCP servers, sync file-change tracking) correctly refuses
//    instead of crashing.
//  - bootWithRootPath: returns 0 so ensureKernelBooted() completes and the
//    app proceeds; the "boot" installs nothing.
//  - The two native_offload_* C functions below are the only libish
//    symbols the surviving NativeOffloads/*.m files reference. They are
//    defined here so those files still link; nothing calls the offload
//    register functions any more (this stub never calls them), so the
//    handlers are never installed and never run.
//
//  If the sandbox is ever re-enabled, restore the real implementation
//  from the upstream OpenMinis repo (this file is the only iSH source
//  that was stubbed; ISHKernel.h is unchanged).
//

#import "ISHKernel.h"
#import "kernel/native_offload.h"

NSNotificationName const ISHProcessExitedNotification = @"ISHProcessExitedNotification";
NSNotificationName const ISHTerminalOutputNotification = @"ISHTerminalOutputNotification";

@implementation ISHKernel

+ (ISHKernel *)shared {
    static ISHKernel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ISHKernel alloc] init];
    });
    return instance;
}

- (BOOL)isBooted {
    // Sandbox removed: the kernel never boots.
    return NO;
}

- (int)bootWithRootPath:(NSString *)rootPath {
    // No-op: pretend the boot succeeded so ensureKernelBooted() completes
    // and the app proceeds. isBooted stays NO, so nothing that needs the
    // guest will try to use it.
    (void)rootPath;
    return 0;
}

+ (BOOL)isAOJITEnabled {
    return YES;
}

+ (void)setAOJITEnabled:(BOOL)enabled {
    (void)enabled;
}

+ (NSString *)aojitStatusReport {
    return @"Linux sandbox removed from this build — no guest JIT.";
}

- (int)executeCommand:(NSArray<NSString *> *)command {
    (void)command;
    return -1;
}

- (void)executeCommandAndWait:(NSString *)commandString
                      timeout:(NSTimeInterval)timeout
                   completion:(ISHCommandCompletionCallback)completion {
    (void)commandString;
    (void)timeout;
    if (completion) {
        NSError *error = [NSError errorWithDomain:@"MinisSandboxRemoved"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Linux sandbox removed from this build."}];
        completion(@"", error);
    }
}

- (void)sendInput:(NSData *)data {
    (void)data;
}

- (void)sendInputString:(NSString *)input {
    (void)input;
}

- (void)setTerminalSize:(int)columns rows:(int)rows {
    (void)columns;
    (void)rows;
}

- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath {
    (void)linuxPath;
    (void)hostPath;
    return -1;
}

- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath readOnly:(BOOL)readOnly {
    (void)linuxPath;
    (void)hostPath;
    (void)readOnly;
    return -1;
}

- (int)bindUnmountPath:(NSString *)linuxPath {
    (void)linuxPath;
    return -1;
}

- (void)refreshDns {
}

@end

@implementation ISHFakefsChangeEvent
@end

@implementation ISHKernel (FakefsChange)

- (void)installFakefsChangeHandler:(void (^)(NSArray<ISHFakefsChangeEvent *> *batch))handler {
    (void)handler;
}

- (uint64_t)fakefsChangeDroppedCount {
    return 0;
}

@end

@implementation ISHKernel (PathTranslate)

- (void)installPathTranslateHandler:(nullable ISHPathTranslateHandler)handler {
    (void)handler;
}

@end

@implementation ISHKernel (PathReverse)

- (void)installPathReverseHandler:(nullable ISHPathReverseHandler)handler {
    (void)handler;
}

@end

@implementation ISHKernel (Scheduler)

- (void)enableCPUThrottleWithDutyCycle:(float)dutyCycle {
    (void)dutyCycle;
}

- (void)disableCPUThrottle {
}

- (void)beginBackgroundCPUGovernor {
}

- (void)endBackgroundCPUGovernor {
}

- (NSDictionary<NSString *, id> *)backgroundCPUGovernorStatus {
    return @{};
}

- (void)getGuestProcessCount:(int *)processCount anonBytes:(int64_t *)anonBytes {
    if (processCount) *processCount = -1;
    if (anonBytes) *anonBytes = 0;
}

@end

#pragma mark - libish stubs for the surviving native offloads

// NativeOffloads/*.m call these two libish C functions from their
// *_offload_register() functions. The sandbox is gone, so the register
// functions are never called — but the symbols must still exist at link
// time. Both are inert: they record nothing and return success.
int native_offload_add_handler(const char *guest_name, native_handler_func handler) {
    (void)guest_name;
    (void)handler;
    return 0;
}

int native_offload_set_abort_handler(const char *guest_name, native_abort_func abort_fn) {
    (void)guest_name;
    (void)abort_fn;
    return 0;
}
