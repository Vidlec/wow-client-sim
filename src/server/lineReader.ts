// A stream of text cut into lines, read one at a time as they are asked for: the Lua host answers each request with
// one JSON line (often 100+ KB: the text is kept as it came, never parsed here unless asked).

export type LineReader = {
  /** The next line without its newline; null once the stream has ended */
  next: () => Promise<string | null>;
};

export const createLineReader = (stream: ReadableStream<Uint8Array>): LineReader => {
  const reader = stream.getReader();
  const decoder = new TextDecoder(); // (streaming: a character split between two chunks is kept whole)
  const ready: string[] = []; // lines read and not yet asked for
  let partial = "";
  let isDone = false;

  const fill = async (): Promise<void> => {
    while (ready.length === 0 && !isDone) {
      const { value, done } = await reader.read();
      if (done) {
        isDone = true;
        if (partial) ready.push(partial);
        partial = "";
        return;
      }
      const lines = (partial + decoder.decode(value, { stream: true })).split("\n");
      partial = lines.pop() ?? "";
      for (const line of lines) ready.push(line.endsWith("\r") ? line.slice(0, -1) : line);
    }
  };

  return {
    next: async () => {
      await fill();
      return ready.shift() ?? null;
    },
  };
};
