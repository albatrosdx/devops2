import { LightningElement, api, wire } from "lwc";
import { loadScript } from "lightning/platformResourceLoader";
import { CloseActionScreenEvent } from "lightning/actions";
import getQuotePdfData from "@salesforce/apex/QuotePdfController.getQuotePdfData";
import JSPDF_RESOURCE from "@salesforce/resourceUrl/jspdf";
import NOTO_SANS_JP_RESOURCE from "@salesforce/resourceUrl/NotoSansJPNormal";

/** 既定の敬称。見積側で未設定の場合に使用する。 */
const DEFAULT_HONORIFIC = "御中";

/** jsPDF の VFS 上に登録するフォントファイル名と論理フォント名。 */
const PDF_FONT_FILE = "NotoSansJP.ttf";
const PDF_FONT_NAME = "NotoSansJP";

/**
 * 金額表示用フォーマッタ。
 * 日本円は最小単位が1円のため小数は表示しない(Apex側でも税額は切り捨て済み)。
 */
const CURRENCY_FORMATTER = new Intl.NumberFormat("ja-JP", {
  maximumFractionDigits: 0
});

/** 数量表示用フォーマッタ。数量は小数第2位まで持ちうる。 */
const QUANTITY_FORMATTER = new Intl.NumberFormat("ja-JP", {
  maximumFractionDigits: 2
});

/**
 * PDFレイアウト定数(単位: mm / A4縦 = 210 x 297)。
 * すべてのY座標計算をこの1か所に集約し、改ページ判定を単純化する。
 */
const PDF_LAYOUT = {
  pageWidth: 210,
  pageHeight: 297,
  marginX: 15,
  marginTop: 16,
  marginBottom: 18,
  contentWidth: 180,
  textLineHeight: 4.4,
  tableRowMinHeight: 7,
  summaryRowHeight: 7,
  summaryBoxWidth: 85
};

/**
 * 明細テーブルの列定義。width の合計は contentWidth(180mm) と一致させること。
 * key は printableLines が生成する整形済みプロパティ名に対応する。
 * 税率は「非課税」(全角3文字)が折り返さない幅を確保している。
 */
const TABLE_COLUMNS = [
  { key: "lineNumberText", label: "No.", width: 9, align: "center" },
  { key: "productName", label: "品名", width: 43, align: "left" },
  { key: "description", label: "摘要", width: 43, align: "left" },
  { key: "quantityText", label: "数量", width: 13, align: "right" },
  { key: "unit", label: "単位", width: 10, align: "center" },
  { key: "unitPriceText", label: "単価", width: 22, align: "right" },
  { key: "amountText", label: "金額", width: 26, align: "right" },
  { key: "taxRate", label: "税率", width: 14, align: "center" }
];

/** 明細テーブルの見出し行の背景色(RGB)。 */
const TABLE_HEADER_FILL = [238, 238, 238];

/** 金額(数値)を3桁区切りの文字列にする。null/未定義は 0 として扱う。 */
function formatCurrency(value) {
  const numeric = Number(value);
  return CURRENCY_FORMATTER.format(
    Number.isFinite(numeric) ? Math.round(numeric) : 0
  );
}

/** 数量(数値)を3桁区切りの文字列にする。 */
function formatQuantity(value) {
  const numeric = Number(value);
  return QUANTITY_FORMATTER.format(Number.isFinite(numeric) ? numeric : 0);
}

/**
 * Apex の Date 項目(`YYYY-MM-DD` 文字列)を `yyyy年M月d日` に整形する。
 * Date オブジェクトを経由するとタイムゾーンで日付がずれるため、文字列のまま処理する。
 */
function formatJapaneseDate(value) {
  if (!value) {
    return "";
  }
  const parts = String(value).split("-");
  if (parts.length < 3) {
    return String(value);
  }
  const year = Number(parts[0]);
  const month = Number(parts[1]);
  const day = Number(parts[2].substring(0, 2));
  if (!year || !month || !day) {
    return String(value);
  }
  return `${year}年${month}月${day}日`;
}

