import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { LineDecoder, PROTOCOL_VERSION, encode } from "./protocol.ts";
import type { Event, Request, Response } from "./protocol.ts";

export function socketPath(repoHash: string, sessionId: string, runtimeDir?: string): string {
  const base = runtimeDir ?? process.env.XDG_RUNTIME_DIR ?? os.tmpdir();
  return path.join(base, "pi-nvim", repoHash, `${sessionId}.sock`);
}

export type Server = { broadcast(e: Event): void; close(): Promise<void> };

function isLive(p: string): Promise<boolean> {
  return new Promise((resolve, reject) => {
    const probe = net.connect(p);
    probe.once("connect", () => { probe.destroy(); resolve(true); });
    probe.once("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "ECONNREFUSED" || err.code === "ENOENT" || err.code === "ENOTSOCK") resolve(false);
      else reject(err);
    });
  });
}

export async function startServer(opts: {
  path: string;
  handle(req: Request): Promise<unknown>;
}): Promise<Server> {
  fs.mkdirSync(path.dirname(opts.path), { recursive: true, mode: 0o700 });
  if (fs.existsSync(opts.path)) {
    if (await isLive(opts.path)) throw new Error("socket in use");
    fs.unlinkSync(opts.path);
  }

  const clients = new Set<net.Socket>();
  const greeted = new WeakSet<net.Socket>();

  const reply = (sock: net.Socket, res: Response) => {
    if (!sock.destroyed) sock.write(encode(res));
  };

  const dispatch = async (sock: net.Socket, msg: unknown) => {
    const req = msg as Request;
    const id = typeof req?.id === "number" ? req.id : null;
    if (req?.type === "hello") {
      if (req.version !== PROTOCOL_VERSION) {
        reply(sock, { id, ok: false, error: `protocol version mismatch: server ${PROTOCOL_VERSION}, client ${req.version}` });
        return;
      }
      greeted.add(sock);
      reply(sock, { id, ok: true, result: { version: PROTOCOL_VERSION } });
      return;
    }
    if (!greeted.has(sock)) {
      reply(sock, { id, ok: false, error: "hello required" });
      return;
    }
    try {
      reply(sock, { id, ok: true, result: await opts.handle(req) });
    } catch (e) {
      reply(sock, { id, ok: false, error: e instanceof Error ? e.message : String(e) });
    }
  };

  const server = net.createServer((sock) => {
    clients.add(sock);
    const decoder = new LineDecoder();
    sock.setEncoding("utf8");
    sock.on("data", (data: string) => {
      for (const line of decoder.pushLines(data)) {
        let msg: unknown;
        try {
          msg = JSON.parse(line);
        } catch {
          reply(sock, { id: null, ok: false, error: "invalid json" });
          continue;
        }
        void dispatch(sock, msg);
      }
    });
    sock.on("error", () => sock.destroy());
    sock.on("close", () => clients.delete(sock));
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(opts.path, () => { server.removeListener("error", reject); resolve(); });
  });

  return {
    broadcast(e) {
      const line = encode(e);
      for (const c of clients) if (greeted.has(c) && !c.destroyed) c.write(line);
    },
    async close() {
      for (const c of clients) c.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      try { fs.unlinkSync(opts.path); } catch { /* already gone */ }
    },
  };
}
