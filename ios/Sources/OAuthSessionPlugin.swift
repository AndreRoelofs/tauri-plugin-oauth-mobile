// SPDX-License-Identifier: Apache-2.0

import AppAuth
import Tauri
import UIKit

/// Tauri bridge over AppAuth-iOS. Per-command bodies land in phase 4 of the
/// rewrite plan; for now every command rejects with `NOT_IMPLEMENTED` so the
/// native target compiles against the new dependency surface.
class OAuthSessionPlugin: Plugin {
    /// Active AppAuth user-agent flow. Retained while a browser sheet or token
    /// exchange is outstanding so AppAuth can drive it to completion or
    /// cancellation.
    private var currentSession: OIDExternalUserAgentSession?

    @objc public func discover(_ invoke: Invoke) {
        invoke.reject("discover is not implemented yet", code: "NOT_IMPLEMENTED")
    }

    @objc public func register(_ invoke: Invoke) {
        invoke.reject("register is not implemented yet", code: "NOT_IMPLEMENTED")
    }

    @objc public func authorize(_ invoke: Invoke) {
        invoke.reject("authorize is not implemented yet", code: "NOT_IMPLEMENTED")
    }

    @objc public func authorizeBrowserOnly(_ invoke: Invoke) {
        invoke.reject("authorizeBrowserOnly is not implemented yet", code: "NOT_IMPLEMENTED")
    }

    @objc public func refresh(_ invoke: Invoke) {
        invoke.reject("refresh is not implemented yet", code: "NOT_IMPLEMENTED")
    }

    @objc public func endSession(_ invoke: Invoke) {
        invoke.reject("endSession is not implemented yet", code: "NOT_IMPLEMENTED")
    }
}

@_cdecl("init_plugin_oauth_session")
func initPlugin() -> Plugin {
    return OAuthSessionPlugin()
}
