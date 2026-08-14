/**
 * 見積書PDF出力LWC(quotePdfGenerator)向けに、見積・見積明細・発行元情報を1回で返す。
 *
 * 実行ユーザーの権限を尊重するため、見積と明細の取得は WITH USER_MODE で行う。
 * 発行元情報はカスタムメタデータ型のため全ユーザーが参照でき、USER_MODE の対象外。
 */
public with sharing class QuotePdfController {
  @TestVisible
  private static final String MSG_INVALID_ID = '見積のレコードIDを指定してください。';
  @TestVisible
  private static final String MSG_NOT_FOUND = '見積が見つからないか、参照する権限がありません。';

  /**
   * 見積書の印字に必要なデータ一式を返す。
   *
   * @param quoteId 対象の見積(Quote__c)レコードID
   * @return 見積ヘッダ・明細・発行元情報
   */
  @AuraEnabled(cacheable=true)
  public static QuotePdfData getQuotePdfData(Id quoteId) {
    if (quoteId == null || quoteId.getSobjectType() != Quote__c.SObjectType) {
      throw newException(MSG_INVALID_ID);
    }

    List<Quote__c> quotes;
    List<QuoteLineItem__c> lineItems;
    try {
      quotes = [
        SELECT
          Id,
          Name,
          Subject__c,
          QuoteDate__c,
          ExpirationDate__c,
          Status__c,
          CustomerName__c,
          CustomerHonorific__c,
          DeliveryDate__c,
          DeliveryPlace__c,
          PaymentTerms__c,
          Notes__c,
          Subtotal__c,
          TaxableBase10__c,
          TaxableBase8__c,
          TaxAmount10__c,
          TaxAmount8__c,
          TaxAmount__c,
          TotalAmount__c,
          Account__r.Name,
          Contact__r.Name
        FROM Quote__c
        WHERE Id = :quoteId
        WITH USER_MODE
        LIMIT 1
      ];
      lineItems = [
        SELECT
          Id,
          LineNumber__c,
          ProductName__c,
          Description__c,
          Quantity__c,
          Unit__c,
          UnitPrice__c,
          Amount__c,
          TaxRate__c,
          TaxAmount__c
        FROM QuoteLineItem__c
        WHERE Quote__c = :quoteId
        WITH USER_MODE
        ORDER BY LineNumber__c NULLS LAST, Name
      ];
    } catch (System.QueryException e) {
      // WITH USER_MODE はオブジェクト・項目の権限不足時に QueryException を投げる。
      // 内部メッセージをそのまま返さず、利用者向けの文言に置き換える。
      throw newException(MSG_NOT_FOUND);
    }

    if (quotes.isEmpty()) {
      throw newException(MSG_NOT_FOUND);
    }

    QuotePdfData data = new QuotePdfData();
    data.quote = new QuoteHeader(quotes[0]);
    data.lines = new List<QuoteLine>();
    for (QuoteLineItem__c item : lineItems) {
      data.lines.add(new QuoteLine(item));
    }
    data.issuer = loadIssuer();
    return data;
  }

  /** 既定の発行元情報を返す。未設定でも画面が壊れないよう空のインスタンスを返す。 */
  private static IssuerInfo loadIssuer() {
    List<QuoteIssuer__mdt> issuers = [
      SELECT
        CompanyName__c,
        PostalCode__c,
        Address__c,
        Phone__c,
        Fax__c,
        InvoiceRegistrationNumber__c,
        BankAccount__c
      FROM QuoteIssuer__mdt
      WHERE IsDefault__c = TRUE
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return issuers.isEmpty() ? new IssuerInfo() : new IssuerInfo(issuers[0]);
  }

  private static AuraHandledException newException(String message) {
    AuraHandledException e = new AuraHandledException(message);
    // 既定では 'Script-thrown exception' となるため、明示的にメッセージを設定する
    e.setMessage(message);
    return e;
  }

  public class QuotePdfData {
    @AuraEnabled
    public QuoteHeader quote;
    @AuraEnabled
    public List<QuoteLine> lines;
    @AuraEnabled
    public IssuerInfo issuer;
  }

  public class QuoteHeader {
    @AuraEnabled
    public String quoteNumber;
    @AuraEnabled
    public String subject;
    @AuraEnabled
    public Date quoteDate;
    @AuraEnabled
    public Date expirationDate;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String customerName;
    @AuraEnabled
    public String honorific;
    @AuraEnabled
    public String contactName;
    @AuraEnabled
    public String deliveryDate;
    @AuraEnabled
    public String deliveryPlace;
    @AuraEnabled
    public String paymentTerms;
    @AuraEnabled
    public String notes;
    @AuraEnabled
    public Decimal subtotal;
    @AuraEnabled
    public Decimal taxableBase10;
    @AuraEnabled
    public Decimal taxableBase8;
    @AuraEnabled
    public Decimal taxAmount10;
    @AuraEnabled
    public Decimal taxAmount8;
    @AuraEnabled
    public Decimal taxAmount;
    @AuraEnabled
    public Decimal totalAmount;

    public QuoteHeader(Quote__c record) {
      this.quoteNumber = record.Name;
      this.subject = record.Subject__c;
      this.quoteDate = record.QuoteDate__c;
      this.expirationDate = record.ExpirationDate__c;
      this.status = record.Status__c;
      // 宛名が未入力なら取引先名を使う
      this.customerName = String.isNotBlank(record.CustomerName__c)
        ? record.CustomerName__c
        : (record.Account__r == null ? null : record.Account__r.Name);
      this.honorific = record.CustomerHonorific__c;
      this.contactName = record.Contact__r == null
        ? null
        : record.Contact__r.Name;
      this.deliveryDate = record.DeliveryDate__c;
      this.deliveryPlace = record.DeliveryPlace__c;
      this.paymentTerms = record.PaymentTerms__c;
      this.notes = record.Notes__c;
      this.subtotal = zeroIfNull(record.Subtotal__c);
      this.taxableBase10 = zeroIfNull(record.TaxableBase10__c);
      this.taxableBase8 = zeroIfNull(record.TaxableBase8__c);
      this.taxAmount10 = zeroIfNull(record.TaxAmount10__c);
      this.taxAmount8 = zeroIfNull(record.TaxAmount8__c);
      this.taxAmount = zeroIfNull(record.TaxAmount__c);
      this.totalAmount = zeroIfNull(record.TotalAmount__c);
    }
  }

  public class QuoteLine {
    @AuraEnabled
    public Id recordId;
    @AuraEnabled
    public Decimal lineNumber;
    @AuraEnabled
    public String productName;
    @AuraEnabled
    public String description;
    @AuraEnabled
    public Decimal quantity;
    @AuraEnabled
    public String unit;
    @AuraEnabled
    public Decimal unitPrice;
    @AuraEnabled
    public Decimal amount;
    @AuraEnabled
    public String taxRate;
    @AuraEnabled
    public Decimal taxAmount;

    public QuoteLine(QuoteLineItem__c record) {
      this.recordId = record.Id;
      this.lineNumber = record.LineNumber__c;
      this.productName = record.ProductName__c;
      this.description = record.Description__c;
      this.quantity = zeroIfNull(record.Quantity__c);
      this.unit = record.Unit__c;
      this.unitPrice = zeroIfNull(record.UnitPrice__c);
      this.amount = zeroIfNull(record.Amount__c);
      this.taxRate = record.TaxRate__c;
      this.taxAmount = zeroIfNull(record.TaxAmount__c);
    }
  }

  public class IssuerInfo {
    @AuraEnabled
    public String companyName;
    @AuraEnabled
    public String postalCode;
    @AuraEnabled
    public String address;
    @AuraEnabled
    public String phone;
    @AuraEnabled
    public String fax;
    @AuraEnabled
    public String invoiceRegistrationNumber;
    @AuraEnabled
    public String bankAccount;

    public IssuerInfo() {
    }

    public IssuerInfo(QuoteIssuer__mdt setting) {
      this.companyName = setting.CompanyName__c;
      this.postalCode = setting.PostalCode__c;
      this.address = setting.Address__c;
      this.phone = setting.Phone__c;
      this.fax = setting.Fax__c;
      this.invoiceRegistrationNumber = setting.InvoiceRegistrationNumber__c;
      this.bankAccount = setting.BankAccount__c;
    }
  }

  private static Decimal zeroIfNull(Decimal value) {
    return value == null ? 0 : value;
  }
}
