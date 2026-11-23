// One thing at a time: the Lua host reads one request and writes one answer, so requests must not interleave.

export type Mutex = {
  run: <T>(work: () => Promise<T> | T) => Promise<T>;
};

export const createMutex = (): Mutex => {
  let tail: Promise<unknown> = Promise.resolve();
  return {
    run: <T>(work: () => Promise<T> | T): Promise<T> => {
      const result = tail.then(work);
      tail = result.catch(() => undefined); // a failed request does not block the ones after it
      return result;
    },
  };
};
