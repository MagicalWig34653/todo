// WebAuthn helpers: base64url conversion and mapping between server JSON and navigator.credentials types.

export function base64urlToBuffer(value: string): ArrayBuffer {
	const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
	const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
	const binary = atob(padded);
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
	return bytes.buffer;
}

export function bufferToBase64url(buffer: ArrayBuffer | Uint8Array): string {
	const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
	let binary = '';
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

type DescriptorJSON = { id: string; type: string; transports?: string[] };

export interface CreationOptionsJSON {
	challenge: string;
	user: { id: string; name: string; displayName: string };
	excludeCredentials?: DescriptorJSON[];
	authenticatorSelection?: Record<string, unknown>;
	[key: string]: unknown;
}

export interface RequestOptionsJSON {
	challenge: string;
	allowCredentials?: DescriptorJSON[];
	[key: string]: unknown;
}

function descriptors(list: DescriptorJSON[] | undefined) {
	return list?.map((c) => ({ ...c, id: base64urlToBuffer(c.id) }));
}

export function toCreationOptions(json: CreationOptionsJSON): PublicKeyCredentialCreationOptions {
	return {
		...json,
		challenge: base64urlToBuffer(json.challenge),
		user: { ...json.user, id: base64urlToBuffer(json.user.id) },
		excludeCredentials: descriptors(json.excludeCredentials),
		// The server logs in without a username (empty allowCredentials), so the passkey must be discoverable.
		// The backend does not request this yet, hence the client default.
		authenticatorSelection: {
			residentKey: 'required',
			requireResidentKey: true,
			userVerification: 'preferred',
			...(json.authenticatorSelection as object | undefined)
		}
	} as unknown as PublicKeyCredentialCreationOptions;
}

export function toRequestOptions(json: RequestOptionsJSON): PublicKeyCredentialRequestOptions {
	return {
		...json,
		challenge: base64urlToBuffer(json.challenge),
		allowCredentials: descriptors(json.allowCredentials)
	} as unknown as PublicKeyCredentialRequestOptions;
}

export interface RegistrationPayload {
	id: string;
	rawId: string;
	type: string;
	response: { clientDataJSON: string; attestationObject: string; transports?: string[] };
}

export interface AuthenticationPayload {
	id: string;
	rawId: string;
	type: string;
	response: {
		clientDataJSON: string;
		authenticatorData: string;
		signature: string;
		userHandle?: string;
	};
}

export function serializeRegistration(credential: PublicKeyCredential): RegistrationPayload {
	const response = credential.response as AuthenticatorAttestationResponse;
	return {
		id: credential.id,
		rawId: bufferToBase64url(credential.rawId),
		type: credential.type,
		response: {
			clientDataJSON: bufferToBase64url(response.clientDataJSON),
			attestationObject: bufferToBase64url(response.attestationObject)
		}
	};
}

export function serializeAuthentication(credential: PublicKeyCredential): AuthenticationPayload {
	const response = credential.response as AuthenticatorAssertionResponse;
	return {
		id: credential.id,
		rawId: bufferToBase64url(credential.rawId),
		type: credential.type,
		response: {
			clientDataJSON: bufferToBase64url(response.clientDataJSON),
			authenticatorData: bufferToBase64url(response.authenticatorData),
			signature: bufferToBase64url(response.signature),
			...(response.userHandle ? { userHandle: bufferToBase64url(response.userHandle) } : {})
		}
	};
}

export function passkeysSupported(): boolean {
	return typeof window !== 'undefined' && !!window.PublicKeyCredential && !!navigator.credentials;
}
