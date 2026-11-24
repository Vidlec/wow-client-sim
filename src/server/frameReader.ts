// The Lua host's answers, one at a time: each a JSON line, which a binary frame follows when the line ends with its
// length (`,"bin":N,"id":…}`: the scene stream's binary frames, lua/stream.lua). The text is kept as it came, never
// parsed here; the bytes are handed on as they are.

export type HostReply = {
  /** The answer's JSON line, without its newline */
  text: string;
  /** The binary part that followed it, when the line said so */
  bin?: Uint8Array;
};

export type FrameReader = {
  /** The next answer; null once the stream has ended */
  next: () => Promise<HostReply | null>;
};

// (anchored at the line's end: a string inside the answer cannot end the line so, its quotes are escaped)
const BINARY_LENGTH = /,"bin":(\d+),"id":-?\d+\}\r?$/;
const NEWLINE = 10;

export const createFrameReader = (stream: ReadableStream<Uint8Array>): FrameReader => {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let chunks: Uint8Array[] = []; // read and not yet taken, in order
  let buffered = 0;
  let isDone = false;

  const readMore = async (): Promise<boolean> => {
    if (isDone) return false;
    const { value, done } = await reader.read();
    if (done || !value) {
      isDone = true;
      return false;
    }
    chunks.push(value);
    buffered += value.length;
    return true;
  };

  /** The first `count` bytes held, taken off */
  const take = (count: number): Uint8Array => {
    const out = new Uint8Array(count);
    let filled = 0;
    while (filled < count) {
      const chunk = chunks[0] as Uint8Array;
      const part = Math.min(chunk.length, count - filled);
      out.set(chunk.subarray(0, part), filled);
      filled += part;
      if (part === chunk.length) chunks.shift();
      else chunks[0] = chunk.subarray(part);
    }
    buffered -= count;
    return out;
  };

  /** Where the first newline is among the bytes held (from their start), or -1 */
  const newlineAt = (): number => {
    let offset = 0;
    for (const chunk of chunks) {
      const at = chunk.indexOf(NEWLINE);
      if (at >= 0) return offset + at;
      offset += chunk.length;
    }
    return -1;
  };

  return {
    next: async () => {
      let at = newlineAt();
      while (at < 0) {
        if (!(await readMore())) {
          if (buffered === 0) return null;
          const rest = decoder.decode(take(buffered));
          chunks = [];
          return { text: rest };
        }
        at = newlineAt();
      }
      const lineBytes = take(at + 1);
      let text = decoder.decode(lineBytes.subarray(0, at));
      if (text.endsWith("\r")) text = text.slice(0, -1);
      const binary = BINARY_LENGTH.exec(text);
      if (!binary) return { text };
      const length = Number(binary[1]);
      while (buffered < length) {
        if (!(await readMore())) return { text };
      }
      return { text, bin: take(length) };
    },
  };
};
