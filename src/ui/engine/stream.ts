// The scene comes over a WebSocket, pushed by the server at each frame of the game's clock that changed it (a whole
// scene first, then what changed), as binary frames (binaryFrame.ts); while the socket is closed the page shows it
// and tries again. Input goes over the socket, in order with everything else sent on it, or, without one, is posted
// one after another (a release must never overtake its press).
import { createBinaryState, readBinaryFrame } from "./binaryFrame.ts";
import type { SceneFrame } from "./items.ts";
import type { InputEvent } from "./types.ts";

const RECONNECT_MS = 1500;

export type StreamHandlers = {
  onFrame: (frame: SceneFrame) => void;
  /** The socket opened or closed */
  onConnection: (isConnected: boolean) => void;
};

export type Stream = {
  /** Sent in order; resolves when posted (at once over the socket: its effect comes with the next frame) */
  send: (event: InputEvent) => Promise<void>;
  /** A whole scene asked for when the page has none (it comes over the socket) */
  poll: () => void;
  /** The page's scene dropped: a whole one comes next (after a reload) */
  forgetScene: () => void;
  close: () => void;
};

export const createStream = ({ onFrame, onConnection }: StreamHandlers): Stream => {
  let socket: WebSocket | null = null;
  let isClosed = false;
  let version: number | null = null;
  let inputQueue: Promise<void> = Promise.resolve();
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;

  const take = (frame: SceneFrame): void => {
    if (frame.version !== undefined) version = frame.version;
    onFrame(frame);
  };

  // A whole scene is asked for only when the page dropped its own (version null: a reload); without the socket, the
  // one it opens with is whole
  const poll = (): void => {
    if (socket && version === null) {
      version = -1;
      socket.send(JSON.stringify({ t: "whole" }));
    }
  };

  const connect = (): void => {
    if (isClosed) return;
    const opened = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
    // (a frame is binary when it carries the scene, binaryFrame.ts, the keys' ids it uses this connection's; JSON
    // text when only the counts, the pointer or the sounds changed)
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
    poll,
    forgetScene: () => {
      version = null;
      poll();
    },
    close: () => {
      isClosed = true;
      clearTimeout(reconnectTimer);
      socket?.close();
      socket = null;
    },
  };
};
