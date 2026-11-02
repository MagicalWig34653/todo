import { api, type AttachmentRole } from './api.js';
import { checkFile, sha256Hex } from './attachments.js';

/** Why a file was refused before the upload (see `checkFile`). */
export class AttachProblem extends Error {
	constructor(readonly problem: NonNullable<ReturnType<typeof checkFile>>) {
		super(problem);
	}
}

/** Uploads one file to a task (begin, upload, complete); a failed upload drops the pending attachment again. */
export async function attachFile(taskID: string, file: File, role: AttachmentRole = 'reference'): Promise<void> {
	const problem = checkFile(file);
	if (problem) throw new AttachProblem(problem);
	const checksum = await sha256Hex(file);
	const cap = await api.beginAttachment({ taskID, filename: file.name, role, mediaType: file.type, size: file.size, checksum });
	try {
		await api.uploadAttachment(cap, file);
		await api.completeAttachment(cap.attachmentID);
	} catch (err) {
		await api.abortAttachment(cap.attachmentID).catch(() => {});
		throw err;
	}
}
