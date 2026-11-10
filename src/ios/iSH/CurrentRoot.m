
//
//  CurrentRoot.m
//  Minis — adapted from iSH app/CurrentRoot.m
//
//  STUB — Linux sandbox removed (2026-11-10, user decision).
//
//  FsApplyOverlay used to apply rootfs patches from RootfsPatch.bundle
//  into the guest filesystem on boot. With no guest filesystem there is
//  nothing to patch; the function is a no-op so the boot sequence keeps
//  compiling. If the sandbox is ever re-enabled, restore the real
//  implementation from the upstream OpenMinis repo.
//

#import "CurrentRoot.h"

void FsApplyOverlay(void) {
    // Sandbox removed: nothing to apply.
}
