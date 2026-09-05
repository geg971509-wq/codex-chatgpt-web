import { expect, test } from "bun:test";
import { readJsonRequestBody } from "../src/http-body";

test("decodes Codex zstd-compressed JSON request bodies", async () => {
  const body = { model: "chatgpt-web/pro", reasoning: { effort: "ultra" }, input: [{ role: "user", content: "hello" }] };
  const compressed = Bun.zstdCompressSync(Buffer.from(JSON.stringify(body)));
  const encoded = new ArrayBuffer(compressed.byteLength);
  new Uint8Array(encoded).set(compressed);
  const request = new Request("http://127.0.0.1/v1/responses", {
    method: "POST",
    headers: { "content-type": "application/json", "content-encoding": "zstd" },
    body: encoded,
  });

  expect(await readJsonRequestBody(request)).toEqual(body);
});

test("rejects unsupported request content encodings", async () => {
  const request = new Request("http://127.0.0.1/v1/responses", {
    method: "POST",
    headers: { "content-type": "application/json", "content-encoding": "br" },
    body: "{}",
  });

  await expect(readJsonRequestBody(request)).rejects.toThrow("Unsupported Content-Encoding: br");
});

test("stops and cancels an oversized streamed body before consuming the remainder", async () => {
  let pulled = 0;
  let cancelled = false;
  const totalChunks = 40;
  const chunk = new Uint8Array(2 * 1024 * 1024);
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (pulled === totalChunks) controller.close();
      else { pulled += 1; controller.enqueue(chunk); }
    },
    cancel() { cancelled = true; },
  }, { highWaterMark: 0 });
  const request = new Request("http://127.0.0.1/v1/responses", { method: "POST", body });
  await expect(readJsonRequestBody(request)).rejects.toThrow("Encoded request body");
  expect(cancelled).toBe(true);
  expect(pulled).toBeLessThan(totalChunks);
});

test("decodes identity JSON and rejects malformed UTF-8", async () => {
  const body = { input: "你好", store: false };
  expect(await readJsonRequestBody(new Request("http://localhost", {
    method: "POST", body: JSON.stringify(body),
  }))).toEqual(body);
  await expect(readJsonRequestBody(new Request("http://localhost", {
    method: "POST", body: new Uint8Array([0xff]),
  }))).rejects.toThrow();
});

test("rejects zstd output larger than the decoded limit", async () => {
  const compressed = Bun.zstdCompressSync(Buffer.alloc(128 * 1024 * 1024 + 1, 32));
  const request = new Request("http://localhost", {
    method: "POST", headers: { "content-encoding": "zstd" }, body: new Uint8Array(compressed),
  });
  await expect(readJsonRequestBody(request)).rejects.toThrow("Decoded request body");
});
