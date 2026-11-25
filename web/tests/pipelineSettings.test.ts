import { describe, expect, it, vi } from 'vitest';
import { ApiError, createApi, type FetchLike } from '../src/lib/api';
import { de } from '../src/lib/i18n/de';
import {
	MODEL_SUGGESTIONS,
	createSettingsController,
	draftOf,
	draftProblems,
	emptySettingsView,
	normalizeSettings,
	settingsDirty,
	settingsErrorKey,
	settingsPatch,
	settingsSummary,
	type PipelineSettings,
	type SettingsApi
} from '../src/lib/pipelineSettings';

// Card B926E7D8 (pipeline stage 2): project settings "Pipeline" (docs/PLAN-PIPELINE-STUFE-2.md, section 1 and 7).
const ALL_ON = { planner: true, approval: true, developer: true, validation: true, tester: true, review: true };
const settings = (over: Partial<PipelineSettings> = {}): PipelineSettings => ({
	projectID: 'p1',
	revision: 0,
	steps: { ...ALL_ON },
	roles: { planner: {}, developer: {}, tester: {}, reviewer: {} },
	maxFixRounds: 3,
	notifyOnWaitingApproval: true,
	history: [],
	...over
});

describe('reading the settings', () => {
	it('fills defaults when the server omits parts (missing equals null)', () => {
		const s = normalizeSettings({ projectID: 'p1', revision: 4 } as never);
		expect(s.steps).toEqual(ALL_ON);
		expect(s.roles).toEqual({ planner: {}, developer: {}, tester: {}, reviewer: {} });
		expect(s.maxFixRounds).toBe(3);
		expect(s.notifyOnWaitingApproval).toBe(true);
		expect(s.history).toEqual([]);
		expect(s.revision).toBe(4);
	});

	it('keeps what the server sent and ignores unknown keys', () => {
		const s = normalizeSettings({
			projectID: 'p1', revision: 2, steps: { ...ALL_ON, tester: false, future: false }, roles: { developer: { model: 'sonnet', effort: 'high' }, extra: { model: 'x' } },
			maxFixRounds: 0, notifyOnWaitingApproval: false, updatedByLabel: 'Ada', history: [{ id: 'h', actorType: 'person', actorLabel: 'Ada', summary: 'steps.tester aus', createdAt: '2026-11-25T08:00:00Z' }]
		} as never);
		expect(s.steps.tester).toBe(false);
		expect('future' in s.steps).toBe(false);
		expect(s.roles.developer).toEqual({ model: 'sonnet', effort: 'high' });
		expect('extra' in s.roles).toBe(false);
		expect(s.maxFixRounds).toBe(0);
		expect(s.notifyOnWaitingApproval).toBe(false);
		expect(s.history).toHaveLength(1);
	});

	it('has model suggestions without duplicates', () => {
		expect(MODEL_SUGGESTIONS.length).toBeGreaterThan(2);
		expect(new Set(MODEL_SUGGESTIONS).size).toBe(MODEL_SUGGESTIONS.length);
	});
});

describe('draft of the form', () => {
	it('starts from the server values; no model is an empty text, no effort the default', () => {
		const d = draftOf(settings({ roles: { planner: {}, developer: { model: 'sonnet', effort: 'high' }, tester: { model: null, effort: null }, reviewer: {} }, maxFixRounds: 5 }));
		expect(d.roles.developer).toEqual({ model: 'sonnet', effort: 'high' });
		expect(d.roles.tester).toEqual({ model: '', effort: '' });
		expect(d.maxFixRounds).toBe('5');
		expect(d.notify).toBe(true);
		expect(d.steps.tester).toBe(true);
	});

	it('accepts the models of the contract and empty text', () => {
		const d = draftOf(settings());
		for (const model of ['', 'sonnet', 'haiku', 'gpt-6.1-sol', 'claude-sonnet-5-5', 'org/model:v1.2', ' sonnet ']) {
			d.roles.tester.model = model;
			expect(draftProblems(d), model).toEqual([]);
		}
	});

	it('refuses a model with blanks inside, special characters or more than 100 characters, before anything is sent', () => {
		const d = draftOf(settings());
		for (const model of ['gpt 6', 'sonnet!', 'söhnet', 'a'.repeat(101), '<b>']) {
			d.roles.developer.model = model;
			expect(draftProblems(d), model).toEqual([{ field: 'model', role: 'developer', code: 'invalid_model' }]);
		}
		d.roles.developer.model = 'a'.repeat(100);
		expect(draftProblems(d)).toEqual([]);
	});

	it('refuses a fix round count that is not a whole number from 0 to 10', () => {
		const d = draftOf(settings());
		for (const value of ['0', '10', ' 4 ']) {
			d.maxFixRounds = value;
			expect(draftProblems(d), value).toEqual([]);
		}
		for (const value of ['', '-1', '11', '2.5', 'drei', '1e1']) {
			d.maxFixRounds = value;
			expect(draftProblems(d), value).toEqual([{ field: 'maxFixRounds', code: 'invalid_max_fix_rounds' }]);
		}
	});

	it('refuses an unknown effort', () => {
		const d = draftOf(settings());
		d.roles.reviewer.effort = 'turbo';
		expect(draftProblems(d)).toEqual([{ field: 'effort', role: 'reviewer', code: 'invalid_effort' }]);
	});
});

