/**
 * QuotePdfController.getQuotePdfData(Id) のテスト。
 *
 * 設計書 doc/WI-000003/design.md §5 のテスト計画に対応する。
 * - 正常系: 明細3行(10%/8%/非課税)の返却内容と税率別集計
 * - 端数処理: 税率ごとに1回だけ切り捨てられること(明細ごとではないこと)
 * - 境界: 明細0件の見積
 * - 宛名: CustomerName__c の有無による customerName の切り替え
 * - 異常系: null / 別オブジェクトのId / 存在しない見積Id
 * - 権限: 参照権限のないユーザーからのアクセス
 *
 * 【実行ユーザーについて】
 * 見積・見積明細のカスタム項目の項目レベルセキュリティ(FLS)は QuoteManagement 権限セット
 * だけが付与する。システム管理者プロファイルには FLS が自動付与されないため、
 * 権限セット未割り当ての組織(本番組織や check-only 検証)ではデプロイユーザーのまま
 * DML/参照を行うと項目にアクセスできず失敗する。
 * そのため、テストデータの作成とコントローラの呼び出しは QuoteManagement 権限セットを
 * 割り当てた専用のテストユーザーとして System.runAs で実行する。
 */
@isTest
private class QuotePdfControllerTest {
  // ---------- 実行ユーザー ----------
  /** 見積のFLSを付与する権限セットのAPI参照名 */
  private static final String PERMISSION_SET_NAME = 'QuoteManagement';
  private static final String RUNNER_ALIAS = 'qpdfr';

  // ---------- テストデータ識別用 ----------
  private static final String ACCOUNT_NAME = 'テスト取引先株式会社';
  private static final String SUBJECT_STANDARD = 'テスト見積_明細3行';
  private static final String SUBJECT_NO_LINE = 'テスト見積_明細なし';
  private static final String SUBJECT_CUSTOM_NAME = 'テスト見積_宛名あり';
  private static final String SUBJECT_ROUNDING = 'テスト見積_端数処理';
  private static final String CUSTOM_ADDRESSEE = '宛名指定株式会社';

  private static final String HONORIFIC = '御中';
  private static final String STATUS_DRAFT = '作成中';
  private static final String DELIVERY_DATE = '別途協議';
  private static final String DELIVERY_PLACE = '東京都千代田区丸の内2-2-2';
  private static final String PAYMENT_TERMS = '月末締め翌月末払い';
  private static final String NOTES = '本見積書の有効期限は発行日より30日間です。';
  private static final Date QUOTE_DATE = Date.newInstance(2026, 4, 1);
  private static final Date EXPIRATION_DATE = Date.newInstance(2026, 5, 1);

  // Decimal項目との比較で型を揃えるための定数
  private static final Decimal ZERO = 0;
  private static final Decimal LINE_NO_1 = 1;
  private static final Decimal LINE_NO_2 = 2;
  private static final Decimal LINE_NO_3 = 3;

  private static final String TAX_RATE_10 = '10%';
  private static final String TAX_RATE_8 = '8%';
  private static final String TAX_RATE_FREE = '非課税';

  // ---------- 明細3行の入力値 ----------
  private static final String PRODUCT_LINE1 = '要件定義・基本設計';
  private static final String PRODUCT_LINE2 = '軽減税率対象品';
  private static final String PRODUCT_LINE3 = '印紙代';
  private static final String DESCRIPTION_LINE1 = '設計書一式の作成を含む';
  private static final Decimal QTY_LINE1 = 3;
  private static final Decimal QTY_LINE2 = 2;
  private static final Decimal QTY_LINE3 = 1;
  // 10%対象に端数(x.3)が出る単価をあえて選ぶ
  private static final Decimal PRICE_LINE1 = 1111;
  private static final Decimal PRICE_LINE2 = 1234;
  private static final Decimal PRICE_LINE3 = 5000;

