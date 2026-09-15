//
//  NDIFinder.swift
//  OpenBeam
//
//  Discovery of NDI sources on the local network.
//

import Foundation

/// Lives only while the menu is open: discovery keeps a socket and a thread
/// inside libndi, and the list it produces is only ever read to build a menu.
final class NDIFinder: @unchecked Sendable {

    private var instance: NDIlib_find_instance_t?
    /// libndi forbids calling `NDIlib_find_get_current_sources` concurrently
    /// for one instance, so every touch of the handle goes through here.
    private let queue = DispatchQueue(label: "com.openbeam.ndi-find")

    func start() {
        // Async: `NDIlib_initialize` and the discovery socket set-up are libndi
        // work, and this runs from `menuWillOpen` on the main thread. The queue
        // is serial, so a `sources` read still sees a finished start.
        queue.async {
            guard self.instance == nil, NDIRuntime.retain() else { return }

            var settings = NDIlib_find_create_t()
            settings.show_local_sources = true
            settings.p_groups = nil
            settings.p_extra_ips = nil

            guard let created = NDIlib_find_create_v2(&settings) else {
                print("[OpenBeam] NDIlib_find_create_v2 failed")
                NDIRuntime.release()
                return
            }
            self.instance = created
        }
    }

    func stop() {
        queue.async {
            guard let instance = self.instance else { return }
            NDIlib_find_destroy(instance)
            self.instance = nil
            NDIRuntime.release()
        }
    }

    /// The sources discovered so far, by NDI name. Returns whatever libndi has
    /// at this instant; discovery keeps filling in for a second or two after
    /// `start()`, which is why the menu re-reads it on every open.
    var sources: [String] {
        queue.sync {
            guard let instance else { return [] }

            var count: UInt32 = 0
            guard let list = NDIlib_find_get_current_sources(instance, &count) else { return [] }

            // The array belongs to the finder and is valid only until the next
            // call, so the names are copied out here rather than handed on.
            return (0..<Int(count)).compactMap { index in
                list[index].p_ndi_name.map { String(cString: $0) }
            }
        }
    }

    deinit {
        // Not `stop()`: its async block would capture a deallocating object.
        // Nothing can be running on the queue either — every block there
        // retains self, so deinit cannot be reached while one is pending.
        if let instance {
            NDIlib_find_destroy(instance)
            NDIRuntime.release()
        }
    }
}
