<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import {
		authorize,
		AppAuthError,
		onAuthEvent,
		type AuthEvent,
		type AuthorizeRequest,
		type AuthState,
		type Unsubscribe,
	} from '@eurora-labs/tauri-plugin-appauth';

	type Provider = 'google' | 'duende';

	type DisplayError = {
		code: string;
		message: string;
		oauthError?: string;
		oauthErrorDescription?: string;
	};

	const googleClientId = import.meta.env.VITE_GOOGLE_CLIENT_ID ?? '';
	const googleRedirectUri = import.meta.env.VITE_GOOGLE_REDIRECT_URI ?? '';
	const duendeClientId = import.meta.env.VITE_DUENDE_CLIENT_ID ?? 'interactive.public';
	const duendeRedirectUri =
		import.meta.env.VITE_DUENDE_REDIRECT_URI ?? 'io.identitymodel.native://callback';

	const googleConfigured = googleClientId.length > 0 && googleRedirectUri.length > 0;
	const duendeConfigured = duendeRedirectUri.length > 0;

	type State = {
		auth: AuthState | null;
		error: DisplayError | null;
		inFlight: Provider | null;
		events: AuthEvent[];
	};

	let state: State = $state({
		auth: null,
		error: null,
		inFlight: null,
		events: [],
	});

	let unsubscribe: Unsubscribe | null = null;

	onMount(async () => {
		try {
			unsubscribe = await onAuthEvent((event) => {
				state.events = [...state.events, event];
			});
		} catch (e) {
			// Event subscription is best-effort. On desktop the plugin rejects
			// every command with `UNSUPPORTED_PLATFORM`; we still want the page
			// to render so developers can poke at the UI.
			console.warn('auth-events subscription failed', e);
		}
	});

	onDestroy(() => {
		unsubscribe?.();
	});

	async function signIn(provider: Provider) {
		const request: AuthorizeRequest =
			provider === 'google'
				? {
						config: { kind: 'discovery', issuer: 'https://accounts.google.com' },
						clientId: googleClientId,
						redirectUri: googleRedirectUri,
						scopes: ['openid', 'email', 'profile'],
					}
				: {
						config: { kind: 'discovery', issuer: 'https://demo.duendesoftware.com' },
						clientId: duendeClientId,
						redirectUri: duendeRedirectUri,
						scopes: ['openid', 'profile', 'email'],
					};

		state.inFlight = provider;
		state.error = null;
		state.events = [];
		try {
			state.auth = await authorize(request);
		} catch (e) {
			state.auth = null;
			state.error = toDisplayError(e);
		} finally {
			state.inFlight = null;
		}
	}

	function signOut() {
		state.auth = null;
		state.error = null;
		state.events = [];
	}

	function toDisplayError(value: unknown): DisplayError {
		if (value instanceof AppAuthError) {
			return {
				code: value.code,
				message: value.message,
				oauthError: value.oauthError,
				oauthErrorDescription: value.oauthErrorDescription,
			};
		}
		if (value instanceof Error) {
			return { code: 'UNKNOWN', message: value.message };
		}
		return { code: 'UNKNOWN', message: String(value) };
	}

	function truncate(value: string | undefined, n = 32): string {
		if (!value) return '—';
		return value.length <= n ? value : `${value.slice(0, n)}…`;
	}

	function formatExpiry(seconds: number | undefined): string {
		if (seconds === undefined) return '—';
		return new Date(seconds * 1000).toISOString();
	}
</script>

