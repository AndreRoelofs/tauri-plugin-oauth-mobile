# Rewrite Plan: AppAuth-Backed Tauri Mobile OAuth Plugin

## 0. Premise & framing

Today this plugin is a thin, hand-rolled wrapper around `ASWebAuthenticationSession` (iOS) and `androidx.browser.customtabs.CustomTabsIntent` (Android) that returns the raw redirect URL to the caller. The caller is responsible for PKCE, `state`/`nonce` generation, code exchange, token storage, refresh, and discovery. That is "half an OAuth client" — and the half that's hardest to get right is the half we're skipping.

The OpenID Foundation's **AppAuth** SDKs (`AppAuth-iOS`, `AppAuth-Android`) are the reference RFC 8252 ("OAuth 2.0 for Native Apps") implementations. They handle PKCE S256, dynamic client registration (RFC 7591), discovery (RFC 8414 + OIDC), authorization, token exchange, refresh, and end-session. They are the standard primitive that `react-native-app-auth`, Capacitor's first-class OAuth plugins, and most production mobile apps build on.

**The rewrite turns this plugin into a thin Tauri bridge over AppAuth on both platforms**, exposing the full OAuth/OIDC surface as the *idiomatic* API while keeping a low-level "browser session only" escape hatch for backend-mediated flows (Eurora's current shape). All hand-rolled session/state-machine code is deleted. AppAuth becomes the source of truth.

This plan does **not** preserve the current public API. It is a clean break.

## 1. Goals & non-goals

### Goals

1. Single Tauri 2 plugin, one Rust crate, one iOS Swift package, one Android Gradle module — supports both mobile platforms with feature parity.
2. AppAuth (`net.openid:appauth-android` ≥ 0.11.1, `AppAuth/AppAuth` ≥ 1.7.6 SwiftPM) is the *only* OAuth implementation. We write **no** PKCE, state, nonce, code-exchange, refresh, or discovery code ourselves.
3. Idiomatic Tauri 2 mobile-plugin shape: `tauri-plugin` build macro, per-command permissions, `run_mobile_plugin` IPC, `Channel` for streaming events, generated TS bindings.
4. Strongly-typed Rust + TS API. PKCE on by default (cannot be disabled). `state`/`nonce` validated by AppAuth before we ever return success.
5. Persists AppAuth's `AuthState` across process death (required for Android — the OS may kill us while Custom Tabs is foregrounded).
6. Real TS package: `dist-js/`, ESM + CJS + IIFE, `.d.ts`, no name/identity drift between `Cargo.toml`, `package.json`, and `README.md`.
7. Working example app that exercises the real plugin end-to-end against a public OIDC provider.
8. Test coverage for the contract: Rust unit tests, native-side instrumentation tests, and a manual E2E checklist.

### Non-goals

- Desktop support. The plugin returns `Error::UnsupportedPlatform` on desktop, same as today. (Desktop OAuth has its own canonical plugin — `tauri-plugin-oauth` — and conflating the two helps no one.)
- Token *storage*. AppAuth's `AuthState` is returned to the caller; persistence inside the OS keychain/keystore is the host app's job (Eurora already has `euro-secret`). The plugin offers an opt-in encrypted-store helper but does not own credentials by default.
- Provider-specific SDKs (Sign in with Apple's native `ASAuthorizationController`, Google One Tap, etc.). Those require platform consent UI and entitlements that don't belong in a generic OAuth plugin. Document this and link to dedicated plugins.
- Backwards compatibility with the current `authenticate` command. Consumers update.

## 2. Identity: pick one name

The plugin currently identifies as four different things in four files:

| File | Name |
|---|---|
| Directory | `tauri-plugin-oauth-mobile` |
| `Cargo.toml` | `tauri-plugin-oauth-session` |
| `package.json` | `tauri-plugin-glazier` (template leak) |
| Android namespace | `app.tauri.oauth_session` |

Pick **`tauri-plugin-appauth`** and rename everywhere as part of this rewrite:

- crate name `tauri-plugin-appauth`
- npm name `@eurora-labs/tauri-plugin-appauth` (or unscoped if publishing to crates.io / npm public — decide before phase 1)
- Tauri plugin identifier `appauth` → JS calls become `plugin:appauth|authorize`
- Android namespace `app.tauri.appauth`
- iOS package `tauri-plugin-appauth`

Rationale: the name AppAuth is industry-recognised, signals the implementation, and matches the JS ecosystem (`react-native-app-auth`, `expo-auth-session` etc. all centre on AppAuth). "oauth-session" implied "browser session only," which the rewrite explicitly outgrows.

## 3. Public API design

### 3.1 Conceptual model

AppAuth's surface maps cleanly onto four operations. The plugin exposes those as four Tauri commands plus one Tauri-event channel:

| Command | Purpose |
|---|---|
| `discover` | Hit `<issuer>/.well-known/openid-configuration` (or pass explicit endpoints) and return `ServiceConfiguration`. Cacheable. |
| `register` | RFC 7591 dynamic client registration (optional; only providers that support it). |
| `authorize` | Open the browser, run PKCE, capture the redirect, exchange the code for tokens. Returns full `AuthState`. |
| `refresh` | Use a refresh token to mint a new access token. Returns updated `AuthState`. |
| `endSession` | RFC 8665 end-session / RP-initiated logout. Returns when the post-logout redirect fires. |

Plus one event channel:

| Event | Purpose |
|---|---|
| `auth-events` | Streams `BrowserOpened`, `RedirectIntercepted`, `TokenExchangeStarted` etc. for diagnostics + UX (spinners, telemetry). Optional to subscribe. |

For consumers (like Eurora today) who run their own backend-mediated flow and only need the browser leg, expose one additional command:

| Command | Purpose |
|---|---|
| `authorizeBrowserOnly` | Open the browser at an arbitrary `authUrl`, wait for the redirect to a custom scheme, return the redirect URL. AppAuth still handles browser orchestration + cancellation; we don't roll the state machine ourselves. |

`authorizeBrowserOnly` covers Eurora's current flow exactly (`get_login_token` → open browser → `complete_login`) and matches the current `authenticate` command's semantics, so the migration in `crates/app/euro-mobile/` is a one-line rename.

### 3.2 Rust API (final shape)

```rust
// src/lib.rs
pub fn init<R: Runtime>() -> TauriPlugin<R>;

pub trait AppAuthExt<R: Runtime> {
    fn appauth(&self) -> &AppAuth<R>;
}

impl<R: Runtime> AppAuth<R> {
    pub async fn discover(&self, req: DiscoverRequest) -> Result<ServiceConfiguration>;
    pub async fn register(&self, req: RegisterRequest) -> Result<RegistrationResponse>;
    pub async fn authorize(&self, req: AuthorizeRequest) -> Result<AuthState>;
    pub async fn authorize_browser_only(&self, req: BrowserOnlyRequest) -> Result<BrowserOnlyResponse>;
    pub async fn refresh(&self, req: RefreshRequest) -> Result<AuthState>;
    pub async fn end_session(&self, req: EndSessionRequest) -> Result<EndSessionResponse>;
    pub fn events(&self) -> impl Stream<Item = AuthEvent>;
}
```

```rust
// src/models.rs (sketch — exhaustive list deferred to phase 1)

#[derive(Serialize, Deserialize)] #[serde(rename_all = "camelCase")]
pub struct AuthorizeRequest {
    pub config: ConfigSource,        // Discovery or explicit endpoints
    pub client_id: String,
    pub redirect_uri: String,        // Validated to be a custom scheme or HTTPS app-link
    pub scopes: Vec<String>,
    pub additional_parameters: HashMap<String, String>,
    pub prompt: Option<Prompt>,      // login / consent / select_account / none
    pub login_hint: Option<String>,
    pub ui_locales: Option<Vec<String>>,
    pub prefers_ephemeral_session: bool,    // iOS-only hint, defaults true
    pub use_nonce: bool,             // OIDC nonce, defaults true when scopes contain "openid"
}

#[derive(Serialize, Deserialize)] #[serde(rename_all = "camelCase")]
pub struct AuthState {
    pub access_token: Option<String>,
    pub access_token_expires_at: Option<i64>,    // unix seconds
    pub id_token: Option<String>,
    pub refresh_token: Option<String>,
    pub scope: Option<String>,
    pub token_type: Option<String>,
    pub authorization_code: Option<String>,      // exposed for backend-mediated flows
    pub additional_parameters: HashMap<String, serde_json::Value>,
}
```

`ConfigSource` is a tagged union: `{ kind: "discovery", issuer }` or `{ kind: "explicit", authorization_endpoint, token_endpoint, end_session_endpoint? }`. AppAuth's `AuthorizationServiceConfiguration` maps onto this 1:1 on both platforms.

### 3.3 TS API (final shape)

```ts
// guest-js/index.ts
export { authorize, authorizeBrowserOnly, refresh, endSession, discover, register } from './commands';
export { onAuthEvent } from './events';
export {
  type AuthorizeRequest, type AuthState,
  type RefreshRequest, type EndSessionRequest,
  type ServiceConfiguration, type AuthEvent,
  AppAuthError, AppAuthErrorCode,
} from './types';
```

```ts
// Example consumer code
import { authorize, AppAuthError } from '@eurora-labs/tauri-plugin-appauth';

try {
  const auth = await authorize({
    config: { kind: 'discovery', issuer: 'https://accounts.google.com' },
    clientId: '...apps.googleusercontent.com',
    redirectUri: 'com.eurora.app:/oauth/callback',
    scopes: ['openid', 'email', 'profile'],
  });
  // auth.accessToken, auth.idToken, auth.refreshToken
} catch (e) {
  if (e instanceof AppAuthError && e.code === 'USER_CANCELED') return;
  throw e;
}
```

Errors are a typed class with discriminated codes; no string sniffing. Codes are derived 1:1 from AppAuth's iOS `OIDErrorCode` and Android `AuthorizationException` categories so cross-platform behaviour is identical.

### 3.4 Permissions

Each command gets its own permission, generated by `tauri-plugin` from `build.rs` `COMMANDS`. Default set:

```toml
# permissions/default.toml
[default]
description = "Run OAuth 2.0 / OIDC authorization on mobile via AppAuth."
permissions = [
  "allow-discover",
  "allow-authorize",
  "allow-authorize-browser-only",
  "allow-refresh",
  "allow-end-session",
  # `register` deliberately not in default — DCR is rare and risky to leave on.
]
```

This is a real change vs. today's single coarse permission and lets host apps deny e.g. `register` without losing `authorize`.

## 4. Architecture

### 4.1 Layers

```
┌─────────────────────────────────────────────────────────┐
│ Host app (TS)                                           │
│   import { authorize } from '@eurora-labs/...appauth'   │
└──────────────────────────┬──────────────────────────────┘
                           │  invoke('plugin:appauth|authorize', …)
┌──────────────────────────▼──────────────────────────────┐
│ Rust core (src/)                                        │
│   - typed models, command handlers                      │
│   - serde marshalling                                   │
│   - run_mobile_plugin → native                          │
│   - Channel<AuthEvent> wiring                           │
└─────────────┬──────────────────────────┬────────────────┘
              │                          │
   ┌──────────▼────────┐      ┌──────────▼──────────┐
   │ iOS (Swift)       │      │ Android (Kotlin)    │
   │  AppAuth-iOS      │      │  AppAuth-Android    │
   │  OIDAuthState     │      │  AuthorizationSvc   │
   │  ASWebAuthSession │      │  Custom Tabs +      │
   │   (managed by     │      │   AuthorizationMgmt │
   │    AppAuth)       │      │   Activity          │
   └───────────────────┘      └─────────────────────┘
```

### 4.2 Why AppAuth replaces our state machine

- iOS: `OIDAuthState.authState(byPresenting:presenting:callback:)` *internally* uses `ASWebAuthenticationSession`, retains it, validates `state`, runs PKCE, exchanges the code, and returns a fully-populated `OIDAuthState`. Our 116-line `OAuthSessionPlugin.swift` becomes ~30 lines of glue.
- Android: `AuthorizationService.performAuthorizationRequest` launches Custom Tabs via a managed `AuthorizationManagementActivity` that AppAuth provides. AppAuth handles process-death recovery via `Intent` extras + a `PendingIntent` round-trip, so our `RedirectActivity` + static `pendingInvoke` state machine + `skipNextResume` flag all go away. We don't write `RedirectActivity` at all — AppAuth's `RedirectUriReceiverActivity` ships in the AAR and is registered via manifest merge.

### 4.3 Process-death recovery

The current Android implementation loses `pendingInvoke` if the OS kills the app while Custom Tabs is foregrounded. AppAuth's authorization request is instead delivered through a `PendingIntent` that the OS re-binds even after process restart. The plugin must:

1. Serialise the `AuthorizationRequest` and the Tauri `Invoke` reply channel id into the `PendingIntent` extras.
2. On cold start, if the launching `Intent` carries an AppAuth response, replay it to the (now-fresh) Tauri runtime via a registered listener and resolve.

This is the *one* genuinely subtle piece of native glue we still write. It's well-documented in AppAuth's Android sample (`MainActivity.handleAuthorizationResponse`).

### 4.4 Threading & cancellation

- Rust commands are `async`. Native side runs on the platform UI thread for browser ops (required by both AppAuth implementations) and on a worker for token exchange (AppAuth handles dispatch internally).
- Cancellation: when the Tauri caller drops the future, we attempt to cancel the in-flight AppAuth request. AppAuth-iOS supports `OIDAuthorizationService.cancel*`; AppAuth-Android exposes `AuthorizationService.dispose()`. Cancelled flows reject with `USER_CANCELED` to preserve the existing semantics.

## 5. Phased plan

Each phase ends in a green build, green tests, and a working example.

### Phase 1 — Identity & metadata cleanup

Touches: `Cargo.toml`, `package.json`, `tsconfig.json`, `README.md`, Android namespace, `permissions/`, build script.

- Rename the crate, npm package, and Android namespace per §2.
- Fix `package.json` name + description + repo URL.
- Rewrite `README.md` to describe the AppAuth-backed plugin (overview, install, configure, quickstart, error reference, platform notes).
- Delete the `tauri-plugin-glazier` references in the example app's `Cargo.toml` and `lib.rs`.
- Verify `bun run build` produces a non-empty `dist-js/` even with the current empty `index.ts` (it should now bundle a real `export {}` plus type re-exports stub).

Deliverable: clean rename, consistent metadata, no functional change. Commit boundary.

### Phase 2 — Add AppAuth dependencies, retire hand-rolled native code

Touches: `ios/Package.swift`, `ios/Sources/`, `android/build.gradle.kts`, `android/AndroidManifest.xml`, `android/src/main/java/...`.

- iOS: add SwiftPM dependency `https://github.com/openid/AppAuth-iOS` (pinned to a specific 1.7.x tag). Delete the entire body of `OAuthSessionPlugin.swift`; replace with a minimal `Plugin` subclass that holds an `OIDExternalUserAgentSession?` (managed by AppAuth) and exposes the five `@objc` command methods as stubs that `invoke.reject` with `NOT_IMPLEMENTED`.
- Android: add `implementation("net.openid:appauth:0.11.1")`. Delete `RedirectActivity.kt` and the static state machine in `OAuthSessionPlugin.kt`; replace with a `Plugin` subclass holding an `AuthorizationService` (lazy, disposed in `onDestroy`) and stubbed command methods.
- AndroidManifest: remove our custom `RedirectActivity` declaration. Document that consumers add `appAuthRedirectScheme` as a `manifestPlaceholder` in their `app/build.gradle.kts`, exactly like AppAuth-Android requires (`net.openid.appauth.RedirectUriReceiverActivity` is provided by the library and its intent-filter is merged automatically).
- Build the example app on both platforms; expect everything to fail at runtime (commands all reject) but compile cleanly.

Deliverable: native projects compile against AppAuth, all hand-rolled OAuth code deleted. Commit boundary.

### Phase 3 — Rust core: models, commands, error mapping, init

Touches: `src/lib.rs`, `src/models.rs`, `src/commands.rs`, `src/error.rs`, `build.rs`, `permissions/default.toml`.

- Define every model in §3.2 with `#[serde(rename_all = "camelCase")]` and `#[derive(Debug, Clone, Serialize, Deserialize)]`.
- Update `build.rs` `COMMANDS` to the new six commands (or seven if we keep `register`).
- Rewrite `error.rs` so codes mirror AppAuth's domains exactly: `USER_CANCELED`, `AUTHORIZATION_FAILED`, `TOKEN_EXCHANGE_FAILED`, `NETWORK_ERROR`, `INVALID_REGISTRATION_RESPONSE`, `ID_TOKEN_VALIDATION_FAILED`, `BROWSER_NOT_AVAILABLE`, `INVALID_REQUEST`, `SERVER_ERROR`, `UNSUPPORTED_PLATFORM`, `PLUGIN_INVOKE_FAILED`. Each carries an optional `oauth_error` (the OAuth error name from the response, e.g. `invalid_grant`) and `oauth_error_description`.
- Rewrite `lib.rs::init` with the new commands list. Keep the `cfg(mobile)`/`cfg(not(mobile))` shape.
- Wire a `tauri::ipc::Channel<AuthEvent>` for the events stream.

Deliverable: Rust crate compiles, command handlers all delegate to native (which still rejects with `NOT_IMPLEMENTED`). Commit boundary.

### Phase 4 — iOS implementation against AppAuth-iOS

Touches: `ios/Sources/AppAuthPlugin.swift` (renamed).

Per command, in this order (each commit ends with the example app exercising that command end-to-end against a public OIDC issuer such as `https://demo.duendesoftware.com`):

1. `discover` → `OIDAuthorizationService.discoverConfiguration(forIssuer:completion:)`. Marshal `OIDServiceConfiguration` ↔ our `ServiceConfiguration`.
2. `authorize` → build `OIDAuthorizationRequest` (PKCE on, nonce on if `openid` in scopes, `state` auto-generated), call `OIDAuthState.authState(byPresenting:presenting:prefersEphemeralSession:callback:)`. Marshal the resulting `OIDAuthState` to our `AuthState` (extract access/refresh/ID tokens + expiry from `lastTokenResponse`).
3. `authorizeBrowserOnly` → drop to `OIDAuthorizationService.present(_:externalUserAgent:callback:)` with a custom `OIDExternalUserAgentIOS` for the host's anchor, returning the raw redirect URL without a token-exchange step.
4. `refresh` → `OIDAuthState.performAction(freshTokens:)` with `forceRefresh: true` semantics, return updated `AuthState`.
5. `endSession` → `OIDEndSessionRequest` + `OIDAuthorizationService.present(_:externalUserAgent:callback:)`.
6. `register` → `OIDAuthorizationService.perform(_:completion:)` with `OIDRegistrationRequest`.

Presentation anchor: keep the existing logic that prefers `manager.viewController?.view.window`, falls back to the key `UIWindowScene` window. Document the iPad multitasking edge case.

Threading: all `OIDAuthState`/`OIDAuthorizationService` calls happen on `DispatchQueue.main`. Token exchanges complete on AppAuth's internal queue; we hop back to main before resolving the `Invoke`.

Errors: switch on `OIDErrorCode` and `OIDErrorCodeOAuth` (token endpoint subdomain) to map to our error enum. Network errors come through as `NSURLErrorDomain` and map to `NETWORK_ERROR`.

Deliverable: full iOS feature parity with AppAuth. Commit per command.

### Phase 5 — Android implementation against AppAuth-Android

Touches: `android/src/main/java/app/tauri/appauth/AppAuthPlugin.kt`.

Per command, same order as Phase 4:

1. `discover` → `AuthorizationServiceConfiguration.fetchFromIssuer(uri, RetrieveConfigurationCallback)`.
2. `authorize` → `AuthorizationRequest.Builder(...).setCodeVerifier(...)` (or the auto-PKCE builder helper) + `AuthorizationService.performAuthorizationRequest(req, completedIntent, canceledIntent)`. Use `PendingIntent`s pointing at a private `AuthHandlerActivity` that the plugin owns. On result, run token exchange via `authService.performTokenRequest`. Marshal the merged `AuthState` (AppAuth's class) to ours.
3. `authorizeBrowserOnly` → use `CustomTabsIntent.Builder()` directly via `AuthorizationService.customTabManager.createTabBuilder()` (so we still benefit from AppAuth's warmup) but skip the token exchange. Result delivery still goes via a `PendingIntent` so process-death is handled.
4. `refresh` → `AuthState.createTokenRefreshRequest()` + `authService.performTokenRequest`.
5. `endSession` → `EndSessionRequest` + `authService.performEndSessionRequest`.
6. `register` → `RegistrationRequest` + `authService.performRegistrationRequest`.

Process-death recovery: register the plugin's `AuthHandlerActivity` in the plugin manifest (auto-merged into the host app) and route its `onCreate(intent)` back to a `PluginHandle` lookup keyed by a request id stored in the intent extras. Deliver to the matching pending `Invoke`; if no `Invoke` is registered (because the JS side hasn't reattached yet), buffer the response in a `Bundle` until first `authorize` call subscribes to results — Capacitor's plugin model does this and it works well.

Lifecycle: own a single `AuthorizationService` per plugin instance, dispose it in `onDestroy` (the existing `Plugin` superclass exposes the lifecycle hook). Recreate on next command if disposed.

Errors: map `AuthorizationException` categories (`GENERAL_ERRORS`, `AUTHORIZATION_REQUEST_ERRORS`, `TOKEN_REQUEST_ERRORS`, `REGISTRATION_REQUEST_ERRORS`) to our error enum.

Deliverable: full Android feature parity. Commit per command.

### Phase 6 — TypeScript bindings

Touches: `guest-js/index.ts`, `guest-js/commands.ts`, `guest-js/events.ts`, `guest-js/types.ts`, `tsconfig.json`, `package.json` build scripts.

- Real implementations for `authorize`, `refresh`, etc. — each `invoke('plugin:appauth|<command>', { ... })` with typed args.
- `AppAuthError` class with `code: AppAuthErrorCode`, `message: string`, optional `oauthError`/`oauthErrorDescription`. Normalises rejections from `invoke`.
- `onAuthEvent(handler) → unsubscribe` using the Tauri `Channel` mechanism.
- ESM, CJS, IIFE, and `.d.ts` outputs in `dist-js/`. Verify `package.json` `exports` map points correctly.
- Re-publish `api-iife.js` from the new bundle.

Deliverable: importable TS package with full coverage of the Rust API. Commit boundary.

### Phase 7 — Example app

Touches: `examples/tauri-app/`.

- Rip out the `tauri-plugin-glazier` references.
- Add a real Svelte/React page with three buttons: "Sign in (Google)", "Sign in (Demo OIDC)", "Sign out".
- Wire each to the new TS API. Display the resulting `AuthState` (truncated) and any `AppAuthError` codes.
- Add a `.env.example` documenting the OAuth client IDs the example expects (Google + Duende demo).
- README in the example explaining how to register a Google OAuth client and configure the redirect scheme on each platform.

Deliverable: a developer can `cd examples/tauri-app && pnpm tauri ios dev` (and `... android dev`) and complete a real OIDC flow.

### Phase 8 — Tests

- Rust: unit tests on serde round-trips for every model and error mapping (no native runtime).
- Rust: a `#[cfg(not(mobile))] #[tokio::test]` per command verifying we get `Error::UnsupportedPlatform`.
- iOS: XCTest target under `ios/Tests/` with cases that mock `OIDAuthorizationService` (it has a protocol-shaped public surface) and assert our state machine + error mapping.
- Android: instrumentation test under `android/src/androidTest/` covering the redirect-URI activity result path with `Robolectric` for the unit-style cases and a real device test for the AppAuth round-trip.
- Manual E2E checklist (in `docs/e2e-checklist.md`): every command, on a physical device per platform, against the Duende demo issuer, with screenshots of the AppAuth-managed browser sheet.

Deliverable: `cargo test`, `xcodebuild test`, and `./gradlew connectedAndroidTest` all green in CI (GitHub Actions matrix).

### Phase 9 — Docs & release

- Final `README.md`: install (Cargo + npm), configure (manifest placeholders, redirect URI rules per platform, Universal Links / App Links guidance), quickstart, full API reference, error code reference, troubleshooting (common AppAuth pitfalls — wrong redirect scheme casing, app links not verified, `prompt=none` SSO).
- `CHANGELOG.md` with an "**0.2.0 — full rewrite**" entry that calls out the breaking API change and links to a migration guide.
- `docs/migrating-from-0.1.md` showing the diff for Eurora's `auth_procedures.rs` (mostly: rename `authenticate` → `authorizeBrowserOnly` in TS, swap models in Rust).
- Tag `v0.2.0`. Publish to crates.io + npm.

## 6. Final file layout

```
tauri-plugin-appauth/
├── Cargo.toml                                  # name = "tauri-plugin-appauth"
├── build.rs
├── package.json                                # name = "@eurora-labs/tauri-plugin-appauth"
├── tsconfig.json
├── README.md
├── CHANGELOG.md
├── LICENSE
├── plan.md                                     # this file (delete after phase 9)
├── docs/
│   ├── e2e-checklist.md
│   └── migrating-from-0.1.md
├── src/
│   ├── lib.rs
│   ├── commands.rs
│   ├── models.rs
│   ├── error.rs
│   └── events.rs
├── guest-js/
│   ├── index.ts
│   ├── commands.ts
│   ├── events.ts
│   └── types.ts
├── dist-js/                                    # build output, gitignored
├── api-iife.js                                 # build output, gitignored
├── ios/
│   ├── Package.swift                           # depends on AppAuth-iOS 1.7.x
│   └── Sources/
│       ├── AppAuthPlugin.swift
│       ├── Models.swift
│       └── ErrorMapping.swift
├── android/
│   ├── build.gradle.kts                        # depends on net.openid:appauth:0.11.1
│   ├── AndroidManifest.xml                     # AuthHandlerActivity only
│   ├── proguard-rules.pro
│   └── src/main/java/app/tauri/appauth/
│       ├── AppAuthPlugin.kt
│       ├── AuthHandlerActivity.kt
│       ├── Models.kt
│       └── ErrorMapping.kt
├── permissions/
│   ├── default.toml
│   ├── schemas/schema.json
│   └── autogenerated/                          # regenerated by build.rs
├── examples/
│   └── tauri-app/                              # working example, both platforms
└── scripts/
    └── build-iife.ts
```

Deletions: `RedirectActivity.kt`, the `OAuthSessionPlugin` static state machine, the `skipNextResume` flag, the empty `guest-js/index.ts`, the entire glazier example.

## 7. Migration impact on consumers (Eurora specifically)

In `crates/app/euro-mobile/`:

- `Cargo.toml`: `tauri-plugin-oauth-session` → `tauri-plugin-appauth`; `lib.rs` plugin init line changes accordingly.
- `apps/mobile/src/lib/services/oauth-session.ts` → renamed to `auth-browser.ts`, calls `authorizeBrowserOnly` from `@eurora-labs/tauri-plugin-appauth` instead of raw `invoke`. Error codes stay equivalent.
- `apps/mobile/src/routes/login/+page.svelte:24` — pass `redirectUri` instead of `callbackScheme` (more flexible — supports app-links not just custom schemes).
- `crates/app/euro-mobile/src/procedures/auth_procedures.rs` is unchanged: PKCE + login-token exchange still happen against `be-auth-service`. The plugin only replaces the browser-leg.
- `crates/app/euro-mobile/gen/android/app/build.gradle.kts:21`: rename `oauthSessionRedirectScheme` → `appAuthRedirectScheme`.
- `crates/app/euro-mobile/capabilities/main.json`: replace `oauth-session:default` with `appauth:default` (or scope down to `appauth:allow-authorize-browser-only` since that's all the host app uses).

This is one PR in the Eurora repo, fully mechanical, and unblocks the iOS+Android parity that the current plugin version doesn't deliver.

If/when Eurora wants to stop running its own backend OAuth and instead let the mobile app talk to Google directly: switch from `authorizeBrowserOnly` to `authorize`, drop most of `auth_procedures.rs`. Out of scope for this rewrite but the plugin makes it a one-line change.

## 8. Open questions to resolve before phase 1

1. **Naming**: confirm `tauri-plugin-appauth` and the npm scope. If keeping `tauri-plugin-oauth-session`, the plan still works but the rename steps drop out.
    Rename to tauri-plugin-appauth
2. **Crate publishing**: crates.io public publish, or workspace-local? Affects whether we need a real `keywords`/`categories`/`repository` set on `Cargo.toml`.
    It will be a public publish, I will do it later by hand.
3. **AppAuth versions to pin**: AppAuth-iOS 1.7.x is current stable; AppAuth-Android 0.11.1 (Aug 2023) is current stable. Both are well-maintained. Confirm we're OK with these.
    I am ok with these changes
4. **Token persistence**: do we ship an opt-in encrypted-store helper (using the OS keychain/keystore via the same primitives `tauri-plugin-stronghold` uses), or leave persistence entirely to the host app? Recommendation: leave it out for v0.2.0 and add it in v0.3.0 if there's demand — it's the easiest thing to get wrong and the easiest thing to add later.
    Leave it for later
5. **Dynamic Client Registration**: ship `register` in v0.2.0 or defer? It's ~30 lines on each platform and AppAuth supports it natively, so I'd ship it; just exclude it from the default permission set so it's opt-in.
    Ship it
6. **Channel events**: ship `auth-events` in v0.2.0 or defer? Useful for telemetry but adds API surface. Recommendation: ship a minimal version (`browserOpened`, `redirectIntercepted`, `tokenExchangeStarted`, `tokenExchangeCompleted`) and expand later.
    Ship minimal and expand later

Pick answers, then phase 1 starts.