  // ---------- 明細3行から導出した期待値 ----------
  private static final Decimal EXPECTED_AMOUNT_LINE1 = QTY_LINE1 * PRICE_LINE1; // 3,333
  private static final Decimal EXPECTED_AMOUNT_LINE2 = QTY_LINE2 * PRICE_LINE2; // 2,468
  private static final Decimal EXPECTED_AMOUNT_LINE3 = QTY_LINE3 * PRICE_LINE3; // 5,000
  private static final Decimal EXPECTED_SUBTOTAL =
    EXPECTED_AMOUNT_LINE1 +
    EXPECTED_AMOUNT_LINE2 +
    EXPECTED_AMOUNT_LINE3; // 10,801
  private static final Decimal EXPECTED_BASE_10 = EXPECTED_AMOUNT_LINE1; // 3,333
  private static final Decimal EXPECTED_BASE_8 = EXPECTED_AMOUNT_LINE2; // 2,468
  // FLOOR(3,333 * 0.1) = FLOOR(333.3) = 333
  private static final Decimal EXPECTED_TAX_10 = (EXPECTED_BASE_10 * 0.1)
    .round(System.RoundingMode.FLOOR);
  // FLOOR(2,468 * 0.08) = FLOOR(197.44) = 197
  private static final Decimal EXPECTED_TAX_8 = (EXPECTED_BASE_8 * 0.08)
    .round(System.RoundingMode.FLOOR);
  private static final Decimal EXPECTED_TAX_TOTAL =
    EXPECTED_TAX_10 + EXPECTED_TAX_8; // 530
  private static final Decimal EXPECTED_TOTAL =
    EXPECTED_SUBTOTAL + EXPECTED_TAX_TOTAL; // 11,331
  // 明細の表示用消費税額(明細ごとの切り捨て)
  private static final Decimal EXPECTED_LINE1_TAX = (EXPECTED_AMOUNT_LINE1 *
    0.1)
    .round(System.RoundingMode.FLOOR);
  private static final Decimal EXPECTED_LINE2_TAX = (EXPECTED_AMOUNT_LINE2 *
    0.08)
    .round(System.RoundingMode.FLOOR);

  // ---------- 端数処理検証用(10%明細2行)の入力値と期待値 ----------
  // 明細ごとに切り捨てると 110 + 210 = 320、税率ごとに集計してから切り捨てると 321 となる組合せ。
  private static final Decimal ROUNDING_PRICE_A = 1105;
  private static final Decimal ROUNDING_PRICE_B = 2105;
  private static final Decimal EXPECTED_ROUNDING_BASE_10 =
    ROUNDING_PRICE_A + ROUNDING_PRICE_B; // 3,210
  private static final Decimal EXPECTED_ROUNDING_TAX_10 = (EXPECTED_ROUNDING_BASE_10 *
    0.1)
    .round(System.RoundingMode.FLOOR); // 321
  private static final Decimal EXPECTED_ROUNDING_LINE_A_TAX = (ROUNDING_PRICE_A *
    0.1)
    .round(System.RoundingMode.FLOOR); // 110
  private static final Decimal EXPECTED_ROUNDING_LINE_B_TAX = (ROUNDING_PRICE_B *
    0.1)
    .round(System.RoundingMode.FLOOR); // 210
  private static final Decimal WRONG_PER_LINE_TAX_SUM =
    EXPECTED_ROUNDING_LINE_A_TAX + EXPECTED_ROUNDING_LINE_B_TAX; // 320