/** null/空文字を除いた文字列を返す。PDF/プレビュー双方の空欄表示に使う。 */
function textOrEmpty(value) {
  return value === null || value === undefined ? "" : String(value);
}

/** wire / 例外オブジェクトから利用者向けのメッセージを取り出す。 */
function extractErrorMessage(error) {
  if (!error) {
    return "";
  }
  if (Array.isArray(error.body)) {
    return error.body.map((entry) => entry.message).join(" / ");
  }
  if (error.body && error.body.message) {
    return error.body.message;
  }
  if (error.message) {
    return error.message;
  }
  return "原因不明のエラーが発生しました。";
}

/**
 * 見積書のプレビュー表示と日本語PDFのダウンロードを行う画面クイックアクション。
 *
 * 注意: LWCクイックアクション(ScreenAction)では recordId が connectedCallback() の
 * 時点では未設定のため、必ず setter 経由で受け取る必要がある。
 */
export default class QuotePdfGenerator extends LightningElement {
  /** クイックアクションから注入されるレコードID(内部保持用)。 */
  _recordId;

  /** wire で取得した整形済みデータ。 */
  quoteData;

  /** 画面に表示するエラーメッセージ。 */
  errorMessage = "";

  /** PDF生成(フォント読込を含む)の実行中フラグ。 */
  isGenerating = false;

  /** 静的リソース読み込み完了フラグ。2回目以降の再ロードを避けるために保持する。 */
  _librariesLoaded = false;

  /** wire の応答待ちフラグ。初期表示のスピナー制御に使う。 */
  _wirePending = true;

  /**
   * レコードID。
   * ScreenAction では connectedCallback() より後に設定されるため setter で受ける。
   */
  @api
  get recordId() {
    return this._recordId;
  }

  set recordId(value) {
    this._recordId = value;
  }

  @wire(getQuotePdfData, { quoteId: "$_recordId" })
  wiredQuotePdfData({ data, error }) {
    if (data) {
      this.quoteData = data;
      this.errorMessage = "";
      this._wirePending = false;
    } else if (error) {
      this.quoteData = undefined;
      this.errorMessage =
        extractErrorMessage(error) || "見積データを取得できませんでした。";
      this._wirePending = false;
    }
  }

  // ------------------------------------------------------------------
  // 画面表示用のゲッター
  // ------------------------------------------------------------------

  /** 読み込み中(wire未応答かつエラーなし)かどうか。 */
  get isLoading() {
    return this._wirePending && !this.errorMessage;
  }

  /** プレビューを描画できる状態かどうか。 */
  get hasData() {
    return Boolean(this.quoteData && this.quoteData.quote);
  }

  /** 見積ヘッダ。未取得時も参照できるよう空オブジェクトを返す。 */
  get quote() {
    return (this.quoteData && this.quoteData.quote) || {};
  }

  /** 発行元情報。 */
  get issuer() {
    return (this.quoteData && this.quoteData.issuer) || {};
  }

  /** 明細行(プレビューとPDFで共有する整形済みデータ)。 */
  get printableLines() {
    const lines = (this.quoteData && this.quoteData.lines) || [];
    return lines.map((line, index) => ({
      recordId: line.recordId || `line-${index}`,
      lineNumberText:
        line.lineNumber === null || line.lineNumber === undefined
          ? String(index + 1)
          : String(Math.round(Number(line.lineNumber))),
      productName: textOrEmpty(line.productName),
      description: textOrEmpty(line.description),
      quantityText: formatQuantity(line.quantity),
      unit: textOrEmpty(line.unit),
      unitPriceText: formatCurrency(line.unitPrice),
      amountText: formatCurrency(line.amount),
      taxRate: textOrEmpty(line.taxRate)
    }));
  }

  /** 宛名(敬称込み)。敬称が未設定なら「御中」を補う。 */
  get customerNameWithHonorific() {
    const name = textOrEmpty(this.quote.customerName);
    if (!name) {
      return "";
    }
    const honorific = textOrEmpty(this.quote.honorific) || DEFAULT_HONORIFIC;
    return `${name} ${honorific}`;
  }

