import type { AttachmentRole } from './api.js';

export const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
export const ATTACHMENT_TYPES = ['image/png', 'image/jpeg', 'image/webp', 'application/pdf'] as const;
export const ATTACHMENT_ROLES: AttachmentRole[] = ['reference', 'progress', 'result'];

export type AttachmentProblem = 'type' | 'empty' | 'too_large' | 'name';

/** Client-side precheck mirroring the contract; the server validates again (magic bytes, checksum). */
export function checkFile(file: { name: string; size: number; type: string }): AttachmentProblem | null {
	if (!(ATTACHMENT_TYPES as readonly string[]).includes(file.type)) return 'type';
	if (file.size < 1) return 'empty';
	if (file.size > MAX_ATTACHMENT_BYTES) return 'too_large';
	const bytes = new TextEncoder().encode(file.name).length;
	if (bytes < 1 || bytes > 200 || /[\x00-\x1f\x7f/\\]/.test(file.name)) return 'name';
	return null;
}

/** Lowercase SHA-256 hex digest, as required by `BeginAttachment.checksum`. */
export async function sha256Hex(data: Blob | ArrayBuffer): Promise<string> {
	const buffer = data instanceof Blob ? await data.arrayBuffer() : data;
	const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', buffer));
	return Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
}

export function formatSize(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1).replace('.', ',')} KB`;
	return `${(bytes / 1024 / 1024).toFixed(1).replace('.', ',')} MB`;
}

export const isImage = (mediaType: string) => mediaType.startsWith('image/');