describe('what is sent', () => {
	it('sends nothing when nothing changed, even after blanks around a value', () => {
		const base = settings({ roles: { planner: {}, developer: { model: 'sonnet' }, tester: {}, reviewer: {} } });
		const d = draftOf(base);
		expect(settingsPatch(base, d)).toBeNull();
		d.roles.developer.model = ' sonnet ';
		d.maxFixRounds = ' 3 ';
		expect(settingsPatch(base, d)).toBeNull();
		expect(settingsDirty(base, d)).toBe(false);
	});

	it('sends only the changed fields, on field level', () => {
		const base = settings();
		const d = draftOf(base);
		d.steps.tester = false;
		d.roles.developer.model = 'sonnet';
		d.roles.developer.effort = 'xhigh';
		d.maxFixRounds = '5';
		d.notify = false;
		expect(settingsPatch(base, d)).toEqual({
			steps: { tester: false },
			roles: { developer: { model: 'sonnet', effort: 'xhigh' } },
			maxFixRounds: 5,
			notifyOnWaitingApproval: false
		});
		expect(settingsDirty(base, d)).toBe(true);
	});

	it('clears a model or an effort with null', () => {
		const base = settings({ roles: { planner: {}, developer: { model: 'sonnet', effort: 'high' }, tester: {}, reviewer: {} } });
		const d = draftOf(base);
		d.roles.developer.model = '  ';
		d.roles.developer.effort = '';
		expect(settingsPatch(base, d)).toEqual({ roles: { developer: { model: null, effort: null } } });
	});

	it('leaves roles and steps out of the body when only another field changed', () => {
		const base = settings();
		const d = draftOf(base);
		d.maxFixRounds = '0';
		expect(settingsPatch(base, d)).toEqual({ maxFixRounds: 0 });
	});
});

describe('history text', () => {
	it('translates what the server writes into the history and keeps the rest readable', () => {
		expect(settingsSummary('steps.tester aus')).toBe('Tester ausgeschaltet');
		expect(settingsSummary('steps.review an')).toBe('Review eingeschaltet');
		expect(settingsSummary('roles.developer.model sonnet')).toBe('Entwickler: Modell sonnet');
		expect(settingsSummary('roles.developer.effort high')).toBe('Entwickler: Effort Hoch');
		expect(settingsSummary('steps.tester aus; roles.developer.model sonnet')).toBe('Tester ausgeschaltet; Entwickler: Modell sonnet');
		expect(settingsSummary('maxFixRounds 5')).toBe('Höchstens 5 Fix-Runden');
		expect(settingsSummary('notifyOnWaitingApproval aus')).toBe('Benachrichtigung bei wartender Freigabe ausgeschaltet');
		expect(settingsSummary('roles.reviewer.model null')).toBe('Reviewer: Modell auf Standard');
		// What the backend writes when a value is cleared.
		expect(settingsSummary('roles.developer.model Standard; roles.developer.effort Standard')).toBe('Entwickler: Modell auf Standard; Entwickler: Effort auf Standard');
	});

	it('shows an unknown text as it is', () => {
		expect(settingsSummary('etwas ganz Neues')).toBe('etwas ganz Neues');
		expect(settingsSummary('steps.deploy aus; etwas')).toBe('steps.deploy aus; etwas');
		expect(settingsSummary('')).toBe('');
	});
});