  get quoteDateText() {
    return formatJapaneseDate(this.quote.quoteDate);
  }

  get expirationDateText() {
    return formatJapaneseDate(this.quote.expirationDate);
  }

  get subtotalText() {
    return formatCurrency(this.quote.subtotal);
  }

  get taxableBase10Text() {
    return formatCurrency(this.quote.taxableBase10);
  }

  get taxAmount10Text() {
    return formatCurrency(this.quote.taxAmount10);
  }

  get taxableBase8Text() {
    return formatCurrency(this.quote.taxableBase8);
  }

  get taxAmount8Text() {
    return formatCurrency(this.quote.taxAmount8);
  }

  get totalAmountText() {
    return formatCurrency(this.quote.totalAmount);
  }

  /** 軽減税率(8%)対象がある場合のみ8%の行を描画する。 */
  get hasReducedTaxRate() {
    return Number(this.quote.taxableBase8) > 0;
  }

  /** PDFボタンのラベル。処理中は状態が分かる文言にする。 */
  get downloadButtonLabel() {
    return this.isGenerating ? "PDFを生成中..." : "PDFをダウンロード";
  }

  /** データ未取得中・生成中はダウンロードを許可しない。 */
  get isDownloadDisabled() {
    return this.isGenerating || !this.hasData;
  }

  // ------------------------------------------------------------------
  // イベントハンドラ
  // ------------------------------------------------------------------

  handleClose() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  /**
   * PDFを生成してダウンロードする。
   * フォント静的リソースが約2.9MBあるため、初期化時ではなくここで遅延ロードする。
   */
  async handleDownloadPdf() {
    if (this.isDownloadDisabled) {
      return;
    }
    this.isGenerating = true;
    this.errorMessage = "";
    try {
      await this.loadPdfLibraries();
      const doc = this.buildPdfDocument();
      doc.save(this.pdfFileName);
    } catch (error) {
      this.errorMessage = `PDFの生成に失敗しました。${extractErrorMessage(error)}`;
    } finally {
      this.isGenerating = false;
    }
  }

  /** jsPDF本体と日本語フォントを読み込む。読み込み済みなら何もしない。 */
  async loadPdfLibraries() {
    if (this._librariesLoaded) {
      return;
    }
    // 2つの静的リソースは互いに依存しないため並行して読み込む。
    await Promise.all([
      loadScript(this, JSPDF_RESOURCE),
      loadScript(this, NOTO_SANS_JP_RESOURCE)
    ]);
    this._librariesLoaded = true;
  }

  get pdfFileName() {
    const quoteNumber = textOrEmpty(this.quote.quoteNumber) || "無題";
    return `見積書_${quoteNumber}.pdf`;
  }

  // ------------------------------------------------------------------
  // PDF生成
  // ------------------------------------------------------------------

  /**
   * A4縦・日本語のPDFを組み立てる。
   * 描画は「ヘッダ → 明細テーブル → 集計/条件 → 備考・振込先 → ページ番号」の順。
   */
  buildPdfDocument() {
    const jspdfNamespace = window.jspdf;
    if (!jspdfNamespace || !jspdfNamespace.jsPDF) {
      throw new Error("jsPDFライブラリを読み込めませんでした。");
    }
    const { jsPDF } = jspdfNamespace;
    const doc = new jsPDF({
      orientation: "portrait",
      unit: "mm",
      format: "a4"
    });

    // 日本語を出力するには TTF を VFS に登録してフォントとして宣言する必要がある。
    // サブセットフォントは normal ウェイトのみのため、強調は太字ではなく文字サイズで表現する。
    doc.addFileToVFS(PDF_FONT_FILE, window.NotoSansJPNormal);
    doc.addFont(PDF_FONT_FILE, PDF_FONT_NAME, "normal");
    doc.setFont(PDF_FONT_NAME, "normal");

    let y = this.drawPdfHeader(doc);
    y = this.drawPdfTable(doc, y);
    y = this.drawPdfSummaryAndTerms(doc, y);
    this.drawPdfNotes(doc, y);
    this.drawPdfPageNumbers(doc);
    return doc;
  }

