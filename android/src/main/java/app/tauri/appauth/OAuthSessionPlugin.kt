// SPDX-License-Identifier: Apache-2.0

package app.tauri.appauth

import android.app.Activity
import app.tauri.annotation.Command
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.Plugin
import net.openid.appauth.AuthorizationService

/**
 * Tauri bridge over AppAuth-Android. Per-command bodies land in phase 5 of the
 * rewrite plan; for now every command rejects with `NOT_IMPLEMENTED` so the
 * native target compiles against the new dependency surface.
 */
@TauriPlugin
class OAuthSessionPlugin(activity: Activity) : Plugin(activity) {

    // Lazily instantiated by per-command handlers (phase 5) and disposed here
    // so Custom Tabs connections are released on activity teardown.
    private var authService: AuthorizationService? = null

    override fun onDestroy() {
        authService?.dispose()
        authService = null
        super.onDestroy()
    }

    @Command
    fun discover(invoke: Invoke) {
        invoke.reject("discover is not implemented yet", ERROR_NOT_IMPLEMENTED)
    }

    @Command
    fun register(invoke: Invoke) {
        invoke.reject("register is not implemented yet", ERROR_NOT_IMPLEMENTED)
    }

    @Command
    fun authorize(invoke: Invoke) {
        invoke.reject("authorize is not implemented yet", ERROR_NOT_IMPLEMENTED)
    }

    @Command
    fun authorizeBrowserOnly(invoke: Invoke) {
        invoke.reject("authorizeBrowserOnly is not implemented yet", ERROR_NOT_IMPLEMENTED)
    }

    @Command
    fun refresh(invoke: Invoke) {
        invoke.reject("refresh is not implemented yet", ERROR_NOT_IMPLEMENTED)
    }

    @Command
    fun endSession(invoke: Invoke) {
        invoke.reject("endSession is not implemented yet", ERROR_NOT_IMPLEMENTED)
    }

    private companion object {
        const val ERROR_NOT_IMPLEMENTED = "NOT_IMPLEMENTED"
    }
}
