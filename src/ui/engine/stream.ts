// The scene comes over a WebSocket, pushed by the server at each frame of the game's clock that changed it (a whole
// scene first, then what changed); without one (the socket closed) the page polls /api/scene for whole scenes until
// it is back. Input goes the same way: over the socket, in order with everything else sent on it, or posted one
// after another (a release must never overtake its press).
import { createBinaryState, readBinaryFrame } from "./binaryFrame.ts";
import type { SceneFrame } from "./items.ts";
import type { InputEvent } from "./types.ts";

const RECONNECT_MS = 1500;
const POLL_RETRY_MS = 500;

export type StreamHandlers = {
  onFrame: (frame: SceneFrame) => void;
  /** The socket opened or closed, or the poll answered or did not */
  onConnection: (isConnected: boolean) => void;
};

export type Stream = {
  /** Sent in order; resolves when posted (at once over the socket: its effect comes with the next frame) */
  send: (event: InputEvent) => Promise<void>;
  /** A whole scene asked for when the page has none; without the socket, the scene polled */
  poll: () => void;
  /** The page's scene dropped: a whole one comes next (after a reload) */
  forgetScene: () => void;
  close: () => void;
};

export const createStream = ({ onFrame, onConnection }: StreamHandlers): Stream => {
  let socket: WebSocket | null = null;
  let isClosed = false;
  let version: number | null = null;
  let fetching: Promise<boolean> | null = null;
  let inputQueue: Promise<void> = Promise.resolve();
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;

  const take = (frame: SceneFrame): void => {
    if (frame.version !== undefined && !frame.unchanged) version = frame.version;
    onFrame(frame);
  };

  const fetchScene = async (): Promise<boolean> => {
    try {
      const frame = (await (await fetch(`/api/scene?since=${version ?? ""}`)).json()) as SceneFrame;
      // (a poll answered after the socket opened is older than the socket's frames: dropped)
      if (!isClosed && !socket) {
        onConnection(true);
        take(frame);
      }
      return true;
    } catch {
      if (!isClosed) onConnection(false);
      return false;
    }
  };

  // True when it answered (or there was nothing to ask)
  const poll = async (): Promise<boolean> => {
    // With the socket, a whole scene is asked for only when the page dropped its own (version null: a reload)
    if (socket) {
      if (version === null) {
        version = -1;
        socket.send(JSON.stringify({ t: "whole" }));
      }
      return true;
    }
    if (isClosed) return true;
    // (one request at a time: a poll asked for meanwhile waits on it)
    fetching ??= fetchScene().finally(() => {
      fetching = null;
    });
    return fetching;
  };

  // One loop at a time (each failed connection would start another); the server holds a request until there is a
  // newer frame, so it does not spin, and with no server it waits a moment between tries
  let isLooping = false;
  const pollLoop = async (): Promise<void> => {
    if (isLooping) return;
    isLooping = true;
    while (!socket && !isClosed) {
      const isAnswered = await poll();
      await new Promise((resolve) => setTimeout(resolve, isAnswered ? 0 : POLL_RETRY_MS));
    }
    isLooping = false;
  };

  const connect = (): void => {
    if (isClosed) return;
    const opened = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
    // (frames come as JSON text, or binary when the simulator's native store is built: binaryFrame.ts; the keys' ids
    // a binary frame uses are this connection's)
    opened.binaryType = "arraybuffer";
    const binaryState = createBinaryState();
    opened.onopen = () => {
      if (isClosed) {
        opened.close();
        return;
      }
      socket = opened;
      onConnection(true);
    };
    opened.onmessage = (event) => {
      try {
        if (event.data instanceof ArrayBuffer) take(readBinaryFrame(event.data, binaryState));
        else take(JSON.parse(String(event.data)) as SceneFrame);
      } catch (problem) {
        console.warn("AddonSim frame", problem);
      }
    };
    opened.onclose = () => {
      const wasOpen = socket === opened;
      if (wasOpen) socket = null;
      if (isClosed) return;
      if (wasOpen) onConnection(false);
      void pollLoop();
      reconnectTimer = setTimeout(connect, RECONNECT_MS);
    };
  };
  connect();

  const post = async (event: InputEvent): Promise<void> => {
    const response = await fetch("/api/input", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(event),
    });
    await response.body?.cancel();
  };

  return {
    send: (event) => {
      if (socket) {
        socket.send(JSON.stringify({ t: "input", e: event }));
        return inputQueue;
      }
      inputQueue = inputQueue.then(() => post(event)).catch(() => {});
      return inputQueue;
    },
    poll: () => void poll(),
    forgetScene: () => {
      version = null;
      void poll();
    },
    close: () => {
      isClosed = true;
      clearTimeout(reconnectTimer);
      socket?.close();
      socket = null;
    },
  };
};