describe('refusals of the server', () => {
	it('explains every refusal in German', () => {
		const key = (status: number, reason?: string) => settingsErrorKey(new ApiError(status, reason));
		expect(de[key(409, 'revision_conflict')]).toContain('inzwischen');
		expect(de[key(400, 'invalid_model')]).toContain('Modell');
		expect(de[key(400, 'invalid_effort')]).toContain('Effort');
		expect(de[key(400, 'invalid_pipeline_settings')]).toContain('Einstellungen');
		expect(key(403, 'forbidden')).toBe('pipeline.settings.error.forbidden');
		expect(key(0, 'network')).toBe('pipeline.settings.error.network');
		expect(key(500)).toBe('pipeline.settings.error.generic');
		expect(key(401)).toBe('error.unauthorized');
		expect(settingsErrorKey(new Error('x'))).toBe('pipeline.settings.error.generic');
	});
});

describe('settings API calls', () => {
	const recorder = () => {
		const calls: { url: string; init?: RequestInit }[] = [];
		const fetchFn: FetchLike = async (url, init) => (calls.push({ url, init }), Response.json(settings()));
		return { calls, api: createApi(fetchFn) };
	};

	it('reads the settings of a project', async () => {
		const { calls, api } = recorder();
		await api.pipelineSettings('p1');
		expect(calls[0]!.url).toBe('/v1/projects/p1/pipeline-settings');
		expect(calls[0]!.init?.method).toBe('GET');
	});

	it('patches with the revision the person saw', async () => {
		const { calls, api } = recorder();
		await api.updatePipelineSettings('p1', { revision: 3, steps: { tester: false } });
		expect(calls[0]!.url).toBe('/v1/projects/p1/pipeline-settings');
		expect(calls[0]!.init?.method).toBe('PATCH');
		expect(JSON.parse(calls[0]!.init?.body as string)).toEqual({ revision: 3, steps: { tester: false } });
	});
});

function setup(initial: PipelineSettings = settings({ revision: 2 })) {
	const server = { current: initial };
	const api = {
		pipelineSettings: vi.fn<SettingsApi['pipelineSettings']>(async () => structuredClone(server.current)),
		updatePipelineSettings: vi.fn<SettingsApi['updatePipelineSettings']>(async (_id, body) => {
			server.current = settings({ ...server.current, revision: body.revision + 1, steps: { ...server.current.steps, ...body.steps }, history: [{ id: 'h1', actorLabel: 'Ada', summary: 'steps.tester aus' }] });
			return structuredClone(server.current);
		})
	};
	const view = emptySettingsView();
	return { server, api, view, ctl: createSettingsController(view, api) };
}

