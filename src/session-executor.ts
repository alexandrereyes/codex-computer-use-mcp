import {
	createOfficialDirectToolSession,
	pathConfigFile,
	withCleanupFailure,
	type OfficialDirectToolSession,
} from "./direct-broker.ts";
import {
	defaultStateRoot,
	executeDirectTool,
	type DirectResponse,
	type DirectServiceDependencies,
} from "./direct-service.ts";
import { openTurnsDirectory } from "./open-turns.ts";
import type { DirectMethod, DirectToolArguments } from "./tools.ts";

interface DirectSessionExecutorDependencies {
	createSession?: typeof createOfficialDirectToolSession;
	idleTimeoutMs?: number;
}

export class DirectSessionExecutor {
	private queue = Promise.resolve();
	private session?: OfficialDirectToolSession;
	private idleTimer?: NodeJS.Timeout;
	private idleFailure?: Error;
	private closing?: Promise<void>;
	private readonly dependencies: DirectSessionExecutorDependencies;

	constructor(dependencies: DirectSessionExecutorDependencies = {}) {
		this.dependencies = dependencies;
	}

	private runExclusive<T>(operation: () => Promise<T>): Promise<T> {
		const result = this.queue.then(operation);
		this.queue = result.then(() => undefined, () => undefined);
		return result;
	}

	private clearIdleTimer(): void {
		if (this.idleTimer) clearTimeout(this.idleTimer);
		this.idleTimer = undefined;
	}

	private async closeSession(): Promise<void> {
		this.clearIdleTimer();
		const session = this.session;
		this.session = undefined;
		if (!session) return;
		const closing = session.close();
		this.closing = closing;
		try { await closing; }
		finally { if (this.closing === closing) this.closing = undefined; }
	}

	private scheduleIdleClose(): void {
		this.clearIdleTimer();
		if (!this.dependencies.idleTimeoutMs || !this.session) return;
		const timer = setTimeout(() => {
			void this.runExclusive(async () => {
				if (this.idleTimer !== timer) return;
				await this.closeSession();
			}).catch((error) => {
				this.idleFailure = error instanceof Error ? error : new Error(String(error));
			});
		}, this.dependencies.idleTimeoutMs);
		this.idleTimer = timer;
		timer.unref();
	}

	async execute(
		method: DirectMethod,
		params: DirectToolArguments,
		dependencies: DirectServiceDependencies,
	): Promise<DirectResponse> {
		return this.runExclusive(async () => {
			if (this.idleFailure) {
				const failure = this.idleFailure;
				this.idleFailure = undefined;
				throw failure;
			}
			this.clearIdleTimer();
			const session = this.session;
			let response: DirectResponse;
			try {
				response = await executeDirectTool(
					{ method, arguments: params },
					session ? {
						...dependencies,
						callTool: (directMethod, args, options) => session.call(directMethod, args, options),
					} : method === "get_app_state" ? {
						...dependencies,
						callTool: async (directMethod, args, options) => {
							const stateRoot = dependencies.stateRoot ?? defaultStateRoot();
							this.session = await (this.dependencies.createSession ?? createOfficialDirectToolSession)({
								supportsOpenAiFormElicitation: dependencies.supportsOpenAiFormElicitation === true,
								configPath: pathConfigFile(stateRoot),
								openTurnsDir: openTurnsDirectory(stateRoot),
							});
							return this.session.call(directMethod, args, options);
						},
					} : dependencies,
				);
			} catch (error) {
				// A close failure must not replace the call's own failure: report both.
				try { await this.closeSession(); }
				catch (closeError) {
					throw withCleanupFailure(error instanceof Error ? error : new Error(String(error)),
						closeError instanceof Error ? closeError : new Error(String(closeError)));
				}
				throw error;
			}
			if (!response.isError) {
				this.scheduleIdleClose();
				return response;
			}
			try { await this.closeSession(); }
			catch (closeError) {
				const officialText = response.content.filter((block) => block.type === "text").map((block) => String(block.text ?? "")).join("\n");
				throw withCleanupFailure(new Error(officialText || "Official Computer Use returned an error"),
					closeError instanceof Error ? closeError : new Error(String(closeError)));
			}
			return response;
		});
	}

	async close(): Promise<void> {
		await this.runExclusive(async () => {
			await this.closeSession();
			if (this.idleFailure) {
				const failure = this.idleFailure;
				this.idleFailure = undefined;
				throw failure;
			}
		});
	}

	/**
	 * For process exit, outside the call queue: end the retained session's native turn without the
	 * verified teardown, or wait for a close already under way. Callers bound the wait.
	 */
	async shutdown(): Promise<void> {
		this.clearIdleTimer();
		const session = this.session;
		this.session = undefined;
		if (session) await (session.shutdown ? session.shutdown() : session.close()).catch(() => undefined);
		else await this.closing?.catch(() => undefined);
	}
}