<main>
	<header>
		<h1>tauri-plugin-appauth example</h1>
		<p>
			Demonstrates the AppAuth-backed OAuth 2.0 / OIDC flows on iOS and Android. Configure client
			IDs in <code>.env</code> — see <code>.env.example</code> for the expected variables.
		</p>
	</header>

	<section class="actions">
		<button
			onclick={() => signIn('google')}
			disabled={!googleConfigured || state.inFlight !== null}
		>
			{state.inFlight === 'google' ? 'Signing in…' : 'Sign in (Google)'}
		</button>
		<button
			onclick={() => signIn('duende')}
			disabled={!duendeConfigured || state.inFlight !== null}
		>
			{state.inFlight === 'duende' ? 'Signing in…' : 'Sign in (Demo OIDC)'}
		</button>
		<button
			onclick={signOut}
			disabled={state.inFlight !== null || (state.auth === null && state.error === null)}
		>
			Sign out
		</button>
	</section>

	{#if !googleConfigured}
		<p class="hint">
			Set <code>VITE_GOOGLE_CLIENT_ID</code> and <code>VITE_GOOGLE_REDIRECT_URI</code> to enable the
			Google flow.
		</p>
	{/if}

	{#if state.auth !== null}
		<section class="output">
			<h2>AuthState</h2>
			<dl>
				<dt>access_token</dt>
				<dd>{truncate(state.auth.accessToken)}</dd>
				<dt>id_token</dt>
				<dd>{truncate(state.auth.idToken)}</dd>
				<dt>refresh_token</dt>
				<dd>{truncate(state.auth.refreshToken)}</dd>
				<dt>token_type</dt>
				<dd>{state.auth.tokenType ?? '—'}</dd>
				<dt>scope</dt>
				<dd>{state.auth.scope ?? '—'}</dd>
				<dt>expires_at</dt>
				<dd>{formatExpiry(state.auth.accessTokenExpiresAt)}</dd>
			</dl>
		</section>
	{/if}

	{#if state.error !== null}
		<section class="error" role="alert">
			<h2>AppAuthError</h2>
			<p><strong>code:</strong> <code>{state.error.code}</code></p>
			<p><strong>message:</strong> {state.error.message}</p>
			{#if state.error.oauthError}
				<p><strong>oauth_error:</strong> <code>{state.error.oauthError}</code></p>
			{/if}
			{#if state.error.oauthErrorDescription}
				<p>
					<strong>oauth_error_description:</strong>
					{state.error.oauthErrorDescription}
				</p>
			{/if}
		</section>
	{/if}

	{#if state.events.length > 0}
		<section class="events">
			<h2>Events</h2>
			<ol>
				{#each state.events as event, i (i)}
					<li><code>{event.kind}</code></li>
				{/each}
			</ol>
		</section>
	{/if}
</main>

<style>
	main {
		max-width: 720px;
		margin: 0 auto;
		padding: 1.5rem;
		font-family:
			-apple-system,
			BlinkMacSystemFont,
			'Segoe UI',
			sans-serif;
		line-height: 1.5;
	}

	h1 {
		font-size: 1.5rem;
		margin: 0 0 0.5rem;
	}

	header p {
		color: #555;
		margin: 0 0 1.5rem;
	}

	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 0.75rem;
		margin-bottom: 1.5rem;
	}

	button {
		padding: 0.6rem 1rem;
		font-size: 1rem;
		border: 1px solid #ccc;
		border-radius: 6px;
		background: #fff;
		cursor: pointer;
	}

	button:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.hint {
		color: #a06000;
		background: #fff8ec;
		padding: 0.5rem 0.75rem;
		border-radius: 6px;
		margin-bottom: 1rem;
	}

	section {
		border: 1px solid #e5e5e5;
		border-radius: 8px;
		padding: 1rem 1.25rem;
		margin-bottom: 1rem;
	}

	section h2 {
		margin: 0 0 0.5rem;
		font-size: 1.1rem;
	}

	.error {
		border-color: #f5b3b3;
		background: #fff5f5;
	}

	dl {
		display: grid;
		grid-template-columns: max-content 1fr;
		gap: 0.25rem 1rem;
		margin: 0;
	}

	dt {
		font-weight: 600;
		color: #555;
	}

	dd {
		margin: 0;
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		word-break: break-all;
	}

	code {
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		background: #f3f3f3;
		padding: 0.05rem 0.3rem;
		border-radius: 3px;
	}

	ol {
		margin: 0;
		padding-left: 1.25rem;
	}
</style>
