
//
//  RootfsManager.swift
//  MinisApp
//
//  STUB — Linux sandbox removed (2026-11-10, user decision).
//
//  The iSH/Alpine rootfs was stripped from this build: no rootfs zip in
//  the bundle, no guest filesystem, no fakefs meta.db. This file keeps
//  the RootfsManager interface compiling — dataPath/rootfsPath are still
//  used for host-path resolution, installIfNeeded() is still called by
//  the boot sequence, and several features still call the metadata
//  helpers — but every operation is now a no-op that reports "not
//  installed". Callers that need the guest (shell execution, MCP
//  servers, sync file-change tracking) already refuse when
//  ISHKernel.shared.isBooted is NO, so the no-ops below are never on a
//  live path.
//
//  Paths are kept identical to the original (Documents/alpine-rootfs)
//  so any host-path resolution that points there keeps behaving the
//  same (files simply do not exist there any more).
//
//  If the sandbox is ever re-enabled, restore the real implementation
//  from the upstream OpenMinis repo.
//

import Foundation

class RootfsManager {
    static let shared = RootfsManager()

    /// Set once reset() deletes the rootfs directory from disk. Never set
    /// in this build (there is no rootfs to reset).
    private(set) var didResetWhileBooted = false

    private init() {}

    var rootfsPath: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("alpine-rootfs")
    }

    var dataPath: URL {
        return rootfsPath.appendingPathComponent("data")
    }

    /// No rootfs is ever installed in this build.
    var isInstalled: Bool {
        return false
    }

    /// No-op: there is no rootfs zip to install.
    func installIfNeeded() throws {
    }

    /// No-op: there is no rootfs to reset and no user data to back up.
    func reset(keepUserData: Bool = false) throws -> URL? {
        return nil
    }

    /// No-op: there is no user data to restore.
    func restoreUserData(from backupURL: URL) throws {
    }

    /// No-op: there is no overlay bundle to apply.
    func applyDefaultMountOverlay() {
    }

    /// No-op: there is no guest filesystem to stage files into.
    func stageFiles(from dir: URL, toLinuxDir linuxDir: String) throws {
    }

    /// No-op: there is no fakefs meta.db to register paths in.
    func ensureFakefsMetadata(for linuxPath: String, isDirectory: Bool, mode: UInt32? = nil) {
    }

    /// No-op: there is no fakefs meta.db to register parent dirs in.
    func ensureParentDirsInMetaDB(for linuxPath: String) {
    }

    /// No-op: there is no fakefs path to remove.
    func removeFakefsPath(_ linuxPath: String) {
    }

    /// No-op: there is no fakefs meta.db to register a subtree in.
    func registerSubtreeInMetaDB(hostRoot: URL) {
    }

    /// No rootfs on disk in this build.
    func getRootfsSize() throws -> Int64 {
        return 0
    }
}