  /** 見出し・宛名・合計金額・発行元を描画し、明細テーブルの開始Y座標を返す。 */
  drawPdfHeader(doc) {
    const { marginX, pageWidth } = PDF_LAYOUT;
    const rightEdge = pageWidth - marginX;

    doc.setFontSize(20);
    doc.text("見積書", pageWidth / 2, 22, { align: "center" });
    doc.setLineWidth(0.4);
    doc.line(pageWidth / 2 - 18, 24.5, pageWidth / 2 + 18, 24.5);
    doc.setLineWidth(0.2);

    // 右上: 見積番号 / 見積日
    doc.setFontSize(10);
    doc.text(
      `見積番号: ${textOrEmpty(this.quote.quoteNumber)}`,
      rightEdge,
      32,
      { align: "right" }
    );
    doc.text(`見積日: ${this.quoteDateText}`, rightEdge, 37, {
      align: "right"
    });

    // 左: 宛名(下線付き) → 件名
    let leftY = 46;
    const customer = this.customerNameWithHonorific;
    if (customer) {
      doc.setFontSize(14);
      doc.text(customer, marginX, leftY);
      const width = doc.getTextWidth(customer);
      doc.line(marginX, leftY + 1.8, marginX + width + 4, leftY + 1.8);
      leftY += 9;
    }
    doc.setFontSize(11);
    doc.text(`件名: ${textOrEmpty(this.quote.subject)}`, marginX, leftY);
    leftY += 4;

    // 左: 合計金額(税込)を枠付きで強調
    const boxWidth = 92;
    const boxHeight = 14;
    doc.rect(marginX, leftY, boxWidth, boxHeight);
    doc.setFontSize(9);
    doc.text("合計金額(税込)", marginX + 3, leftY + 5);
    doc.setFontSize(16);
    doc.text(
      `${this.totalAmountText} 円`,
      marginX + boxWidth - 3,
      leftY + 11.5,
      { align: "right" }
    );
    leftY += boxHeight;

    // 右: 発行元情報
    const issuer = this.issuer;
    let rightY = 46;
    doc.setFontSize(11);
    doc.text(textOrEmpty(issuer.companyName), rightEdge, rightY, {
      align: "right"
    });
    rightY += 5;
    doc.setFontSize(8.5);
    const issuerLines = [];
    if (issuer.postalCode) {
      issuerLines.push(`〒${issuer.postalCode}`);
    }
    if (issuer.address) {
      issuerLines.push(textOrEmpty(issuer.address));
    }
    const contact = [
      issuer.phone ? `TEL: ${issuer.phone}` : "",
      issuer.fax ? `FAX: ${issuer.fax}` : ""
    ]
      .filter(Boolean)
      .join("  ");
    if (contact) {
      issuerLines.push(contact);
    }
    if (issuer.invoiceRegistrationNumber) {
      issuerLines.push(`登録番号: ${issuer.invoiceRegistrationNumber}`);
    }
    issuerLines.forEach((line) => {
      const wrapped = doc.splitTextToSize(line, 80);
      wrapped.forEach((part) => {
        doc.text(part, rightEdge, rightY, { align: "right" });
        rightY += 4.2;
      });
    });

    return Math.max(leftY, rightY) + 6;
  }

  /** 明細テーブルのヘッダ行を描画し、次の行のY座標を返す。 */
  drawPdfTableHeader(doc, y) {
    const height = 8;
    doc.setFontSize(9);

    // jsPDF の text() は描画時に塗り色を文字色(黒)へ書き換えるため、
    // 塗りつぶしとラベルを別ループに分ける。混在させると2セル目以降が黒く潰れる。
    doc.setFillColor(...TABLE_HEADER_FILL);
    let x = PDF_LAYOUT.marginX;
    TABLE_COLUMNS.forEach((column) => {
      // 'FD' = 塗りつぶし + 枠線
      doc.rect(x, y, column.width, height, "FD");
      x += column.width;
    });

    x = PDF_LAYOUT.marginX;
    TABLE_COLUMNS.forEach((column) => {
      this.drawPdfCellText(
        doc,
        column.label,
        x,
        y + 5.4,
        column.width,
        "center"
      );
      x += column.width;
    });
    return y + height;
  }