  @TestSetup
  static void setupTestData() {
    // 権限セットを割り当てたテストユーザーを先に作成する(設定オブジェクトのDMLを分離するため)
    User runner = createRunnerUser();

    Account account = buildAccount();
    insert account;

    Contact contact = buildContact(account.Id);
    insert contact;

    // 見積・見積明細のFLSは権限セット経由でしか付与されないため、テストユーザーとして作成する
    System.runAs(runner) {
      List<Quote__c> quotes = new List<Quote__c>{
        buildQuote(account.Id, contact.Id, SUBJECT_STANDARD, null),
        buildQuote(account.Id, null, SUBJECT_NO_LINE, null),
        buildQuote(account.Id, null, SUBJECT_CUSTOM_NAME, CUSTOM_ADDRESSEE),
        buildQuote(account.Id, null, SUBJECT_ROUNDING, null)
      };
      insert quotes;

      List<QuoteLineItem__c> lines = new List<QuoteLineItem__c>();
      lines.addAll(buildStandardLines(quotes[0].Id));
      lines.addAll(buildRoundingLines(quotes[3].Id));
      insert lines;
    }
  }

  /**
   * 正常系: 明細3行(10%/8%/非課税)の見積で、ヘッダ項目と明細の各項目が
   * 行番号順に正しく返ること。
   */
  @isTest
  static void shouldReturnHeaderAndLines_WhenQuoteHasThreeLineItems() {
    // Given
    User runner = runnerUser();

    // When
    QuotePdfController.QuotePdfData data;
    // 取引先責任者名の姓名の並びは実行ユーザーのロケールで変わるため、
    // 期待値も同じユーザーコンテキストで取得する
    Contact expectedContact;
    Test.startTest();
    System.runAs(runner) {
      expectedContact = [SELECT Name FROM Contact LIMIT 1];
      data = QuotePdfController.getQuotePdfData(
        quoteIdBySubject(SUBJECT_STANDARD)
      );
    }
    Test.stopTest();

    // Then: ヘッダ
    Assert.isNotNull(data, '見積データが返ること');
    Assert.isNotNull(data.quote, '見積ヘッダが返ること');
    Assert.isTrue(
      String.isNotBlank(data.quote.quoteNumber),
      '見積番号(自動採番)が設定されていること'
    );
    Assert.areEqual(SUBJECT_STANDARD, data.quote.subject, '件名が一致すること');
    Assert.areEqual(QUOTE_DATE, data.quote.quoteDate, '見積日が一致すること');
    Assert.areEqual(
      EXPIRATION_DATE,
      data.quote.expirationDate,
      '見積有効期限が一致すること'
    );
    Assert.areEqual(
      STATUS_DRAFT,
      data.quote.status,
      'ステータスが一致すること'
    );
    Assert.areEqual(HONORIFIC, data.quote.honorific, '敬称が一致すること');
    Assert.areEqual(
      expectedContact.Name,
      data.quote.contactName,
      '先方担当者名が一致すること'
    );
    Assert.areEqual(
      DELIVERY_DATE,
      data.quote.deliveryDate,
      '納期が一致すること'
    );
    Assert.areEqual(
      DELIVERY_PLACE,
      data.quote.deliveryPlace,
      '納入場所が一致すること'
    );
    Assert.areEqual(
      PAYMENT_TERMS,
      data.quote.paymentTerms,
      '支払条件が一致すること'
    );
    Assert.areEqual(NOTES, data.quote.notes, '備考が一致すること');
    Assert.isNotNull(data.issuer, '発行元情報のインスタンスが必ず返ること');

    // Then: 明細(LineNumber__c 昇順で返る)
    Assert.areEqual(3, data.lines.size(), '明細が3件返ること');

    QuotePdfController.QuoteLine line1 = data.lines[0];
    Assert.areEqual(LINE_NO_1, line1.lineNumber, '1件目は行番号1であること');
    Assert.areEqual(
      PRODUCT_LINE1,
      line1.productName,
      '1件目の品名が一致すること'
    );
    Assert.areEqual(
      DESCRIPTION_LINE1,
      line1.description,
      '1件目の摘要が一致すること'
    );
    Assert.areEqual(QTY_LINE1, line1.quantity, '1件目の数量が一致すること');
    Assert.areEqual('人月', line1.unit, '1件目の単位が一致すること');
    Assert.areEqual(PRICE_LINE1, line1.unitPrice, '1件目の単価が一致すること');
    Assert.areEqual(
      EXPECTED_AMOUNT_LINE1,
      line1.amount,
      '1件目の金額は数量x単価であること'
    );
    Assert.areEqual(TAX_RATE_10, line1.taxRate, '1件目の税率が10%であること');
    Assert.areEqual(
      EXPECTED_LINE1_TAX,
      line1.taxAmount,
      '1件目の表示用消費税額が一致すること'
    );
    Assert.isNotNull(line1.recordId, '1件目のレコードIdが返ること');

    QuotePdfController.QuoteLine line2 = data.lines[1];
    Assert.areEqual(LINE_NO_2, line2.lineNumber, '2件目は行番号2であること');
    Assert.areEqual(
      PRODUCT_LINE2,
      line2.productName,
      '2件目の品名が一致すること'
    );
    Assert.areEqual(
      EXPECTED_AMOUNT_LINE2,
      line2.amount,
      '2件目の金額が一致すること'
    );
    Assert.areEqual(TAX_RATE_8, line2.taxRate, '2件目の税率が8%であること');
    Assert.areEqual(
      EXPECTED_LINE2_TAX,
      line2.taxAmount,
      '2件目の表示用消費税額が一致すること'
    );

    QuotePdfController.QuoteLine line3 = data.lines[2];
    Assert.areEqual(LINE_NO_3, line3.lineNumber, '3件目は行番号3であること');
    Assert.areEqual(
      PRODUCT_LINE3,
      line3.productName,
      '3件目の品名が一致すること'
    );
    Assert.areEqual(
      EXPECTED_AMOUNT_LINE3,
      line3.amount,
      '3件目の金額が一致すること'
    );
    Assert.areEqual(
      TAX_RATE_FREE,
      line3.taxRate,
      '3件目の税率が非課税であること'
    );
    Assert.areEqual(
      ZERO,
      line3.taxAmount,
      '非課税の明細の消費税額は0であること'
    );
  }