describe('settings controller', () => {
	it('loads on open and builds the draft', async () => {
		const { view, ctl, api } = setup();
		const done = ctl.open('p1');
		expect(view.status).toBe('loading');
		await done;
		expect(api.pipelineSettings).toHaveBeenCalledWith('p1');
		expect(view.status).toBe('ready');
		expect(view.data?.revision).toBe(2);
		expect(view.draft?.maxFixRounds).toBe('3');
	});

	it('treats a server without the endpoint (404) as unsupported, not as an error', async () => {
		const { view, ctl, api } = setup();
		api.pipelineSettings.mockRejectedValueOnce(new ApiError(404));
		await ctl.open('p1');
		expect(view.status).toBe('unsupported');
	});

	it('reports a failed load and recovers with a retry', async () => {
		const { view, ctl, api } = setup();
		api.pipelineSettings.mockRejectedValueOnce(new ApiError(500));
		await ctl.open('p1');
		expect(view.status).toBe('failed');
		await ctl.reload();
		expect(view.status).toBe('ready');
	});

	it('saves the change with the revision, shows the new state and clears the draft difference', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('p1');
		view.draft!.steps.tester = false;
		expect(await ctl.save(true)).toBe('saved');
		expect(api.updatePipelineSettings).toHaveBeenCalledWith('p1', { revision: 2, steps: { tester: false } });
		expect(view.data?.revision).toBe(3);
		expect(view.data?.history).toHaveLength(1);
		expect(settingsDirty(view.data!, view.draft!)).toBe(false);
		expect(view.feedback).toEqual({ tone: 'success', key: 'pipeline.settings.saved' });
		expect(view.busy).toBe(false);
	});

	it('sends nothing without a change and says so', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('p1');
		expect(await ctl.save(true)).toBe('unchanged');
		expect(api.updatePipelineSettings).not.toHaveBeenCalled();
		expect(view.feedback?.key).toBe('pipeline.settings.unchanged');
	});

	it('never saves without the manage right or twice at once', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('p1');
		view.draft!.maxFixRounds = '4';
		expect(await ctl.save(false)).toBe('ignored');
		let release!: () => void;
		api.updatePipelineSettings.mockImplementationOnce(() => new Promise((resolve) => (release = () => resolve(settings({ revision: 3, maxFixRounds: 4 })))));
		const one = ctl.save(true);
		expect(view.busy).toBe(true);
		expect(await ctl.save(true)).toBe('ignored');
		release();
		await one;
		expect(api.updatePipelineSettings).toHaveBeenCalledTimes(1);
	});

	it('does not send an invalid draft and names the field', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('p1');
		view.draft!.roles.tester.model = 'zwei Wörter';
		view.draft!.maxFixRounds = '11';
		expect(await ctl.save(true)).toBe('invalid');
		expect(api.updatePipelineSettings).not.toHaveBeenCalled();
		expect(view.problems).toEqual([
			{ field: 'model', role: 'tester', code: 'invalid_model' },
			{ field: 'maxFixRounds', code: 'invalid_max_fix_rounds' }
		]);
		view.draft!.roles.tester.model = 'haiku';
		view.draft!.maxFixRounds = '4';
		expect(await ctl.save(true)).toBe('saved');
		expect(view.problems).toEqual([]);
	});

	it('on a revision conflict reloads the current values, explains it and does not retry by itself', async () => {
		const { view, ctl, api, server } = setup();
		await ctl.open('p1');
		view.draft!.steps.tester = false;
		api.updatePipelineSettings.mockRejectedValueOnce(new ApiError(409, 'revision_conflict'));
		server.current = settings({ revision: 5, maxFixRounds: 7 });
		expect(await ctl.save(true)).toBe('conflict');
		expect(view.data?.revision).toBe(5);
		expect(view.draft?.maxFixRounds).toBe('7');
		expect(view.draft?.steps.tester).toBe(true);
		expect(view.feedback).toEqual({ tone: 'error', key: 'pipeline.settings.error.conflict' });
		expect(api.updatePipelineSettings).toHaveBeenCalledTimes(1);
		expect(view.busy).toBe(false);
		// The next save uses the reloaded revision.
		view.draft!.steps.tester = false;
		await ctl.save(true);
		expect(api.updatePipelineSettings).toHaveBeenLastCalledWith('p1', { revision: 5, steps: { tester: false } });
	});

	it('keeps the draft and the shown values on other refusals', async () => {
		const { view, ctl, api } = setup();
		await ctl.open('p1');
		view.draft!.roles.tester.model = 'haiku';
		api.updatePipelineSettings.mockRejectedValueOnce(new ApiError(400, 'invalid_model'));
		expect(await ctl.save(true)).toBe('failed');
		expect(view.draft!.roles.tester.model).toBe('haiku');
		expect(view.data?.revision).toBe(2);
		expect(view.feedback).toEqual({ tone: 'error', key: 'pipeline.settings.error.invalidModel' });
		api.updatePipelineSettings.mockRejectedValueOnce(new ApiError(0, 'network'));
		expect(await ctl.save(true)).toBe('failed');
		expect(view.feedback?.key).toBe('pipeline.settings.error.network');
	});

	it('discards the draft and forgets everything when another project opens; late answers of the old one are dropped', async () => {
		const { view, ctl, api, server } = setup();
		await ctl.open('p1');
		view.draft!.maxFixRounds = '9';
		ctl.discard();
		expect(view.draft?.maxFixRounds).toBe('3');
		let release!: () => void;
		api.updatePipelineSettings.mockImplementationOnce(() => new Promise((resolve) => (release = () => resolve(settings({ revision: 9 })))));
		view.draft!.maxFixRounds = '4';
		const pending = ctl.save(true);
		server.current = settings({ projectID: 'p2', revision: 1 });
		await ctl.open('p2');
		release();
		expect(await pending).toBe('ignored');
		expect(view.projectID).toBe('p2');
		expect(view.data?.projectID).toBe('p2');
		expect(view.feedback).toBeNull();
		expect(view.busy).toBe(false);
	});
});
