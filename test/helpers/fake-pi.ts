import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type FakeEntry = { type: "custom"; customType: string; data: unknown };
export type SentCall =
  | { kind: "message"; message: { customType: string; content: unknown; display?: boolean }; options?: unknown }
  | { kind: "user"; content: unknown; options?: unknown };

type Handler = (event: any, ctx: any) => unknown;
type ToolDef = {
  name: string;
  defaultActive?: boolean;
  executionMode?: string;
  execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, ctx: any): Promise<any>;
};
type CommandDef = { handler(args: string, ctx: any): Promise<void> | void };

/** Minimal stand-in for pi's ExtensionAPI and ExtensionContext, enough for pi-nvim.ts. */
export function makeFakePi(
  cwd: string,
  opts: {
    sessionId?: string;
    sessionName?: string;
    entries?: FakeEntry[];
    hasUI?: boolean;
    /** Like a `--tools` allowlist: pi never activates a tool outside it. */
    allowedTools?: string[];
  } = {},
) {
  const handlers = new Map<string, Handler[]>();
  const tools = new Map<string, ToolDef>();
  const commands = new Map<string, CommandDef>();
  let activeTools = ["read", "bash", "edit", "write"];
  let idle = true;
  const abortCalls: number[] = [];
  const toolAborts = new Set<AbortController>();
  const sent: SentCall[] = [];
  const entries: FakeEntry[] = [...(opts.entries ?? [])];
  const statuses = new Map<string, string | undefined>();
  const notifications: { message: string; level?: string }[] = [];
  const confirms: { title: string; message: string; signal?: AbortSignal }[] = [];
  let confirmAnswer = false;
  const allowed = (n: string) => !opts.allowedTools || opts.allowedTools.includes(n);

  const pi = {
    on(event: string, handler: Handler) {
      handlers.set(event, [...(handlers.get(event) ?? []), handler]);
      return () => {};
    },
    registerTool(tool: ToolDef) {
      tools.set(tool.name, tool);
      if (tool.defaultActive !== false && allowed(tool.name) && !activeTools.includes(tool.name)) activeTools.push(tool.name);
    },
    registerCommand(name: string, command: CommandDef) {
      commands.set(name, command);
    },
    setActiveTools(names: string[]) {
      activeTools = names.filter((n) => (tools.has(n) || ["read", "bash", "edit", "write"].includes(n)) && allowed(n));
    },
    getActiveTools: () => [...activeTools],
    sendMessage(message: any, options?: unknown) {
      sent.push({ kind: "message", message, options });
    },
    sendUserMessage(content: unknown, options?: unknown) {
      sent.push({ kind: "user", content, options });
    },
    appendEntry(customType: string, data?: unknown) {
      entries.push({ type: "custom", customType, data: structuredClone(data) });
    },
  };

  const ctx = {
    cwd,
    hasUI: opts.hasUI ?? true,
    ui: {
      setStatus: (key: string, text: string | undefined) => void statuses.set(key, text),
      notify: (message: string, level?: string) => void notifications.push({ message, level }),
      confirm: async (title: string, message: string, dialog?: { signal?: AbortSignal }) => {
        confirms.push({ title, message, signal: dialog?.signal });
        return confirmAnswer;
      },
    },
    sessionManager: {
      getSessionId: () => opts.sessionId ?? "test-session",
      getSessionName: () => opts.sessionName,
      getEntries: () => entries,
    },
    isIdle: () => idle,
    // Like pi: aborts the in-flight tool calls, which end a waiting checkpoint.
    abort() {
      abortCalls.push(abortCalls.length + 1);
      for (const c of toolAborts) c.abort();
    },
  };

  return {
    pi: pi as unknown as ExtensionAPI,
    ctx,
    tools,
    sent,
    entries,
    statuses,
    notifications,
    confirms,
    abortCalls,
    /** What the next `ctx.ui.confirm` answers (default: no). */
    setConfirmAnswer(value: boolean) {
      confirmAnswer = value;
    },
    setIdle(value: boolean) {
      idle = value;
    },
    async fire(event: string, payload: object = {}): Promise<unknown[]> {
      const results: unknown[] = [];
      for (const h of handlers.get(event) ?? []) results.push(await h({ type: event, ...payload }, ctx));
      return results;
    },
    async callTool(name: string, params: object, signal?: AbortSignal) {
      const tool = tools.get(name);
      if (!tool) throw new Error(`no tool ${name}`);
      // Every call gets its own controller that ctx.abort() fires; the caller's signal aborts it too.
      const controller = new AbortController();
      toolAborts.add(controller);
      signal?.addEventListener("abort", () => controller.abort(), { once: true });
      try {
        return await tool.execute("call-1", params, controller.signal, undefined, ctx);
      } finally {
        toolAborts.delete(controller);
      }
    },
    async runCommand(name: string, args: string) {
      const command = commands.get(name);
      if (!command) throw new Error(`no command ${name}`);
      await command.handler(args, ctx);
    },
  };
}

export type FakePi = ReturnType<typeof makeFakePi>;
