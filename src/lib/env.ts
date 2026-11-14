/** 判断是否运行在 Tauri WebView 内（`pnpm dev` 的纯浏览器预览没有 IPC） */
export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}
