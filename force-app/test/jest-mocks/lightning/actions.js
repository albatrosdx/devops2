/**
 * lightning/actions のJestモック。
 * クイックアクションのモーダルを閉じるイベントの最小実装。
 */
export const CloseActionScreenEvent = class extends CustomEvent {
  constructor() {
    super("lightning__closeactionscreen", {
      bubbles: true,
      composed: true
    });
  }
};
