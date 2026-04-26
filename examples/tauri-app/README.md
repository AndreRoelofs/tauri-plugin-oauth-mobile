# tauri-plugin-appauth example

End-to-end demo of [`@eurora-labs/tauri-plugin-appauth`][pkg] running against
two real OIDC issuers:

- **Google** — your own client, registered through Google Cloud Console.
- **Duende IdentityServer demo** — public sandbox at
  `https://demo.duendesoftware.com`, no signup required.

The page renders three buttons (Sign in (Google), Sign in (Demo OIDC), Sign
out), shows the resulting `AuthState` (truncated tokens), surfaces any
`AppAuthError` codes, and lists `auth-events` as they fire.

## Prerequisites

- [Bun](https://bun.sh)
- [Rust](https://rustup.rs) with the iOS / Android targets installed
- Tauri 2 mobile dev toolchains:
  [iOS](https://v2.tauri.app/start/prerequisites/#ios) /
  [Android](https://v2.tauri.app/start/prerequisites/#android)

## Setup

From the **repository root**, build the plugin's TypeScript bindings — the
example resolves `@eurora-labs/tauri-plugin-appauth` via `file:../..`, which
expects `dist-js/` to exist:

```sh
bun install
bun run build
```

Then in this directory:

```sh
cp .env.example .env
# edit .env with your client IDs
bun install
```

## Configure native redirect schemes

Both AppAuth backends require the redirect URI's scheme to be registered with
the OS so the browser can hand the response back to the app.

### iOS

After running `bun tauri ios init` once, edit
`src-tauri/gen/apple/<app>_iOS/Info.plist` and add the scheme(s):

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>com.googleusercontent.apps.123456-abcdef</string>
      <string>io.identitymodel.native</string>
    </array>
  </dict>
</array>
```

### Android

After running `bun tauri android init` once, set the `appAuthRedirectScheme`
manifest placeholder in `src-tauri/gen/android/app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        manifestPlaceholders["appAuthRedirectScheme"] = "io.identitymodel.native"
    }
}
```

AppAuth-Android ships its own `RedirectUriReceiverActivity`; the manifest
placeholder is all the host app needs to wire it up.

> **Heads up:** Android's `appAuthRedirectScheme` only accepts a single value.
> If you need both Google and Duende schemes simultaneously, declare a second
> intent-filter manually pointing at `RedirectUriReceiverActivity`.

## Run

```sh
bun tauri ios dev      # iOS simulator or device
bun tauri android dev  # Android emulator or device
```

Desktop is unsupported — the plugin rejects every command with
`UNSUPPORTED_PLATFORM` so the page renders but the buttons fail. Use the
mobile targets for actual end-to-end verification.

## Troubleshooting

- **`AUTHORIZATION_FAILED` immediately on launch (Android)** — the
  `appAuthRedirectScheme` placeholder is wrong or missing. AppAuth refuses to
  start the flow when no app handler is registered for the redirect URI.
- **Browser opens but redirect never returns (iOS)** — the URL scheme is not
  in `CFBundleURLSchemes`, or it differs in casing from `redirectUri`.
  AppAuth-iOS validates the scheme is registered before opening the sheet.
- **`USER_CANCELED` after the consent screen (iOS)** —
  `prefersEphemeralSession: true` is the default; with that flag the system
  treats every back-swipe as a cancel. Pass `prefersEphemeralSession: false`
  if you want the persistent Safari cookies experience.

[pkg]: ../../README.md