  /**
   * 正常系: 税率別の積み上げ集計(小計/10%対象額/8%対象額/消費税/合計)が
   * 期待値どおりに返ること。非課税分は課税対象額に含まれないことも確認する。
   */
  @isTest
  static void shouldReturnRateBasedTotals_WhenLineItemsHaveMixedTaxRates() {
    // Given
    User runner = runnerUser();

    // When
    QuotePdfController.QuotePdfData data;
    Test.startTest();
    System.runAs(runner) {
      data = QuotePdfController.getQuotePdfData(
        quoteIdBySubject(SUBJECT_STANDARD)
      );
    }
    Test.stopTest();

    // Then
    QuotePdfController.QuoteHeader header = data.quote;
    Assert.areEqual(
      EXPECTED_SUBTOTAL,
      header.subtotal,
      '小計は全明細の金額合計であること'
    );
    Assert.areEqual(
      EXPECTED_BASE_10,
      header.taxableBase10,
      '10%対象額は10%明細の金額合計であること'
    );
    Assert.areEqual(
      EXPECTED_BASE_8,
      header.taxableBase8,
      '8%対象額は8%明細の金額合計であること'
    );
    Assert.areEqual(
      EXPECTED_TAX_10,
      header.taxAmount10,
      '消費税(10%)は10%対象額を切り捨てた値であること'
    );
    Assert.areEqual(
      EXPECTED_TAX_8,
      header.taxAmount8,
      '消費税(8%)は8%対象額を切り捨てた値であること'
    );
    Assert.areEqual(
      EXPECTED_TAX_TOTAL,
      header.taxAmount,
      '消費税額合計は税率別消費税の合計であること'
    );
    Assert.areEqual(
      EXPECTED_TOTAL,
      header.totalAmount,
      '合計金額は小計+消費税額合計であること'
    );
    // 非課税の5,000円は小計に含まれるが、どちらの課税対象額にも含まれない
    Assert.areEqual(
      EXPECTED_AMOUNT_LINE3,
      header.subtotal - header.taxableBase10 - header.taxableBase8,
      '小計から課税対象額を差し引いた残りが非課税明細の金額と一致すること'
    );
  }

