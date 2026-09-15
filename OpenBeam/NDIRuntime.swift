//
//  NDIRuntime.swift
//  OpenBeam
//
//  Shared ownership of the NDI library's process-wide init and teardown.
//

import Foundation
import os

/// `NDIlib_destroy()` tears the library down for the whole process, so the
/// sender cannot own it once a finder and a receiver run alongside it: a mode
/// switch that stops the sender would pull the library out from under them.
/// Every user takes a reference here and drops it when done; the last one out
/// destroys.
enum NDIRuntime {

    private static let users = OSAllocatedUnfairLock(initialState: 0)

    /// Returns false when the library is unavailable, in which case no
    /// reference is held and the caller must not proceed.
    static func retain() -> Bool {
        users.withLock { count in
            if count == 0 {
                guard NDIlib_initialize() else {
                    print("[OpenBeam] NDIlib_initialize failed")
                    return false
                }
            }
            count += 1
            return true
        }
    }

    static func release() {
        users.withLock { count in
            guard count > 0 else { return }
            count -= 1
            if count == 0 {
                NDIlib_destroy()
            }
        }
    }
}
