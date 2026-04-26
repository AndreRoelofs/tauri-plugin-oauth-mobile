// SPDX-License-Identifier: Apache-2.0

package app.tauri.appauth

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/// Invisible activity that catches the OAuth redirect URI declared in the
/// plugin manifest, hands it to the plugin, and finishes immediately. Declared
/// `singleTask` so a fresh redirect always replaces any stale instance.
class RedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        deliver(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliver(intent)
    }

    private fun deliver(intent: Intent?) {
        val uri = intent?.data
        if (uri != null) {
            OAuthSessionPlugin.deliverRedirect(uri)
        } else {
            OAuthSessionPlugin.deliverIntentParseFailure()
        }
        finish()
    }
}
