import { api, ApiError, type User } from './api.js';
import { workspace } from './workspace.svelte.js';
import {
	passkeysSupported,
	serializeAuthentication,
	serializeRegistration,
	toCreationOptions,
	toRequestOptions
} from './webauthn.js';

/** Raised for passkey ceremony problems that are not backend errors. */
export class PasskeyError extends Error {
	constructor(readonly reason: 'passkey_cancelled' | 'passkey_unsupported') {
		super(reason);
	}
}

const SESSION_HINT = 'todo.hadSession';
function hadSession(): boolean {
	try {
		return localStorage.getItem(SESSION_HINT) === '1';
	} catch {
		return false;
	}
}
function markSession(on: boolean): void {
	try {
		if (on) localStorage.setItem(SESSION_HINT, '1');
		else localStorage.removeItem(SESSION_HINT);
	} catch {
		/* storage blocked: no early start next time */
	}
}

class AuthState {
	user = $state<User | null>(null);
	ready = $state(false);

	async restore() {
		// A returning browser starts the workspace reads together with the session check instead of one round trip later.
		const hint = hadSession();
		// The session check goes out first (a browser may only run a few requests per host at once), the reads follow in the same tick.
		const session = api.me();
		if (hint) workspace.prime();
		try {
			this.user = await session;
			markSession(true);
			if (this.user && hint) workspace.primeTasks();
		} catch (e) {
			if (!(e instanceof ApiError)) throw e;
			this.user = null;
			markSession(false);
		}
		this.ready = true;
	}

	async loginWithPasskey() {
		if (!passkeysSupported()) throw new PasskeyError('passkey_unsupported');
		const { challengeID, options } = await api.loginBegin();
		let credential: Credential | null;
		try {
			credential = await navigator.credentials.get({ publicKey: toRequestOptions(options) });
		} catch {
			throw new PasskeyError('passkey_cancelled');
		}
		if (!credential) throw new PasskeyError('passkey_cancelled');
		const session = await api.loginFinish(challengeID, serializeAuthentication(credential as PublicKeyCredential));
		this.user = session.user;
		markSession(true);
	}

	async loginWithPassword(username: string, password: string) {
		this.user = (await api.passwordLogin(username, password)).user;
		markSession(true);
	}

	async registerWithPasskey(token: string, displayName: string, passkeyName?: string) {
		if (!passkeysSupported()) throw new PasskeyError('passkey_unsupported');
		const { challengeID, options } = await api.registerBegin(token, displayName);
		let credential: Credential | null;
		try {
			credential = await navigator.credentials.create({ publicKey: toCreationOptions(options) });
		} catch {
			throw new PasskeyError('passkey_cancelled');
		}
		if (!credential) throw new PasskeyError('passkey_cancelled');
		const session = await api.registerFinish(
			challengeID,
			serializeRegistration(credential as PublicKeyCredential),
			passkeyName || undefined
		);
		this.user = session.user;
		markSession(true);
	}

	async logout() {
		try {
			await api.logout();
		} finally {
			this.user = null;
		}
	}
}

export const auth = new AuthState();
