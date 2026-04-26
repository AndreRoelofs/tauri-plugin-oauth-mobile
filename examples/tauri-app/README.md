# tauri-plugin-appauth example

End-to-end demo of [`@eurora-labs/tauri-plugin-appauth`][pkg] running against
two real OIDC issuers:

- **Google** — your own client, registered through Google Cloud Console.
- **Duende IdentityServer demo** — public sandbox at
  `https://demo.duendesoftware.com`, no signup required.

The page renders three buttons (Sign in (Google), Sign in (Demo OIDC), Sign
out), shows the resulting `AuthState` (truncated tokens), surfaces any
`AppAuthError` codes, and lists `auth-events` as they fire.

The iOS and Android scaffolds (`src-tauri/gen/apple/`,
`src-tauri/gen/android/`) are committed so a fresh clone can run
`bun run dev:ios` / `bun run dev:android` without first invoking
`tauri (ios|android) init`.

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

## Run

```sh
bun run dev:ios      # iOS simulator (default) or attached device
bun run dev:android  # Android emulator or attached device
```

Desktop is unsupported — the plugin rejects every command with
`UNSUPPORTED_PLATFORM` so the page renders but the buttons fail. Use the
mobile targets for actual end-to-end verification.

### iOS code signing

The committed Xcode project deliberately ships **without** an Apple Developer
team id so this public repository can be cloned without leaking signing
credentials.

- **iOS Simulator** works zero-config — `bun run dev:ios` will build, install,
  and boot the simulator without ever prompting for a team.
- **Physical iOS device** requires a one-time setup: open
  `src-tauri/gen/apple/tauri-app-example.xcodeproj` in Xcode, select the
  `tauri-app-example_iOS` target, switch to *Signing & Capabilities*, and
  pick your Apple Developer team. Xcode persists the choice in
  `xcuserdata/`, which is `.gitignore`d, so it never lands in commits.

The example's bundle id is `com.appauth.example`. If you publish your fork
to the App Store, change it in `src-tauri/tauri.conf.json` (and reflect the
new id in your provider's authorized redirect URIs).

## Configured redirect schemes

The committed scaffolds register schemes for the two demo issuers up front.

### iOS — `src-tauri/gen/apple/project.yml`

`CFBundleURLTypes` declares both schemes; `xcodegen` propagates them into
`Info.plist` on every `tauri ios dev` / `tauri ios build`:

```yaml
CFBundleURLTypes:
  - CFBundleURLName: com.appauth.example.duende
    CFBundleURLSchemes:
      - io.identitymodel.native
  - CFBundleURLName: com.appauth.example.google
    CFBundleURLSchemes:
      - com.googleusercontent.apps.REPLACE_WITH_YOUR_GOOGLE_CLIENT_ID
```

Replace the Google scheme with your own reverse-DNS client id from Google
Cloud Console (the format is `com.googleusercontent.apps.<numeric>-<hash>`).

### Android — `src-tauri/gen/android/app/build.gradle.kts`

AppAuth-Android merges its own `RedirectUriReceiverActivity` into the host
app's manifest, with the redirect scheme supplied via a `manifestPlaceholder`:

```kotlin
defaultConfig {
    manifestPlaceholders["appAuthRedirectScheme"] = "io.identitymodel.native"
}
```

> **Heads up:** Android's `appAuthRedirectScheme` placeholder only accepts a
> single value. To run the Google flow on Android instead of (or alongside)
> the Duende demo, swap the placeholder for your reverse-DNS client id, or
> declare a second intent-filter on `RedirectUriReceiverActivity` in
> `src-tauri/gen/android/app/src/main/AndroidManifest.xml`.

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
- **Xcode error `Signing for "tauri-app-example_iOS" requires a development team`**
  — see [iOS code signing](#ios-code-signing) above; the simulator path
  doesn't require this, devices do.

[pkg]: ../../README.md
