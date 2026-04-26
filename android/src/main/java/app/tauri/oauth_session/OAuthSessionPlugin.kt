// SPDX-License-Identifier: Apache-2.0

package app.tauri.oauth_session

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.core.net.toUri
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin

@InvokeArg
class AuthenticateArgs {
    lateinit var authUrl: String
    lateinit var callbackScheme: String

    // Honored on iOS via ASWebAuthenticationSession; ignored on Android because
    // Custom Tabs always shares cookies with the user's default browser. The
    // field is kept in the args schema so the JS payload remains identical
    // across platforms.
    var prefersEphemeralSession: Boolean? = null
}

@TauriPlugin
class OAuthSessionPlugin(private val activity: Activity) : Plugin(activity) {

    // The first onResume after launchUrl() fires while the host activity is
    // still in the foreground (Custom Tabs is a separate task that hasn't yet
    // taken over). Skip exactly that one resume; the next one without a
    // redirect having arrived is the real cancel signal.
    private var skipNextResume = false

    override fun onResume() {
        super.onResume()
        synchronized(stateLock) {
            val invoke = pendingInvoke ?: return
            if (skipNextResume) {
                skipNextResume = false
                return
            }
            // Custom Tabs was dismissed without delivering a redirect.
            pendingInvoke = null
            invoke.reject(
                "user canceled the authentication session",
                ERROR_USER_CANCELED,
            )
        }
    }

    @Command
    fun authenticate(invoke: Invoke) {
        val args = try {
            invoke.parseArgs(AuthenticateArgs::class.java)
        } catch (ex: Exception) {
            invoke.reject(
                "failed to parse authenticate arguments",
                ERROR_SESSION_FAILED,
                ex,
            )
            return
        }

        val url = try {
            args.authUrl.toUri()
        } catch (_: Exception) {
            invoke.reject("invalid auth URL", ERROR_INVALID_AUTH_URL)
            return
        }
        if (url.scheme.isNullOrEmpty()) {
            invoke.reject("invalid auth URL", ERROR_INVALID_AUTH_URL)
            return
        }

        val scheme = args.callbackScheme
        if (scheme.isEmpty() || scheme.contains(':') || scheme.contains('/')) {
            invoke.reject("invalid callback scheme", ERROR_INVALID_CALLBACK_SCHEME)
            return
        }

        activity.runOnUiThread {
            synchronized(stateLock) {
                if (pendingInvoke != null) {
                    invoke.reject(
                        "an authentication session is already in progress",
                        ERROR_SESSION_BUSY,
                    )
                    return@runOnUiThread
                }
                pendingInvoke = invoke
                skipNextResume = true
            }

            val tabs = CustomTabsIntent.Builder().build()
            try {
                tabs.launchUrl(activity, url)
            } catch (ex: ActivityNotFoundException) {
                synchronized(stateLock) {
                    pendingInvoke = null
                    skipNextResume = false
                }
                invoke.reject(
                    "no Custom Tabs-capable browser is available",
                    ERROR_PRESENTATION_FAILED,
                    ex,
                )
            } catch (ex: Exception) {
                synchronized(stateLock) {
                    pendingInvoke = null
                    skipNextResume = false
                }
                invoke.reject(ex.message, ERROR_SESSION_FAILED, ex)
            }
        }
    }

    companion object {
        const val ERROR_USER_CANCELED = "USER_CANCELED"
        const val ERROR_PRESENTATION_FAILED = "PRESENTATION_FAILED"
        const val ERROR_SESSION_FAILED = "SESSION_FAILED"
        const val ERROR_SESSION_BUSY = "SESSION_BUSY"
        const val ERROR_INVALID_AUTH_URL = "INVALID_AUTH_URL"
        const val ERROR_INVALID_CALLBACK_SCHEME = "INVALID_CALLBACK_SCHEME"

        // RedirectActivity has no handle to the active Plugin instance, so it
        // routes the captured URI through these statics. The plugin is a
        // process-wide singleton in practice (one Tauri webview per app), so
        // a single slot is sufficient.
        private val stateLock = Any()
        private var pendingInvoke: Invoke? = null

        /// Called by RedirectActivity once it captures the redirect intent.
        fun deliverRedirect(uri: Uri) {
            val invoke = synchronized(stateLock) {
                pendingInvoke.also { pendingInvoke = null }
            } ?: return

            val response = JSObject().apply { put("url", uri.toString()) }
            invoke.resolve(response)
        }

        /// Called by RedirectActivity when an intent without data is received.
        fun deliverIntentParseFailure() {
            val invoke = synchronized(stateLock) {
                pendingInvoke.also { pendingInvoke = null }
            } ?: return

            invoke.reject(
                "the authentication session returned no callback URL",
                ERROR_SESSION_FAILED,
            )
        }
    }
}
