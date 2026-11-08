// Compresses bitmaps off the main thread (zlib, level 1) for Kitty's o=z. Messages: {id, data} -> {id, z, data}.
// Both buffers are transferred, so nothing is copied.
import { deflateSync } from "node:zlib";

const scope = self as unknown as Worker;
scope.onmessage = (e: MessageEvent<{ id: number; data: Uint8Array }>) => {
  const { id, data } = e.data;
  const z = new Uint8Array(deflateSync(data, { level: 1 }));
  scope.postMessage({ id, z, data }, [z.buffer as ArrayBuffer, data.buffer as ArrayBuffer]);
};
