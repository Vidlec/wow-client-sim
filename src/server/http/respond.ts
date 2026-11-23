// Answers in the shapes the page expects

/** (Bytes here never sit in a SharedArrayBuffer: the body types want a plain ArrayBuffer behind them) */
const asBody = (data: Uint8Array): Uint8Array<ArrayBuffer> => data as Uint8Array<ArrayBuffer>;

export const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

/** JSON the simulator already wrote, passed on as it is */
export const jsonText = (text: string, status = 200): Response =>
  new Response(text, { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

export const notFound = (): Response => json({ error: "not found" }, 404);

/**
 * Art kept by the browser, tagged with the client's build: a file's id may hold other art in another build (the
 * minimap header's sheet held the sun and moon in 70009), so after a build change the browser asks again instead of
 * reusing what it kept; while the build stays, the answer is a quick "not modified"
 */
export const cachedBytes = (request: Request, build: string, data: Uint8Array, contentType: string): Response => {
  const etag = `"${build}"`;
  const headers = { ETag: etag, "Cache-Control": "no-cache" };
  if (request.headers.get("If-None-Match") === etag) return new Response(null, { status: 304, headers });
  return new Response(asBody(data), { headers: { ...headers, "Content-Type": contentType } });
};

export const bytes = (data: Uint8Array, contentType: string): Response =>
  new Response(asBody(data), { headers: { "Content-Type": contentType, "Cache-Control": "no-store" } });

/** A request's JSON body, or an empty object when it has none or it is not JSON */
export const readBody = async (request: Request): Promise<Record<string, unknown>> => {
  try {
    const value: unknown = await request.json();
    return value !== null && typeof value === "object" ? (value as Record<string, unknown>) : {};
  } catch {
    return {};
  }
};
