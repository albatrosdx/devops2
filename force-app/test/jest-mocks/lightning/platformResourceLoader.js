/**
 * lightning/platformResourceLoader のJestモック。
 * 実際の静的リソースは読み込まず、解決済みのPromiseを返すだけにする。
 * 呼び出し検証ができるよう jest.fn() で公開する。
 */
export const loadScript = jest.fn(() => Promise.resolve());
export const loadStyle = jest.fn(() => Promise.resolve());