  /** セル内の水平位置を揃えてテキストを描画する。 */
  drawPdfCellText(doc, text, cellX, textY, cellWidth, align) {
    const padding = 1.6;
    if (align === "right") {
      doc.text(text, cellX + cellWidth - padding, textY, {
        align: "right"
      });
    } else if (align === "center") {
      doc.text(text, cellX + cellWidth / 2, textY, { align: "center" });
    } else {
      doc.text(text, cellX + padding, textY);
    }
  }

  /**
   * 明細テーブルを描画する。
   * 行の高さは折り返し行数から求め、ページ下端を超える場合は改ページして
   * 見出し行を再描画する(明細が何行でも表として読める状態を保つ)。
   */
  drawPdfTable(doc, startY) {
    const bottomLimit = PDF_LAYOUT.pageHeight - PDF_LAYOUT.marginBottom;
    let y = this.drawPdfTableHeader(doc, startY);
    doc.setFontSize(9);

    this.printableLines.forEach((line) => {
      const cells = TABLE_COLUMNS.map((column) => {
        const raw = textOrEmpty(line[column.key]);
        const usableWidth = column.width - 3.2;
        return raw ? doc.splitTextToSize(raw, usableWidth) : [""];
      });
      const maxLineCount = cells.reduce(
        (max, cell) => Math.max(max, cell.length),
        1
      );
      const rowHeight = Math.max(
        PDF_LAYOUT.tableRowMinHeight,
        maxLineCount * PDF_LAYOUT.textLineHeight + 3
      );

      if (y + rowHeight > bottomLimit) {
        doc.addPage();
        y = this.drawPdfTableHeader(doc, PDF_LAYOUT.marginTop);
        doc.setFontSize(9);
      }

      let x = PDF_LAYOUT.marginX;
      TABLE_COLUMNS.forEach((column, index) => {
        doc.rect(x, y, column.width, rowHeight);
        cells[index].forEach((text, lineIndex) => {
          this.drawPdfCellText(
            doc,
            text,
            x,
            y + 5 + lineIndex * PDF_LAYOUT.textLineHeight,
            column.width,
            column.align
          );
        });
        x += column.width;
      });
      y += rowHeight;
    });

    return y;
  }

  /** 集計欄(右)と取引条件(左)を同じ高さから描画し、下端のY座標を返す。 */
  drawPdfSummaryAndTerms(doc, startY) {
    const { marginX, pageWidth, summaryRowHeight, summaryBoxWidth } =
      PDF_LAYOUT;
    const summaryX = pageWidth - marginX - summaryBoxWidth;
    const termsLabelWidth = 26;
    const termsWidth = summaryX - marginX - 8 - termsLabelWidth;

    const summaryRows = this.buildPdfSummaryRows();
    doc.setFontSize(9);
    const termBlocks = this.buildPdfTerms().map((term) => ({
      label: term.label,
      lines: doc.splitTextToSize(term.value, termsWidth)
    }));

    const summaryHeight = summaryRows.length * summaryRowHeight;
    const termsHeight = termBlocks.reduce(
      (total, block) => total + Math.max(1, block.lines.length) * 5,
      0
    );

    let y = startY + 6;
    // 集計欄は分断すると読みにくいため、収まらない場合はブロックごと次ページへ送る。
    if (
      y + Math.max(summaryHeight, termsHeight) >
      PDF_LAYOUT.pageHeight - PDF_LAYOUT.marginBottom
    ) {
      doc.addPage();
      y = PDF_LAYOUT.marginTop;
    }

    let summaryY = y;
    summaryRows.forEach((row) => {
      doc.setFontSize(row.emphasis ? 12 : 10);
      doc.rect(summaryX, summaryY, summaryBoxWidth, summaryRowHeight);
      doc.text(row.label, summaryX + 2.5, summaryY + 5);
      doc.text(row.value, summaryX + summaryBoxWidth - 2.5, summaryY + 5, {
        align: "right"
      });
      summaryY += summaryRowHeight;
    });

    doc.setFontSize(9);
    let termsY = y + 4;
    termBlocks.forEach((block) => {
      doc.text(block.label, marginX, termsY);
      block.lines.forEach((line, index) => {
        doc.text(line, marginX + termsLabelWidth, termsY + index * 5);
      });
      termsY += Math.max(1, block.lines.length) * 5;
    });

    return Math.max(summaryY, termsY);
  }