  /**
   * 端数処理: インボイス制度に合わせ「税率ごとに1回」切り捨てられること。
   * 10%明細2行(1,105円/2,105円)で、明細ごとに切り捨てた合計(320円)ではなく
   * 税率別に集計してから切り捨てた値(321円)が返ることを検証する。
   */
  @isTest
  static void shouldRoundTaxOncePerRate_WhenMultipleLineItemsShareSameRate() {
    // Given
    User runner = runnerUser();

    // When
    QuotePdfController.QuotePdfData data;
    Test.startTest();
    System.runAs(runner) {
      data = QuotePdfController.getQuotePdfData(
        quoteIdBySubject(SUBJECT_ROUNDING)
      );
    }
    Test.stopTest();

    // Then
    QuotePdfController.QuoteHeader header = data.quote;
    Assert.areEqual(2, data.lines.size(), '10%の明細が2件返ること');
    Assert.areEqual(
      EXPECTED_ROUNDING_BASE_10,
      header.taxableBase10,
      '10%対象額が2行分の合計であること'
    );
    Assert.areEqual(
      EXPECTED_ROUNDING_TAX_10,
      header.taxAmount10,
      '税率ごとに1回だけ切り捨てた消費税額(321円)であること'
    );
    Assert.areNotEqual(
      WRONG_PER_LINE_TAX_SUM,
      header.taxAmount10,
      '明細ごとに切り捨てた合計(320円)にはならないこと'
    );
    // 明細側の消費税額は「表示用」なので明細ごとの切り捨て値になる
    Assert.areEqual(
      EXPECTED_ROUNDING_LINE_A_TAX,
      data.lines[0].taxAmount,
      '明細1の表示用消費税額は明細単位の切り捨て値であること'
    );
    Assert.areEqual(
      EXPECTED_ROUNDING_LINE_B_TAX,
      data.lines[1].taxAmount,
      '明細2の表示用消費税額は明細単位の切り捨て値であること'
    );
    Assert.areEqual(
      WRONG_PER_LINE_TAX_SUM,
      data.lines[0].taxAmount + data.lines[1].taxAmount,
      '明細の表示用消費税額の単純合計は集計値と一致しないこと(端数処理の差分)'
    );
  }

  /**
   * 境界値: 明細が0件の見積でも例外にならず、空の明細リストと0の集計値が返ること。
   */
  @isTest
  static void shouldReturnEmptyLines_WhenQuoteHasNoLineItem() {
    // Given
    User runner = runnerUser();

    // When
    QuotePdfController.QuotePdfData data;
    Test.startTest();
    System.runAs(runner) {
      data = QuotePdfController.getQuotePdfData(
        quoteIdBySubject(SUBJECT_NO_LINE)
      );
    }
    Test.stopTest();

    // Then
    Assert.isNotNull(data.lines, '明細リストはnullではなく空リストで返ること');
    Assert.areEqual(0, data.lines.size(), '明細が0件であること');
    Assert.areEqual(ZERO, data.quote.subtotal, '小計が0であること');
    Assert.areEqual(ZERO, data.quote.taxableBase10, '10%対象額が0であること');
    Assert.areEqual(ZERO, data.quote.taxableBase8, '8%対象額が0であること');
    Assert.areEqual(ZERO, data.quote.taxAmount10, '消費税(10%)が0であること');
    Assert.areEqual(ZERO, data.quote.taxAmount8, '消費税(8%)が0であること');
    Assert.areEqual(ZERO, data.quote.taxAmount, '消費税額合計が0であること');
    Assert.areEqual(ZERO, data.quote.totalAmount, '合計金額が0であること');
    // 先方担当者未設定の見積では担当者名がnullになる
    Assert.isNull(
      data.quote.contactName,
      '先方担当者が未設定なら担当者名はnullであること'
    );
  }

