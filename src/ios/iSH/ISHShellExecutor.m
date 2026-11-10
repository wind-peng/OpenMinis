
//
//  ISHShellExecutor.m
//  MinisApp
//
//  STUB — Linux sandbox removed (2026-11-10, user decision).
//
//  The iSH/Alpine sandbox was stripped from this build, so no guest
//  process can ever be spawned. This file keeps the ISHShellExecutor
//  interface (see ISHShellExecutor.h) compiling: ISHExecutionCoordinator
//  still calls killProcess/killProcessGroup and bridges the callback API,
//  and the (now unreachable) shell-execution path still references the
//  execute methods. Every execute call fails fast with a clear error;
//  kill/finalize calls are no-ops.
//
//  If the sandbox is ever re-enabled, restore the real implementation
//  from the upstream OpenMinis repo (this file was stubbed;
//  ISHShellExecutor.h is unchanged).
//

#import "ISHShellExecutor.h"
#import "ISHKernel.h"

static NSString *const kSandboxRemovedMessage = @"Linux sandbox removed from this build.";

@interface ISHShellExecutionResult ()
- (instancetype)initWithExitCode:(int)exitCode
                             pid:(int)pid
                           error:(ISHShellExecutorError)error
                          output:(NSString *)output
                     errorOutput:(NSString *)errorOutput
                        duration:(NSTimeInterval)duration;
@end

@implementation ISHShellExecutionResult

- (instancetype)initWithExitCode:(int)exitCode
                             pid:(int)pid
                           error:(ISHShellExecutorError)error
                          output:(NSString *)output
                     errorOutput:(NSString *)errorOutput
                        duration:(NSTimeInterval)duration {
    self = [super init];
    if (self) {
        _exitCode = exitCode;
        _pid = pid;
        _error = error;
        _output = [output copy];
        _errorOutput = [errorOutput copy];
        _duration = duration;
    }
    return self;
}

@end

@implementation ISHShellExecutor

+ (ISHShellExecutionResult *)sandboxRemovedResult {
    return [[ISHShellExecutionResult alloc] initWithExitCode:-1
                                                         pid:-1
                                                       error:ISHShellExecutorErrorProcessCreationFailed
                                                      output:kSandboxRemovedMessage
                                                 errorOutput:@""
                                                    duration:0];
}

+ (int)executeCommand:(NSString *)command
         lineCallback:(nullable ISHShellLineCallback)lineCallback
           completion:(nullable ISHShellCompletionCallback)completion {
    (void)command;
    (void)lineCallback;
    if (completion) completion([self sandboxRemovedResult]);
    return -1;
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion {
    (void)executable;
    (void)arguments;
    (void)environment;
    (void)lineCallback;
    if (completion) completion([self sandboxRemovedResult]);
    return -1;
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
               stdinData:(nullable NSData *)stdinData
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion {
    (void)executable;
    (void)arguments;
    (void)environment;
    (void)stdinData;
    (void)lineCallback;
    if (completion) completion([self sandboxRemovedResult]);
    return -1;
}

+ (int)executeExecutable:(NSString *)executable
               arguments:(nullable NSArray<NSString *> *)arguments
             environment:(nullable NSDictionary<NSString *, NSString *> *)environment
               stdinData:(nullable NSData *)stdinData
               fsContext:(uint64_t)fsContext
            lineCallback:(nullable ISHShellLineCallback)lineCallback
              completion:(nullable ISHShellCompletionCallback)completion {
    (void)executable;
    (void)arguments;
    (void)environment;
    (void)stdinData;
    (void)fsContext;
    (void)lineCallback;
    if (completion) completion([self sandboxRemovedResult]);
    return -1;
}

+ (ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                        timeout:(NSTimeInterval)timeout
                                   lineCallback:(nullable ISHShellLineCallback)lineCallback {
    (void)command;
    (void)timeout;
    (void)lineCallback;
    return [self sandboxRemovedResult];
}

+ (BOOL)killProcess:(int)pid withSignal:(int)signal {
    (void)pid;
    (void)signal;
    return NO;
}

+ (void)killProcessGroup:(int)pid {
    (void)pid;
}

+ (void)finalizeTimedOutPid:(int)pid {
    (void)pid;
}

+ (NSString *)leakGuardStatus {
    return @"activeExecutions=0 liveReaders=0 sweptContexts=0";
}

+ (NSString *)decodeShellOutputFromPending:(NSMutableData *)pending isFinal:(BOOL)isFinal {
    // Pure UTF-8 decode of the buffered bytes (no iSH state). The sandbox
    // is gone, so this only ever sees an empty buffer in practice; keep
    // the original contract anyway: decode the decodable prefix, leave an
    // incomplete multi-byte sequence at the end for the next read unless
    // this is the final flush.
    if (pending.length == 0) return @"";
    const uint8_t *bytes = (const uint8_t *)pending.bytes;
    NSUInteger len = pending.length;
    NSUInteger decodableLen = len;
    if (!isFinal) {
        // If the tail looks like an incomplete UTF-8 sequence (up to 3
        // trailing continuation bytes), hold it back.
        NSUInteger cont = 0;
        while (cont < len && cont < 3 && (bytes[len - 1 - cont] & 0xC0) == 0x80) cont++;
        if (cont > 0 && cont < len) {
            uint8_t lead = bytes[len - 1 - cont];
            NSUInteger need = 0;
            if ((lead & 0xE0) == 0xC0) need = 1;
            else if ((lead & 0xF0) == 0xE0) need = 2;
            else if ((lead & 0xF8) == 0xF0) need = 3;
            if (need > 0 && cont < need) decodableLen = len - cont - 1;
        }
    }
    NSData *chunk = [pending subdataWithRange:NSMakeRange(0, decodableLen)];
    NSString *text = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding];
    if (!text) {
        text = [[NSString alloc] initWithData:chunk encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    [pending replaceBytesInRange:NSMakeRange(0, decodableLen) withBytes:NULL length:0];
    return text;
}

@end
