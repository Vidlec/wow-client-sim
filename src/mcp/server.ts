// `addonsim mcp`: an MCP server on stdio (JSON-RPC 2.0, a message a line), so an agent such as Claude Code drives the
// project's game with tools (tools.ts). Written against the protocol itself, not the official SDK: the few methods
// a tools-only server answers (initialize, tools/list, tools/call, ping) are less code than the dependency, and no
// new package is needed.
//
// Its game is the project's daemon's when one runs (shared with the CLI); else the server holds the game itself and
// is the project's daemon for as long as it runs, so `addonsim eval` in a shell reaches the same game.
import type { Project } from "../project/config.ts";
import { type DaemonHandle, serveDaemon } from "../sdk/daemon.ts";
import { LocalSim } from "../sdk/local.ts";
import { findDaemon, RemoteSim } from "../sdk/remote.ts";
import type { Sim } from "../sdk/sim.ts";
import { createLineReader } from "../server/lineReader.ts";
import { APP_VERSION } from "../server/paths.ts";
import { TOOLS } from "./tools.ts";

const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

type Message = { jsonrpc?: string; id?: string | number | null; method?: string; params?: Record<string, unknown> };

const INSTRUCTIONS =
  "AddonSim: a WoW: Forever client simulator running this project's addons. Loop: edit the addon's Lua, `run` the " +
  "scenario that covers it (a warm game: no boot wait), read the failures (file:line), look with `ui` (text, cheap) " +
  "or `screenshot` (an image), poke with `eval`/`click`/`key`, repeat; `test` before finishing. `docs` lists the steps.";

const write = (message: Record<string, unknown>): void => {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
};

/** The game the tools use: the running daemon's, else one held here and served as the daemon */
const openSim = async (project: Project): Promise<{ sim: Sim; daemon: DaemonHandle | null }> => {
  const running = await findDaemon(project);
  if (running) return { sim: new RemoteSim(project, running.file, false), daemon: null };
  const sim = new LocalSim(project);
  sim.engine.prewarm();
  // (asked to stop, as the CLI asks a daemon older than the simulator's code: this server stops being the daemon,
  // and keeps its game for its own tools)
  const daemon: DaemonHandle = serveDaemon(project, sim.engine, { idleMinutes: 0, onEnd: () => void daemon.stop() });
  return { sim, daemon };
};

export const runMcpServer = async (project: Project): Promise<void> => {
  let opened: Promise<{ sim: Sim; daemon: DaemonHandle | null }> | null = null;
  const getSim = (): Promise<{ sim: Sim; daemon: DaemonHandle | null }> => {
    opened ??= openSim(project);
    return opened;
  };
  // (booting starts at once, while the client is still saying hello)
  void getSim();

  const answer = async (message: Message): Promise<void> => {
    const { id, method, params = {} } = message;
    const isRequest = id !== undefined && id !== null;
    const reply = (result: Record<string, unknown>): void => {
      if (isRequest) write({ id, result });
    };
    const fail = (code: number, text: string): void => {
      if (isRequest) write({ id, error: { code, message: text } });
    };
    switch (method) {
      case "initialize": {
        const asked = String(params.protocolVersion ?? "");
        reply({
          protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "addonsim", version: APP_VERSION },
          instructions: INSTRUCTIONS,
        });
        return;
      }
      case "ping":
        reply({});
        return;
      case "tools/list":
        reply({
          tools: TOOLS.map((tool) => ({
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
          })),
        });
        return;
      case "tools/call": {
        const tool = TOOLS.find((item) => item.name === params.name);
        if (!tool) {
          fail(-32602, `no tool ${String(params.name)}`);
          return;
        }
        try {
          const { sim } = await getSim();
          const args = (params.arguments ?? {}) as Record<string, unknown>;
          reply(await tool.call(sim, args));
        } catch (error) {
          // (a tool's failure is the tool's answer, for the agent to read: not a protocol error)
          reply({
            content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
            isError: true,
          });
        }
        return;
      }
      default:
        if (method?.startsWith("notifications/")) return;
        fail(-32601, `no method ${String(method)}`);
    }
  };

  const shutDown = async (): Promise<void> => {
    if (opened) {
      const { sim, daemon } = await opened;
      await daemon?.stop();
      await sim.close();
    }
    process.exit(0);
  };
  process.on("SIGINT", () => void shutDown());
  process.on("SIGTERM", () => void shutDown());

  const lines = createLineReader(Bun.stdin.stream());
  const pending = new Set<Promise<void>>();
  for (let line = await lines.next(); line !== null; line = await lines.next()) {
    if (!line.trim()) continue;
    let message: Message;
    try {
      message = JSON.parse(line) as Message;
    } catch {
      write({ id: null, error: { code: -32700, message: "parse error" } });
      continue;
    }
    // (calls answered as they finish: a ping is not held up by a long test)
    const work = answer(message).catch((error: unknown) => {
      process.stderr.write(`mcp: ${error instanceof Error ? error.message : String(error)}\n`);
    });
    pending.add(work);
    void work.finally(() => pending.delete(work));
  }
  // The client closed the pipe: the calls under way finish, then the game goes
  await Promise.all(pending);
  await shutDown();
};
