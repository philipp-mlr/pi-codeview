import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type FakeEntry = { type: "custom"; customType: string; data: unknown };
export type SentCall =
  | { kind: "message"; message: { customType: string; content: unknown; display?: boolean }; options?: unknown }
  | { kind: "user"; content: unknown; options?: unknown };

type Handler = (event: any, ctx: any) => unknown;
type ToolDef = {
  name: string;
  defaultActive?: boolean;
  execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, ctx: any): Promise<any>;
};
type CommandDef = { handler(args: string, ctx: any): Promise<void> | void };

/** Minimal stand-in for pi's ExtensionAPI and ExtensionContext, enough for codeview.ts. */
export function makeFakePi(cwd: string, opts: { sessionId?: string; entries?: FakeEntry[] } = {}) {
  const handlers = new Map<string, Handler[]>();
  const tools = new Map<string, ToolDef>();
  const commands = new Map<string, CommandDef>();
  let activeTools = ["read", "bash", "edit", "write"];
  let idle = true;
  const sent: SentCall[] = [];
  const entries: FakeEntry[] = [...(opts.entries ?? [])];
  const statuses = new Map<string, string | undefined>();
  const notifications: { message: string; level?: string }[] = [];

  const pi = {
    on(event: string, handler: Handler) {
      handlers.set(event, [...(handlers.get(event) ?? []), handler]);
      return () => {};
    },
    registerTool(tool: ToolDef) {
      tools.set(tool.name, tool);
      if (tool.defaultActive !== false && !activeTools.includes(tool.name)) activeTools.push(tool.name);
    },
    registerCommand(name: string, command: CommandDef) {
      commands.set(name, command);
    },
    setActiveTools(names: string[]) {
      activeTools = names.filter((n) => tools.has(n) || ["read", "bash", "edit", "write"].includes(n));
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
    hasUI: true,
    ui: {
      setStatus: (key: string, text: string | undefined) => void statuses.set(key, text),
      notify: (message: string, level?: string) => void notifications.push({ message, level }),
    },
    sessionManager: {
      getSessionId: () => opts.sessionId ?? "test-session",
      getEntries: () => entries,
    },
    isIdle: () => idle,
  };

  return {
    pi: pi as unknown as ExtensionAPI,
    ctx,
    sent,
    entries,
    statuses,
    notifications,
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
      return tool.execute("call-1", params, signal, undefined, ctx);
    },
    async runCommand(name: string, args: string) {
      const command = commands.get(name);
      if (!command) throw new Error(`no command ${name}`);
      await command.handler(args, ctx);
    },
  };
}

export type FakePi = ReturnType<typeof makeFakePi>;