  /**
   * 宛名: CustomerName__c が空欄の場合は取引先名が customerName に入ること。
   */
  @isTest
  static void shouldUseAccountName_WhenCustomerNameIsBlank() {
    // Given
    User runner = runnerUser();

    // When
    QuotePdfController.QuotePdfData data;
    Test.startTest();
    System.runAs(runner) {
      data = QuotePdfController.getQuotePdfData(
        quoteIdBySubject(SUBJECT_STANDARD)
      );
    }
    Test.stopTest();

    // Then
    Assert.areEqual(
      ACCOUNT_NAME,
      data.quote.customerName,
      '宛名が空欄なら取引先名が使われること'
    );
  }

  /**
   * 宛名: CustomerName__c が入力されている場合はその値が取引先名より優先されること。
   */
  @isTest
  static void shouldUseCustomerName_WhenCustomerNameIsFilled() {
    // Given
    User runner = runnerUser();

    // When
    QuotePdfController.QuotePdfData data;
    Test.startTest();
    System.runAs(runner) {
      data = QuotePdfController.getQuotePdfData(
        quoteIdBySubject(SUBJECT_CUSTOM_NAME)
      );
    }
    Test.stopTest();

    // Then
    Assert.areEqual(
      CUSTOM_ADDRESSEE,
      data.quote.customerName,
      '宛名が入力されていればその値が優先されること'
    );
    Assert.areNotEqual(
      ACCOUNT_NAME,
      data.quote.customerName,
      '取引先名で上書きされないこと'
    );
  }

  /**
   * 異常系: null を渡した場合に AuraHandledException が発生すること。
   */
  @isTest
  static void shouldThrowAuraHandledException_WhenQuoteIdIsNull() {
    // When / Then
    Test.startTest();
    try {
      QuotePdfController.getQuotePdfData(null);
      Assert.fail('null を渡した場合は AuraHandledException が発生するはず');
    } catch (AuraHandledException e) {
      Assert.areEqual(
        QuotePdfController.MSG_INVALID_ID,
        e.getMessage(),
        'Id未指定を示すメッセージが返ること'
      );
    }
    Test.stopTest();
  }

  /**
   * 異常系: 見積以外のオブジェクト(取引先)のIdを渡した場合に AuraHandledException が発生すること。
   */
  @isTest
  static void shouldThrowAuraHandledException_WhenIdIsNotQuote() {
    // Given
    Account account = [SELECT Id FROM Account LIMIT 1];

    // When / Then
    Test.startTest();
    try {
      QuotePdfController.getQuotePdfData(account.Id);
      Assert.fail(
        '見積以外のIdを渡した場合は AuraHandledException が発生するはず'
      );
    } catch (AuraHandledException e) {
      Assert.areEqual(
        QuotePdfController.MSG_INVALID_ID,
        e.getMessage(),
        'Id不正を示すメッセージが返ること'
      );
    }
    Test.stopTest();
  }

  /**
   * 異常系: 存在しない見積Idを渡した場合に「見つからない」旨の AuraHandledException が発生すること。
   */
  @isTest
  static void shouldThrowAuraHandledException_WhenQuoteDoesNotExist() {
    // Given: 見積オブジェクトのキープレフィックスから、存在しないIdを組み立てる
    // 子リレーションまで先読みしないよう DEFERRED を指定する
    Id missingQuoteId = Id.valueOf(
      Quote__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
        .getKeyPrefix() + '000000000AAA'
    );
    User runner = runnerUser();

    // When / Then: 権限のあるユーザーで実行し、権限不足ではなく「該当なし」で失敗することを確かめる
    Test.startTest();
    System.runAs(runner) {
      try {
        QuotePdfController.getQuotePdfData(missingQuoteId);
        Assert.fail('存在しない見積Idでは AuraHandledException が発生するはず');
      } catch (AuraHandledException e) {
        Assert.areEqual(
          QuotePdfController.MSG_NOT_FOUND,
          e.getMessage(),
          '見積が見つからない旨のメッセージが返ること'
        );
      }
    }
    Test.stopTest();
  }

