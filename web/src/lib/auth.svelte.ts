import { api, ApiError, type User } from './api.js';
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

class AuthState {
	user = $state<User | null>(null);
	ready = $state(false);

	async restore() {
		try {
			this.user = await api.me();
		} catch (e) {
			if (!(e instanceof ApiError)) throw e;
			this.user = null;
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
	}

	async loginWithPassword(username: string, password: string) {
		this.user = (await api.passwordLogin(username, password)).user;
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
