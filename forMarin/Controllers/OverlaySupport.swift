import UIKit
import Metal

enum OverlaySupport {
    static func isSupported() -> Bool {
        guard #available(iOS 17.0, *) else { return false }
        guard let _ = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }

    static func checkAndLog() -> Bool {
        var ok = true
        if #available(iOS 17.0, *) {
            // ok
        } else {
            log("overlay.unsupported.os_version min=17.0", category: "P2P")
            ok = false
        }
        let hasScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .contains(where: { $0.activationState == .foregroundActive })
        if !hasScene {
            log("overlay.unsupported.no_active_scene", category: "P2P")
            ok = false
        }
        if MTLCreateSystemDefaultDevice() == nil {
            log("overlay.unsupported.metal", category: "P2P")
            ok = false
        }
        return ok
    }
}