  /**
   * 権限: 見積オブジェクトへの参照権限を持たないユーザーからのアクセスでは
   * WITH USER_MODE により取得できず AuraHandledException となること。
   * (メッセージは実行環境の権限構成により NOT_FOUND 系のいずれかになりうるため厳密一致は求めない)
   */
  @isTest
  static void shouldThrowAuraHandledException_WhenUserHasNoAccess() {
    // Given
    User runner = runnerUser();
    Id quoteId;
    System.runAs(runner) {
      quoteId = quoteIdBySubject(SUBJECT_STANDARD);
    }
    // プロファイル名は組織の言語設定で変わるため、名前ではなく権限で特定する
    Profile restrictedProfile = [
      SELECT Id
      FROM Profile
      WHERE PermissionsModifyAllData = FALSE AND UserType = 'Standard'
      LIMIT 1
    ];
    User restrictedUser = buildUser(
      restrictedProfile.Id,
      uniqueUsername('quotepdf.restricted'),
      'qpdft'
    );
    insert restrictedUser;

    // When / Then
    Test.startTest();
    System.runAs(restrictedUser) {
      try {
        QuotePdfController.getQuotePdfData(quoteId);
        Assert.fail(
          '権限のないユーザーでは AuraHandledException が発生するはず'
        );
      } catch (AuraHandledException e) {
        Assert.isTrue(
          String.isNotBlank(e.getMessage()),
          '利用者向けのエラーメッセージが設定されていること'
        );
      }
    }
    Test.stopTest();
  }

  // ===================== ヘルパー =====================

  /**
   * QuoteManagement 権限セットを割り当てたテスト実行用ユーザーを作成する。
   *
   * プロファイル名は組織の言語設定で変わるため、名前ではなく権限で特定する。
   * User / PermissionSetAssignment は設定オブジェクトのため、通常オブジェクトとの
   * 混在DML(MIXED_DML_OPERATION)にならないよう現在ユーザーの runAs 内で登録する。
   */
  private static User createRunnerUser() {
    Profile adminProfile = [
      SELECT Id
      FROM Profile
      WHERE PermissionsModifyAllData = TRUE AND UserType = 'Standard'
      LIMIT 1
    ];
    List<PermissionSet> permissionSets = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :PERMISSION_SET_NAME
      LIMIT 1
    ];
    Assert.isFalse(
      permissionSets.isEmpty(),
      PERMISSION_SET_NAME + ' 権限セットが組織に存在すること'
    );

