import { afterEach, describe, expect, it } from "vitest";
import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { LineDecoder, encode } from "../extensions/protocol.ts";
import { socketPath, startServer } from "../extensions/server.ts";

const dirs: string[] = [];
const closers: Array<() => Promise<void> | void> = [];
function tmp(): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "pcv-"));
  dirs.push(d);
  return path.join(d, "s.sock");
}
afterEach(async () => {
  for (const c of closers.splice(0)) await c();
  for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true });
});

type Client = { send(m: object): void; next(): Promise<any>; sock: net.Socket };
async function connect(p: string): Promise<Client> {
  const sock = net.connect(p);
  await new Promise<void>((res, rej) => { sock.once("connect", res); sock.once("error", rej); });
  const dec = new LineDecoder();
  const queue: any[] = [];
  const waiters: Array<(m: any) => void> = [];
  sock.setEncoding("utf8");
  sock.on("data", (b: string) => {
    for (const m of dec.push(b)) {
      const w = waiters.shift();
      if (w) w(m); else queue.push(m);
    }
  });
  closers.push(() => { sock.destroy(); });
  return {
    sock,
    send: (m) => { sock.write(encode(m)); },
    next: () => new Promise((res) => { const m = queue.shift(); if (m !== undefined) res(m); else waiters.push(res); }),
  };
}
async function start(p: string, handle: (r: any) => Promise<unknown> = async () => ({ pong: true })) {
  const s = await startServer({ path: p, handle });
  closers.push(() => s.close());
  return s;
}

describe("server", () => {
  it("server answers after hello", async () => {
    const p = tmp();
    await start(p, async (r) => ({ echo: r.type }));
    const c = await connect(p);
    c.send({ id: 1, type: "status" });
    expect(await c.next()).toEqual({ id: 1, ok: false, error: "hello required" });
    c.send({ id: 2, type: "hello", version: 1 });
    expect(await c.next()).toEqual({ id: 2, ok: true, result: { version: 1 } });
    c.send({ id: 3, type: "status" });
    expect(await c.next()).toEqual({ id: 3, ok: true, result: { echo: "status" } });
  });

  it("server refuses version mismatch", async () => {
    const p = tmp();
    await start(p);
    const c = await connect(p);
    c.send({ id: 1, type: "hello", version: 2 });
    expect(await c.next()).toEqual({ id: 1, ok: false, error: "protocol version mismatch: server 1, client 2" });
    c.send({ id: 2, type: "status" });
    expect((await c.next()).ok).toBe(false);
  });

  it("server replaces a stale socket file", async () => {
    const p = tmp();
    fs.writeFileSync(p, "");
    await start(p);
    const c = await connect(p);
    c.send({ id: 1, type: "hello", version: 1 });
    expect((await c.next()).ok).toBe(true);
  });

  it("server refuses a live socket", async () => {
    const p = tmp();
    await start(p);
    await expect(startServer({ path: p, handle: async () => null })).rejects.toThrow("socket in use");
  });

  it("broadcast reaches every client", async () => {
    const p = tmp();
    const s = await start(p);
    const a = await connect(p);
    const b = await connect(p);
    const lurker = await connect(p); // no hello: must not receive events
    for (const c of [a, b]) {
      c.send({ id: 1, type: "hello", version: 1 });
      await c.next();
    }
    s.broadcast({ event: "mode_changed", data: { mode: "review" } });
    const ev = { event: "mode_changed", data: { mode: "review" } };
    expect(await a.next()).toEqual(ev);
    expect(await b.next()).toEqual(ev);
    lurker.send({ id: 9, type: "status" });
    expect(await lurker.next()).toEqual({ id: 9, ok: false, error: "hello required" });
  });

  it("handler errors become ok:false responses", async () => {
    const p = tmp();
    await start(p, async () => { throw new Error("boom"); });
    const c = await connect(p);
    c.send({ id: 1, type: "hello", version: 1 });
    await c.next();
    c.send({ id: 2, type: "status" });
    expect(await c.next()).toEqual({ id: 2, ok: false, error: "boom" });
  });

  it("multibyte characters split across chunks survive", async () => {
    const p = tmp();
    let seen: any;
    await start(p, async (r) => { seen = r; return { text: r.text }; });
    const c = await connect(p);
    c.send({ id: 1, type: "hello", version: 1 });
    await c.next();
    const bytes = Buffer.from(encode({ id: 2, type: "status", text: "Größe ä" }), "utf8");
    const cut = bytes.indexOf(Buffer.from("ö")) + 1; // inside the two-byte ö
    c.sock.write(bytes.subarray(0, cut));
    await new Promise((r) => setTimeout(r, 30));
    c.sock.write(bytes.subarray(cut));
    expect(await c.next()).toEqual({ id: 2, ok: true, result: { text: "Größe ä" } });
    expect(seen.text).toBe("Größe ä");
  });

  it("malformed json keeps the connection open", async () => {
    const p = tmp();
    await start(p);
    const c = await connect(p);
    c.sock.write("not json\n");
    expect(await c.next()).toEqual({ id: null, ok: false, error: "invalid json" });
    c.send({ id: 1, type: "hello", version: 1 });
    expect((await c.next()).ok).toBe(true);
  });

  it("close removes the socket file and drops clients", async () => {
    const p = tmp();
    const s = await startServer({ path: p, handle: async () => null });
    const c = await connect(p);
    const closed = new Promise<void>((res) => c.sock.once("close", () => res()));
    await s.close();
    await closed;
    expect(fs.existsSync(p)).toBe(false);
  });

  it("socketPath follows the scheme", () => {
    expect(socketPath("abc", "sess", "/run/u")).toBe("/run/u/pi-codeview/abc/sess.sock");
    const saved = process.env.XDG_RUNTIME_DIR;
    delete process.env.XDG_RUNTIME_DIR;
    try {
      expect(socketPath("abc", "sess")).toBe(path.join(os.tmpdir(), "pi-codeview", "abc", "sess.sock"));
      process.env.XDG_RUNTIME_DIR = "/x";
      expect(socketPath("abc", "sess")).toBe("/x/pi-codeview/abc/sess.sock");
    } finally {
      if (saved === undefined) delete process.env.XDG_RUNTIME_DIR; else process.env.XDG_RUNTIME_DIR = saved;
    }
  });
});
