import { createElement } from "lwc";
import QuotePdfGenerator from "c/quotePdfGenerator";
import { loadScript } from "lightning/platformResourceLoader";
import getQuotePdfData from "@salesforce/apex/QuotePdfController.getQuotePdfData";

// Apexワイヤアダプタをテスト用アダプタに差し替える。
// jest.mock のファクトリはスコープ外の変数を参照できないため require で読み込む。
jest.mock(
  "@salesforce/apex/QuotePdfController.getQuotePdfData",
  () => {
    const {
      createApexTestWireAdapter
    } = require("@salesforce/wire-service-jest-util");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);

const RECORD_ID = "a00000000000001AAA";

/** 10%と8%が混在する見積のモックデータ。 */
const MOCK_QUOTE_DATA = {
  quote: {
    quoteNumber: "Q-00001",
    subject: "基幹システム刷新支援",
    quoteDate: "2026-08-14",
    expirationDate: "2026-09-13",
    status: "作成中",
    customerName: "株式会社テスト商事",
    honorific: null,
    contactName: "山田 太郎",
    deliveryDate: "別途協議",
    deliveryPlace: "貴社指定場所",
    paymentTerms: "月末締め翌月末払い",
    notes: "本見積には保守費用を含みません。",
    subtotal: 1000000,
    taxableBase10: 900000,
    taxableBase8: 100000,
    taxAmount10: 90000,
    taxAmount8: 8000,
    taxAmount: 98000,
    totalAmount: 1098000
  },
  lines: [
    {
      recordId: "a01000000000001AAA",
      lineNumber: 1,
      productName: "要件定義支援",
      description: "3か月分",
      quantity: 3,
      unit: "人月",
      unitPrice: 200000,
      amount: 600000,
      taxRate: "10%",
      taxAmount: 60000
    },
    {
      recordId: "a01000000000002AAA",
      lineNumber: 2,
      productName: "設計支援",
      description: "",
      quantity: 1.5,
      unit: "人月",
      unitPrice: 200000,
      amount: 300000,
      taxRate: "10%",
      taxAmount: 30000
    },
    {
      recordId: "a01000000000003AAA",
      lineNumber: 3,
      productName: "会議用弁当",
      description: "軽減税率対象",
      quantity: 100,
      unit: "個",
      unitPrice: 1000,
      amount: 100000,
      taxRate: "8%",
      taxAmount: 8000
    }
  ],
  issuer: {
    companyName: "株式会社サンプル",
    postalCode: "100-0001",
    address: "東京都千代田区千代田1-1",
    phone: "03-0000-0000",
    fax: "03-0000-0001",
    invoiceRegistrationNumber: "T1234567890123",
    bankAccount: "サンプル銀行 本店 普通 1234567"
  }
};

/** 8%対象額が0(10%のみ)の見積データ。 */
const MOCK_QUOTE_DATA_WITHOUT_REDUCED_RATE = {
  ...MOCK_QUOTE_DATA,
  quote: {
    ...MOCK_QUOTE_DATA.quote,
    taxableBase10: 1000000,
    taxableBase8: 0,
    taxAmount10: 100000,
    taxAmount8: 0,
    taxAmount: 100000,
    totalAmount: 1100000
  },
  lines: MOCK_QUOTE_DATA.lines.slice(0, 2)
};

/** マイクロタスクを消化してLWCの再レンダリングを待つ。 */
async function flushPromises() {
  for (let i = 0; i < 5; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
  }
}

/** PDF生成テスト用の jsPDF ドキュメントスタブを作る。 */
function createJsPdfDocMock() {
  return {
    addFileToVFS: jest.fn(),
    addFont: jest.fn(),
    setFont: jest.fn(),
    setFontSize: jest.fn(),
    setLineWidth: jest.fn(),
    setFillColor: jest.fn(),
    setPage: jest.fn(),
    text: jest.fn(),
    line: jest.fn(),
    rect: jest.fn(),
    addPage: jest.fn(),
    getTextWidth: jest.fn(() => 30),
    splitTextToSize: jest.fn((text) => [String(text)]),
    getNumberOfPages: jest.fn(() => 1),
    save: jest.fn()
  };
}

function createComponent() {
  const element = createElement("c-quote-pdf-generator", {
    is: QuotePdfGenerator
  });
  element.recordId = RECORD_ID;
  document.body.appendChild(element);
  return element;
}

describe("c-quote-pdf-generator", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    delete window.jspdf;
    delete window.NotoSansJPNormal;
  });

  it("recordIdセッターで受け取った値を保持する", () => {
    const element = createElement("c-quote-pdf-generator", {
      is: QuotePdfGenerator
    });
    element.recordId = RECORD_ID;
    document.body.appendChild(element);

    expect(element.recordId).toBe(RECORD_ID);
  });

  it("データ受信時に明細行が件数どおり描画される", async () => {
    const element = createComponent();
    getQuotePdfData.emit(MOCK_QUOTE_DATA);
    await flushPromises();

    const rows = element.shadowRoot.querySelectorAll('[data-id="line-row"]');
    expect(rows.length).toBe(MOCK_QUOTE_DATA.lines.length);
    expect(rows[0].textContent).toContain("要件定義支援");
    // 数量・単価が3桁区切りで整形されていること
    expect(rows[2].textContent).toContain("100,000");
  });

  it("合計金額(税込)が3桁区切りで表示される", async () => {
    const element = createComponent();
    getQuotePdfData.emit(MOCK_QUOTE_DATA);
    await flushPromises();

    const total = element.shadowRoot.querySelector('[data-id="total-amount"]');
    expect(total).not.toBeNull();
    expect(total.textContent).toContain("1,098,000");

    const summaryTotal = element.shadowRoot.querySelector(
      '[data-id="summary-total"]'
    );
    expect(summaryTotal.textContent).toContain("1,098,000");
  });

  it("敬称が未設定の場合は「御中」を補って宛名を表示する", async () => {
    const element = createComponent();
    getQuotePdfData.emit(MOCK_QUOTE_DATA);
    await flushPromises();

    const customer = element.shadowRoot.querySelector(
      '[data-id="customer-name"]'
    );
    expect(customer.textContent).toContain("株式会社テスト商事 御中");
  });

  it("見積日をyyyy年M月d日形式で表示する", async () => {
    const element = createComponent();
    getQuotePdfData.emit(MOCK_QUOTE_DATA);
    await flushPromises();

    const quoteDate = element.shadowRoot.querySelector(
      '[data-id="quote-date"]'
    );
    expect(quoteDate.textContent.trim()).toBe("2026年8月14日");
  });

  it("8%対象額が0のときは8%の集計行を描画しない", async () => {
    const element = createComponent();
    getQuotePdfData.emit(MOCK_QUOTE_DATA_WITHOUT_REDUCED_RATE);
    await flushPromises();

    expect(
      element.shadowRoot.querySelector('[data-id="taxable-base-8-row"]')
    ).toBeNull();
    expect(
      element.shadowRoot.querySelector('[data-id="tax-amount-8-row"]')
    ).toBeNull();
    // 10%の集計と合計は表示され続けること
    expect(
      element.shadowRoot.querySelector('[data-id="summary-total"]').textContent
    ).toContain("1,100,000");
  });

  it("8%対象額があるときは8%の集計行を描画する", async () => {
    const element = createComponent();
    getQuotePdfData.emit(MOCK_QUOTE_DATA);
    await flushPromises();

    expect(
      element.shadowRoot.querySelector('[data-id="taxable-base-8-row"]')
    ).not.toBeNull();
    expect(
      element.shadowRoot.querySelector('[data-id="tax-amount-8-row"]')
    ).not.toBeNull();
  });

  it("wireエラー時にエラーメッセージを表示しプレビューを描画しない", async () => {
    const element = createComponent();
    getQuotePdfData.error({
      message: "見積が見つからないか、参照する権限がありません。"
    });
    await flushPromises();

    const errorElement = element.shadowRoot.querySelector(
      '[data-id="error-message"]'
    );
    expect(errorElement).not.toBeNull();
    expect(errorElement.textContent).toContain(
      "見積が見つからないか、参照する権限がありません。"
    );
    expect(element.shadowRoot.querySelector('[data-id="preview"]')).toBeNull();
  });

  it("PDFボタン押下時に静的リソースを遅延ロードし、2回目は再ロードしない", async () => {
    const docMock = createJsPdfDocMock();
    window.jspdf = { jsPDF: jest.fn(() => docMock) };
    window.NotoSansJPNormal = "BASE64_FONT";

    const element = createComponent();
    getQuotePdfData.emit(MOCK_QUOTE_DATA);
    await flushPromises();

    // 初期化時点ではフォントを読み込まない
    expect(loadScript).not.toHaveBeenCalled();

    const button = element.shadowRoot.querySelector(
      '[data-id="download-button"]'
    );
    button.click();
    await flushPromises();

    // jsPDF本体とフォントの2リソース
    expect(loadScript).toHaveBeenCalledTimes(2);
    expect(docMock.addFileToVFS).toHaveBeenCalledWith(
      "NotoSansJP.ttf",
      "BASE64_FONT"
    );
    expect(docMock.addFont).toHaveBeenCalledWith(
      "NotoSansJP.ttf",
      "NotoSansJP",
      "normal"
    );
    expect(docMock.save).toHaveBeenCalledWith("見積書_Q-00001.pdf");

    // 2回目は読み込み済みフラグにより再ロードしない
    loadScript.mockClear();
    button.click();
    await flushPromises();
    expect(loadScript).not.toHaveBeenCalled();
  });
});
