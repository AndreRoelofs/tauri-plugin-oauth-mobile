/// <reference types="vite/client" />
/// <reference types="svelte" />

declare global {
	namespace App {}
}

interface ImportMetaEnv {
	readonly VITE_GOOGLE_CLIENT_ID?: string;
	readonly VITE_GOOGLE_REDIRECT_URI?: string;
	readonly VITE_DUENDE_CLIENT_ID?: string;
	readonly VITE_DUENDE_REDIRECT_URI?: string;
}

export {};
