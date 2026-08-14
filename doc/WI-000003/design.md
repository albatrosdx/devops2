# WI-000003 設計書 — 見積・見積明細オブジェクトと見積書PDF出力LWC

| 項目                      | 内容                                                   |
| ------------------------- | ------------------------------------------------------ |
| 作業項目                  | WI-000003                                              |
| 件名                      | 見積・見積明細オブジェクトと見積書PDF出力LWCの作成     |
| ブランチ                  | `WI-000003`                                            |
| DevOps Centerプロジェクト | Devops2 (`1QggL0000001F9tSAE`)                         |
| 開発組織                  | `devops2_scr` (Scratch / DevOps Center上の `dev` 環境) |
| 昇格先                    | `prod_devops2` (パイプライン「本番」ステージ)          |
| API バージョン            | 67.0                                                   |

---

## 1. 要件サマリー

ヒアリングで確定した内容:

1. 見積(`Quote__c`)・見積明細(`QuoteLineItem__c`)を**カスタムオブジェクトとして新規作成**する。標準Quoteは使用しない。
2. 一般的な見積書に記載される項目を両オブジェクトに追加する。
3. 見積書を**PDF出力するLWC**を作成する。**LWC単体で完結**させる(Visualforce不使用)。
4. そのLWCを**見積オブジェクトのレコードページのアクション**(Quick Action)として登録する。
5. 消費税は**明細ごとの税率**を持たせ、**税率別に集計**する(軽減税率・インボイス制度対応)。

### 非機能・制約

- 共有モデルは組織のデフォルトに従う(本作業でOWD変更は行わない)。Apexは `with sharing` + `WITH USER_MODE` で項目レベルセキュリティを尊重する。
- 明細件数は1見積あたり数十行を想定(バルク処理の特別対応は不要)。
- 外部連携なし。

---

## 2. 事前検証で確定した事実（推測ではなく実測・公式ドキュメント根拠）

設計の前提となる不確実な点は、着手前に実機検証と公式ドキュメントで確定させた。

### 2.1 PDF生成方式（実測で確定）

| 方式                                 | 日本語 | テキスト選択 | 判定                                |
| ------------------------------------ | ------ | ------------ | ----------------------------------- |
| **jsPDF 2.5.1 + 日本語フォント埋込** | ✅     | ✅           | **採用**                            |
| html2canvas + jsPDF（画像貼付）      | ✅     | ❌           | 不採用。文字検索不可・LWS下で不安定 |
| `window.print()`                     | ✅     | —            | 不採用。PDFを組織内に保存できない   |

確定事項:

