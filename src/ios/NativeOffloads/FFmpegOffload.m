
//
//  FFmpegOffload.m
//  MinisApp
//
//  STUB — Linux sandbox removed (2026-11-10, user decision).
//
//  The ffmpeg native offload routed iSH `ffmpeg` commands to the linked
//  FFmpeg library. With no guest shell there is no `ffmpeg` command to
//  route, and the FFmpeg frameworks are no longer built or linked — so
//  this file keeps only the registration entry point as a no-op. It is
//  never called (the stub ISHKernel never registers offloads), but the
//  symbol must exist because the bridging header declares it.
//
//  If the sandbox is ever re-enabled, restore the real implementation
//  from the upstream OpenMinis repo.
//

#import "FFmpegOffload.h"

void ffmpeg_offload_register(void) {
    // Sandbox removed: no guest ffmpeg to route.
}