  /** 集計欄の行データ。8%対象が無い見積では8%の行を出力しない。 */
  buildPdfSummaryRows() {
    const rows = [
      { label: "小計(税抜)", value: `${this.subtotalText} 円` },
      { label: "10%対象額", value: `${this.taxableBase10Text} 円` },
      { label: "消費税(10%)", value: `${this.taxAmount10Text} 円` }
    ];
    if (this.hasReducedTaxRate) {
      rows.push({
        label: "8%対象額",
        value: `${this.taxableBase8Text} 円`
      });
      rows.push({
        label: "消費税(8%)",
        value: `${this.taxAmount8Text} 円`
      });
    }
    rows.push({
      label: "合計金額(税込)",
      value: `${this.totalAmountText} 円`,
      emphasis: true
    });
    return rows;
  }

  /** 取引条件欄の行データ。未入力項目も枠を揃えるため空文字で出力する。 */
  buildPdfTerms() {
    return [
      { label: "納期", value: textOrEmpty(this.quote.deliveryDate) },
      { label: "納入場所", value: textOrEmpty(this.quote.deliveryPlace) },
      { label: "支払条件", value: textOrEmpty(this.quote.paymentTerms) },
      { label: "見積有効期限", value: this.expirationDateText }
    ];
  }

  /** 備考と振込先を全幅で描画する。ページ下端に達した場合は改ページする。 */
  drawPdfNotes(doc, startY) {
    const { marginX, contentWidth, textLineHeight } = PDF_LAYOUT;
    const bottomLimit = PDF_LAYOUT.pageHeight - PDF_LAYOUT.marginBottom;
    const blocks = [];
    if (this.quote.notes) {
      blocks.push({ label: "備考", value: textOrEmpty(this.quote.notes) });
    }
    if (this.issuer.bankAccount) {
      blocks.push({
        label: "お振込先",
        value: textOrEmpty(this.issuer.bankAccount)
      });
    }
    if (blocks.length === 0) {
      return;
    }

    doc.setFontSize(9);
    let y = startY + 8;
    blocks.forEach((block) => {
      const lines = doc.splitTextToSize(block.value, contentWidth - 4);
      const blockHeight = (lines.length + 1) * textLineHeight + 4;
      if (y + blockHeight > bottomLimit) {
        doc.addPage();
        y = PDF_LAYOUT.marginTop;
      }
      doc.text(`【${block.label}】`, marginX, y);
      y += textLineHeight + 1;
      lines.forEach((line) => {
        doc.text(line, marginX + 2, y);
        y += textLineHeight;
      });
      y += 3;
    });
  }

  /** 全ページ確定後に「n / m」形式のページ番号を追記する。 */
  drawPdfPageNumbers(doc) {
    const totalPages = doc.getNumberOfPages();
    doc.setFontSize(8);
    for (let page = 1; page <= totalPages; page += 1) {
      doc.setPage(page);
      doc.text(
        `${page} / ${totalPages}`,
        PDF_LAYOUT.pageWidth / 2,
        PDF_LAYOUT.pageHeight - 10,
        { align: "center" }
      );
    }
  }
}