- jsPDF は **v3 / v4 が Locker 環境で動作しない**。**2.5.1 に固定**する。
  出典: [Apex Hours — Generating PDFs with jsPDF in LWC](https://www.apexhours.com/generating-pdfs-with-jspdf-in-lightning-web-components-lwc/)
- 静的リソースは**1ファイル5MB上限**。
  出典: [LWC開発者ガイド — Static Resources](https://developer.salesforce.com/docs/platform/lwc/guide/create-resources.html)
- jsPDFの標準フォントは日本語非対応のため、TTFを base64 で `addFileToVFS` + `addFont` により埋め込む必要がある。
- **実測値（本環境で検証済み）**:

  | フォント構成                               | TTF         | base64      | 5MB上限   |
  | ------------------------------------------ | ----------- | ----------- | --------- |
  | Noto Sans JP 全CJK(約2万字)                | 4.17 MB     | **5.57 MB** | ❌ 超過   |
  | **Noto Sans JP / JIS X 0208 相当 7,423字** | **2.19 MB** | **2.92 MB** | ✅ 収まる |

  → **JIS X 0208(第一・第二水準)へサブセット化**して採用する。文字集合は Python の `cp932` コーデックから機械的に導出するため、再現可能かつ確定的。
  ライセンスは SIL Open Font License 1.1 のため再配布可。

### 2.2 LWCクイックアクションの仕様（公式ドキュメントで確定）

出典: [Create Screen Quick Actions — LWC開発者ガイド](https://developer.salesforce.com/docs/platform/lwc/guide/use-quick-actions-screen.html)

- `js-meta.xml` は `lightning__RecordAction` ターゲット + `<actionType>ScreenAction</actionType>`
- `quickAction-meta.xml` は `<type>ScreenAction</type>` + `<lightningWebComponent>c__xxx</lightningWebComponent>` + `<targetSobjectType>`
- **`recordId` は `connectedCallback()` では渡らない**。`@api set recordId(value)` のセッターで受ける必要がある。← 実装上の落とし穴のため明記

---

## 3. データモデル

```
Account ──(参照)── Quote__c ──(主従)── QuoteLineItem__c
                      │
              QuoteIssuer__mdt（自社情報・カスタムメタデータ）
```

### 3.1 Quote__c（見積）

表示ラベル: 見積 / 複数形: 見積 / レコード名: `見積番号` AutoNumber `Q-{00000}`

| API名                  | ラベル         | 型                                                    | 必須 | 備考                                                  |
| ---------------------- | -------------- | ----------------------------------------------------- | :--: | ----------------------------------------------------- |
| `Account__c`           | 取引先         | 参照(Account)                                         |  ○   |                                                       |
| `Opportunity__c`       | 商談           | 参照(Opportunity)                                     |      |                                                       |
| `Contact__c`           | 先方担当者     | 参照(Contact)                                         |      |                                                       |
| `CustomerName__c`      | 宛名           | テキスト(255)                                         |      | 空なら取引先名を使用                                  |
| `CustomerHonorific__c` | 敬称           | 選択リスト                                            |      | 御中 / 様（既定: 御中）                               |
| `Subject__c`           | 件名           | テキスト(255)                                         |  ○   |                                                       |
| `QuoteDate__c`         | 見積日         | 日付                                                  |  ○   | 既定 `TODAY()`                                        |
| `ExpirationDate__c`    | 見積有効期限   | 日付                                                  |      | 既定 `TODAY() + 30`                                   |
| `Status__c`            | ステータス     | 選択リスト                                            |  ○   | 作成中/申請中/承認済/送付済/受注/失注（既定: 作成中） |
| `DeliveryDate__c`      | 納期           | テキスト(100)                                         |      | 「別途協議」等の文言も入るためテキスト                |
| `DeliveryPlace__c`     | 納入場所       | テキスト(255)                                         |      |                                                       |
| `PaymentTerms__c`      | 支払条件       | テキスト(255)                                         |      |                                                       |
| `Notes__c`             | 備考           | ロングテキスト(4000)                                  |      |                                                       |
| `Subtotal__c`          | 小計(税抜)     | 積み上げ集計 SUM(`QuoteLineItem__c.Amount__c`)        |      |                                                       |
| `TaxableBase10__c`     | 10%対象額      | 積み上げ集計 SUM(`Amount__c`) 条件 `TaxRate__c = 10%` |      |                                                       |
| `TaxableBase8__c`      | 8%対象額       | 積み上げ集計 SUM(`Amount__c`) 条件 `TaxRate__c = 8%`  |      |                                                       |
| `TaxAmount10__c`       | 消費税(10%)    | 数式 `FLOOR(TaxableBase10__c * 0.1)`                  |      |                                                       |
| `TaxAmount8__c`        | 消費税(8%)     | 数式 `FLOOR(TaxableBase8__c * 0.08)`                  |      |                                                       |
| `TaxAmount__c`         | 消費税額合計   | 数式 `TaxAmount10__c + TaxAmount8__c`                 |      |                                                       |
| `TotalAmount__c`       | 合計金額(税込) | 数式 `Subtotal__c + TaxAmount__c`                     |      |                                                       |

**端数処理の設計意図**: インボイス制度では「税率ごとに1回の端数処理」が求められる。そのため明細ごとに切り捨てるのではなく、**税率別の対象額を集計してから切り捨てる**構成にしている。明細の `TaxAmount__c` は画面表示・確認用であり、合計計算には使用しない。

### 3.2 QuoteLineItem__c（見積明細）

表示ラベル: 見積明細 / レコード名: `明細番号` AutoNumber `QL-{00000}`

| API名            | ラベル   | 型                                                                                               | 必須 | 備考                           |
| ---------------- | -------- | ------------------------------------------------------------------------------------------------ | :--: | ------------------------------ |
| `Quote__c`       | 見積     | 主従関係(Quote__c)                                                                               |  ○   |                                |
| `LineNumber__c`  | 行番号   | 数値(3,0)                                                                                        |      | 印字順の制御                   |
| `ProductName__c` | 品名     | テキスト(255)                                                                                    |  ○   |                                |
| `Description__c` | 摘要     | ロングテキスト(1000)                                                                             |      |                                |
| `Quantity__c`    | 数量     | 数値(12,2)                                                                                       |  ○   | 既定 1                         |
| `Unit__c`        | 単位     | 選択リスト                                                                                       |      | 式/個/台/本/時間/人月/一式     |
| `UnitPrice__c`   | 単価     | 通貨(14,2)                                                                                       |  ○   |                                |
| `Amount__c`      | 金額     | 数式(通貨) `Quantity__c * UnitPrice__c`                                                          |      |                                |
| `TaxRate__c`     | 消費税率 | 選択リスト                                                                                       |  ○   | 10% / 8% / 非課税（既定: 10%） |
| `TaxAmount__c`   | 消費税額 | 数式(通貨) `CASE(TEXT(TaxRate__c), "10%", FLOOR(Amount__c*0.1), "8%", FLOOR(Amount__c*0.08), 0)` |      | 表示用                         |

### 3.3 QuoteIssuer__mdt（自社情報・カスタムメタデータ型）

見積書に印字する発行元情報をハードコードせず、組織ごとに設定可能にする。

`CompanyName__c` / `PostalCode__c` / `Address__c` / `Phone__c` / `Fax__c` / `InvoiceRegistrationNumber__c`(インボイス登録番号) / `BankAccount__c`(振込先) / `IsDefault__c`

既定レコード `Default` を1件同梱する。

---

## 4. コンポーネント構成

| 種別           | 名前                              | 役割                                         |
| -------------- | --------------------------------- | -------------------------------------------- |
| CustomObject   | `Quote__c`, `QuoteLineItem__c`    | データモデル                                 |
| CustomMetadata | `QuoteIssuer__mdt` + 既定レコード | 自社情報                                     |
| ApexClass      | `QuotePdfController`              | 見積+明細+自社情報を1回で返す                |
| ApexClass      | `QuotePdfControllerTest`          | テスト                                       |
| LWC            | `quotePdfGenerator`               | プレビュー表示 + PDF生成・ダウンロード       |
| StaticResource | `jspdf`                           | jsPDF **2.5.1** UMD                          |
| StaticResource | `NotoSansJPNormal`                | 日本語フォント base64 (JIS X 0208サブセット) |
| QuickAction    | `Quote__c.QuotePdfAction`         | 「見積書PDF出力」ScreenAction                |
| Layout         | `Quote__c`, `QuoteLineItem__c`    | クイックアクション配置・明細関連リスト       |
| CustomTab      | `Quote__c`                        | 見積タブ                                     |
| PermissionSet  | `QuoteManagement`                 | オブジェクト/項目/Apex/タブ権限              |

### 4.1 Apex設計

```apex
public with sharing class QuotePdfController {
    @AuraEnabled(cacheable=true)
    public static QuotePdfData getQuotePdfData(Id quoteId) { ... }
}
```

- `WITH USER_MODE` を使用し、実行ユーザーの項目・オブジェクト権限を強制する
- `quoteId` の sObjectType が `Quote__c` であることを検証してから使用する
- 明細は `LineNumber__c NULLS LAST, Name` 順で取得
- 戻り値はLWCが必要とする形に整形した内部クラス（`Quote`/`Lines`/`Issuer`）

### 4.2 LWC設計

- `lightning__RecordAction` / `ScreenAction`
- `recordId` は**セッター**で受ける（§2.2の落とし穴に対応）
- `@wire(getQuotePdfData, { quoteId: '$_recordId' })`
- 画面: SLDSで見積書レイアウトのプレビューを表示 + 「PDFをダウンロード」ボタン
- PDF生成: `platformResourceLoader.loadScript` で jsPDF → フォントbase64 を `addFileToVFS`/`addFont` → 描画 → `doc.save()`
- フォント(約2.9MB)の初回ロードに時間がかかるため、**ボタン押下時に遅延ロード**する（モーダル表示は即座に行う）

---

## 5. テスト計画

### Apex (`QuotePdfControllerTest`)

- 正常系: 見積+明細3行(10%/8%/非課税)を作成し、返却データの件数・金額・税率別集計を検証
- 積み上げ集計の検証: 小計・10%対象額・8%対象額・消費税・合計が期待値どおりか
- 異常系: 不正なId型を渡した場合に例外
- 権限: 参照権限のないユーザー(`System.runAs`)でのアクセス挙動
- カバレッジ目標: 90%以上

### Jest (`quotePdfGenerator`)

- wireがデータを返したときにプレビューの明細行数・合計金額が描画されること
- wireがエラーを返したときにエラーメッセージが表示されること
- `recordId` セッターが値を保持すること
- PDFボタン押下で `loadScript` が呼ばれること（jsPDFはモック）

---

## 6. リスクと対応

| #   | リスク                                                                                                                                                                                                                                                                                                                 | 影響 | 対応                                                                                                                                                                                                                                 |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | **数式項目に対する積み上げ集計の可否** — `Amount__c`(数式)をSUMできるかは公式ヘルプがロードエラーで一次情報を確認できなかった。数式項目の積み上げ集計は一般に可能だが、クロスオブジェクト参照・`TODAY()`等の動的関数・`ISBLANK`系を含む数式は不可とされる。`Amount__c = Quantity * UnitPrice` はいずれにも該当しない。 | 中   | Phase 6のデプロイで**実機検証**する。仮に不可だった場合は `Amount__c` を通常の通貨項目に変更し、**開始前レコードトリガーフロー**で `Quantity * UnitPrice` を書き込む方式にフォールバックする（集計対象が通常項目になり制約が消える） |
| 2   | フォント静的リソース約2.9MBによる初回ロード遅延                                                                                                                                                                                                                                                                        | 低   | ボタン押下時の遅延ロード + ローディング表示                                                                                                                                                                                          |
| 3   | jsPDFのバージョン差異によるLocker非互換                                                                                                                                                                                                                                                                                | 中   | 2.5.1に固定。`package.json`ではなく静的リソースとして版を固定コミット                                                                                                                                                                |
| 4   | 選択リスト`TaxRate__c`を積み上げ集計の条件に使用                                                                                                                                                                                                                                                                       | 低   | 条件付き積み上げ集計は選択リストに対応。Phase 6で検証                                                                                                                                                                                |
| 5   | リポジトリに約2.9MBのフォント資産が加わる                                                                                                                                                                                                                                                                              | 低   | SIL OFLで再配布可。生成手順を`doc/`に記録し再現可能にする                                                                                                                                                                            |

---

## 6.1 実装後の確定事項（Phase 6 の実機検証で判明）

| #   | 当初の想定                                                 | 実機での結果                                                                      |
| --- | ---------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1   | 数式項目 `Amount__c` の積み上げ集計が可能か不明            | **可能。問題なくデプロイ・動作した。** フォールバック（開始前フロー）は不要だった |
| 4   | 選択リスト `TaxRate__c` を積み上げ集計の条件に使用できるか | **可能。** 税率別集計は期待どおり動作                                             |

### 新たに判明した制約 — クイックアクションのレコードページ配置

`QuickAction` メタデータ自体は正しく作成・デプロイできたが、**LWCクイックアクションはページレイアウトの `<quickActionList>` に追加できない**ことが判明した。

```
QuickActionType LightningWebComponent を QuickActionList に追加できません。
```

LWCクイックアクションをレコードページに表示するには、**Lightningレコードページ(FlexiPage)の動的アクション**として配置し、そのFlexiPageをオブジェクトのレコードページとして割り当てる必要がある。

**本作業では、利用者の判断によりこの配置は保留とした。** アクション自体はデプロイ済みで、組織の[設定] → [オブジェクトマネージャ] → [見積] → [ボタン、リンク、およびアクション]に「見積書PDF出力」として存在する。

レコードページに出す手順（管理者が数分で実施可能）:

1. 見積レコードを開き、[設定] → [編集ページ]
2. ハイライトパネルを選択し、[アクション] を「動的アクションをアップグレード」
3. [アクションを追加] から「見積書PDF出力」を選択
4. [保存] → [有効化] → 組織のデフォルトに設定

また、この制約は次回以降の設計時に見落とさないよう、オーケストレータースキル
`dx-devops-workitem-orchestrate` の「メタデータ作成のルール」に記録済み。

### QuickAction メタデータの正しい形（4回のデプロイ失敗を経て確定）

```xml
<QuickAction xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>見積書PDF出力</label>
    <lightningWebComponent>quotePdfGenerator</lightningWebComponent>
    <optionsCreateFeedItem>false</optionsCreateFeedItem>
    <type>LightningWebComponent</type>
</QuickAction>
```

- `<apiVersion>` は**無効な要素**
- `<targetSobjectType>` ではなく `<targetObject>`。オブジェクト固有アクションはファイル名でスコープが決まるため省略可
- `<type>` は `ScreenAction` ではなく `LightningWebComponent`（`ScreenAction` はLWC側 `js-meta.xml` の `<actionType>` の値）
- `<optionsCreateFeedItem>` は**必須**

---

## 7. 対象外（本作業では実施しない）

- 見積の承認プロセス、メール送付機能
- PDFのSalesforce Filesへの保存（今回はダウンロードのみ。将来拡張として想定）
- 標準Quoteオブジェクト・CPQとの連携
- 多通貨対応（組織の既定通貨のみ）
- OWD・共有ルールの変更