    User runner = buildUser(adminProfile.Id, runnerUsername(), RUNNER_ALIAS);
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert runner;
      insert new PermissionSetAssignment(
        AssigneeId = runner.Id,
        PermissionSetId = permissionSets[0].Id
      );
    }
    return runner;
  }

  /** @TestSetup で作成したテスト実行用ユーザーを取得する。 */
  private static User runnerUser() {
    return [SELECT Id FROM User WHERE Username = :runnerUsername() LIMIT 1];
  }

  /**
   * テスト実行用ユーザーのユーザー名。
   * ユーザー名はSalesforce全体で一意である必要があるため組織Idを含める。
   */
  private static String runnerUsername() {
    return 'quotepdf.runner.' +
      UserInfo.getOrganizationId().toLowerCase() +
      '@example.com.invalid';
  }

  /** 他組織と衝突しない使い捨てのユーザー名を組み立てる。 */
  private static String uniqueUsername(String prefix) {
    return prefix +
      '.' +
      String.valueOf(DateTime.now().getTime()) +
      String.valueOf(Math.abs(Crypto.getRandomInteger())) +
      '@example.com.invalid';
  }

  /** 件名からテスト用見積のIdを取得する。 */
  private static Id quoteIdBySubject(String subject) {
    return [SELECT Id FROM Quote__c WHERE Subject__c = :subject LIMIT 1].Id;
  }

  private static Account buildAccount() {
    return new Account(Name = ACCOUNT_NAME);
  }

  private static Contact buildContact(Id accountId) {
    return new Contact(
      AccountId = accountId,
      LastName = '見積',
      FirstName = '太郎'
    );
  }

  private static Quote__c buildQuote(
    Id accountId,
    Id contactId,
    String subject,
    String customerName
  ) {
    return new Quote__c(
      Account__c = accountId,
      Contact__c = contactId,
      Subject__c = subject,
      CustomerName__c = customerName,
      CustomerHonorific__c = HONORIFIC,
      QuoteDate__c = QUOTE_DATE,
      ExpirationDate__c = EXPIRATION_DATE,
      Status__c = STATUS_DRAFT,
      DeliveryDate__c = DELIVERY_DATE,
      DeliveryPlace__c = DELIVERY_PLACE,
      PaymentTerms__c = PAYMENT_TERMS,
      Notes__c = NOTES
    );
  }

  /**
   * 10% / 8% / 非課税 の3行。
   * ORDER BY LineNumber__c が効いていることを検証するため、行番号順とは異なる順序で作成する。
   */
  private static List<QuoteLineItem__c> buildStandardLines(Id quoteId) {
    return new List<QuoteLineItem__c>{
      new QuoteLineItem__c(
        Quote__c = quoteId,
        LineNumber__c = 3,
        ProductName__c = PRODUCT_LINE3,
        Unit__c = '式',
        Quantity__c = QTY_LINE3,
        UnitPrice__c = PRICE_LINE3,
        TaxRate__c = TAX_RATE_FREE
      ),
      new QuoteLineItem__c(
        Quote__c = quoteId,
        LineNumber__c = 1,
        ProductName__c = PRODUCT_LINE1,
        Description__c = DESCRIPTION_LINE1,
        Unit__c = '人月',
        Quantity__c = QTY_LINE1,
        UnitPrice__c = PRICE_LINE1,
        TaxRate__c = TAX_RATE_10
      ),
      new QuoteLineItem__c(
        Quote__c = quoteId,
        LineNumber__c = 2,
        ProductName__c = PRODUCT_LINE2,
        Unit__c = '個',
        Quantity__c = QTY_LINE2,
        UnitPrice__c = PRICE_LINE2,
        TaxRate__c = TAX_RATE_8
      )
    };
  }

  /** 端数処理検証用の10%明細2行。 */
  private static List<QuoteLineItem__c> buildRoundingLines(Id quoteId) {
    return new List<QuoteLineItem__c>{
      new QuoteLineItem__c(
        Quote__c = quoteId,
        LineNumber__c = 1,
        ProductName__c = '端数検証A',
        Unit__c = '個',
        Quantity__c = 1,
        UnitPrice__c = ROUNDING_PRICE_A,
        TaxRate__c = TAX_RATE_10
      ),
      new QuoteLineItem__c(
        Quote__c = quoteId,
        LineNumber__c = 2,
        ProductName__c = '端数検証B',
        Unit__c = '個',
        Quantity__c = 1,
        UnitPrice__c = ROUNDING_PRICE_B,
        TaxRate__c = TAX_RATE_10
      )
    };
  }

  /** テストユーザーを組み立てる。 */
  private static User buildUser(Id profileId, String username, String alias) {
    return new User(
      ProfileId = profileId,
      LastName = 'テスト',
      Email = 'quotepdf.test@example.com',
      Username = username,
      Alias = alias,
      TimeZoneSidKey = 'Asia/Tokyo',
      LocaleSidKey = 'ja_JP',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
  }
}
