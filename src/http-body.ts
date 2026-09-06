import { promisify } from "node:util";
import { zstdDecompress } from "node:zlib";

const MAX_ENCODED_REQUEST_BYTES = 64 * 1024 * 1024;
const MAX_DECODED_REQUEST_BYTES = 128 * 1024 * 1024;
const decompressZstd = promisify(zstdDecompress);

function assertWithinLimit(bytes: number, limit: number, label: string): void {
  if (bytes > limit) throw new Error(`${label} exceeds ${limit} bytes`);
}

async function readEncodedBody(request: Request): Promise<Uint8Array> {
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      assertWithinLimit(bytes, MAX_ENCODED_REQUEST_BYTES, "Encoded request body");
      chunks.push(value);
    }
    return Buffer.concat(chunks, bytes);
  } catch (error) {
    // Stop upstream reads without allowing a slow cancellation to delay rejection.
    void reader.cancel(error).catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
}

export async function readJsonRequestBody(request: Request): Promise<unknown> {
  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength)) {
    assertWithinLimit(declaredLength, MAX_ENCODED_REQUEST_BYTES, "Encoded request body");
  }

  const contentEncoding = (request.headers.get("content-encoding") ?? "identity").trim().toLowerCase();
  if (!["", "identity", "zstd"].includes(contentEncoding)) {
    throw new Error(`Unsupported Content-Encoding: ${contentEncoding}`);
  }

  const encoded = await readEncodedBody(request);
  let decoded: Uint8Array = encoded;
  if (contentEncoding === "zstd") {
    try {
      decoded = await decompressZstd(encoded, { maxOutputLength: MAX_DECODED_REQUEST_BYTES });
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code === "ERR_BUFFER_TOO_LARGE") {
        throw new Error(`Decoded request body exceeds ${MAX_DECODED_REQUEST_BYTES} bytes`);
      }
      throw error;
    }
  }
  assertWithinLimit(decoded.byteLength, MAX_DECODED_REQUEST_BYTES, "Decoded request body");

  const text = new TextDecoder("utf-8", { fatal: true }).decode(decoded);
  return JSON.parse(text) as unknown;
}
