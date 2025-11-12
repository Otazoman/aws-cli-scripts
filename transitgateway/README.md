# AWS Transit Gateway (TGW) 動的構築スクリプト

## 1. 概要

このスクリプト群は、`params.conf`ファイルに定義された構成に基づき、複数のAWSアカウントとリージョンにまたがるTransit Gateway (TGW) ハブ＆スポーク環境を動的に構築および削除します。

### 主な特徴

-   **柔軟な構成定義**: `params.conf`でTGWハブ、VPCスポークアタッチメント、TGWピアリングを自由に定義できます。
-   **複数VPC/アカウント対応**: 1つのTGWに複数のVPCをアタッチしたり、複数のスポークアカウントからVPCを接続したりすることが可能です。
-   **自動化**: スクリプトは定義ファイルを読み込み、TGWの作成、VPCアタッチメント、RAM共有、ピアリング接続、および関連するルーティング設定を自動で行います。
-   **冪等性**: スクリプトは繰り返し実行可能です。既に存在するリソースはスキップし、存在しないリソースのみを作成・削除します。

---

## 2. ファイル構成

| ファイル名 | 役割 |
| :--- | :--- |
| `setup_accountA.sh` | **ハブアカウント用**のセットアップスクリプト。TGW本体、同一アカウント内VPCアタッチメント、ピアリング接続、RAM共有の作成など、ハブ側のリソースを管理します。 |
| `setup_accountB.sh` | **スポークアカウント用**のセットアップスクリプト。ハブアカウントから共有されたRAM招待を承認し、自アカウントのVPCをTGWにアタッチします。 |
| `delete_accountA.sh` | **ハブアカウント用**のクリーンアップスクリプト。`setup_accountA.sh`で作成したリソースをすべて削除します。 |
| `delete_accountB.sh` | **スポークアカウント用**のクリーンアップスクリプト。`setup_accountB.sh`で作成したリソースをすべて削除します。 |
| `params.conf` | 環境全体の構成を定義する設定ファイルです。このファイルを編集するだけで、インフラの構成を変更できます。 |

---

## 3. 実行手順

### 環境構築

1.  **`params.conf`の編集**
    - `params.conf`を開き、ご自身の環境に合わせてインフラ構成を定義します。詳細は「5. `params.conf` 設定項目」を参照してください。

2.  **ハブアカウントの設定 (`setup_accountA.sh`)**
    - AWS CLIのプロファイルが**ハブアカウント** (`ACCOUNT_HUB_ID`で指定) を指していることを確認します。
    - 以下のコマンドを実行します。このスクリプトは、ハブアカウントが管理するすべてのリソース（TGW本体、ピアリング、RAM共有など）をセットアップします。
      ```bash
      ./setup_accountA.sh params.conf
      ```

3.  **スポークアカウントの設定 (`setup_accountB.sh`)**
    - `params.conf`で定義した各**スポークアカウント**ごとに、以下の手順を繰り返します。
    - AWS CLIのプロファイルを対象の**スポークアカウント**に合わせて切り替えます。
    - 以下のコマンドを実行します。このスクリプトは、現在設定されているプロファイルのアカウントに属するVPCのみをTGWにアタッチします。
      ```bash
      ./setup_accountB.sh params.conf
      ```

### 環境削除

削除は構築と逆の順序で行います。

1.  **スポークアカウントのクリーンアップ (`delete_accountB.sh`)**
    - `params.conf`で定義した各**スポークアカウント**ごとに、以下の手順を繰り返します。
    - AWS CLIのプロファイルを対象の**スポークアカウント**に合わせて切り替えます。
    - 以下のコマンドを実行します。
      ```bash
      ./delete_accountB.sh params.conf
      ```

2.  **ハブアカウントのクリーンアップ (`delete_accountA.sh`)**
    - すべてのスポークアカウントのクリーンアップが完了したら、AWS CLIのプロファイルを**ハブアカウント**に切り替えます。
    - 以下のコマンドを実行します。
      ```bash
      ./delete_accountA.sh params.conf
      ```

---

## 4. スクリプトの動作ロジック

-   各スクリプトは実行時に`params.conf`を読み込み、定義されている`TGW_*`, `PEERING_*`, `VPC_*`ブロックをループ処理します。
-   `setup/delete_accountA.sh`は、現在のAWSプロファイルが`ACCOUNT_HUB_ID`と一致するリソースブロックのみを処理します。
-   `setup/delete_accountB.sh`は、現在のAWSプロファイルが`VPC_*`ブロックで定義されたアカウントIDと一致し、かつクロスアカウント接続(`CROSS_ACCOUNT_RAM_SHARE_NAME`)が定義されているVPCのみを処理します。
-   この仕組みにより、複数のアカウントでスクリプトを使い回すことが可能になっています。

---

## 5. `params.conf` 設定項目

### 共通設定

| 項目名 | 詳細説明 |
| :--- | :--- |
| `TAGS` | 作成されるすべてのリソースに付与される追加タグ。AWS CLI JSON形式で複数のキー・値ペアを設定できます。`Name`タグは自動的に設定されるため、それ以外のタグを指定してください。<br>**例**: `"{Key=COST,Value=INFO},{Key=Environment,Value=Production},{Key=Project,Value=TransitGateway}"` |

### アカウント定義 (`ACCOUNT_*_ID`)

| 項目名 | 詳細説明 |
| :--- | :--- |
| `ACCOUNT_HUB_ID` | TGWを所有するハブアカウントのAWSアカウントID（12桁）。 |
| `ACCOUNT_SPOKE_B_ID`| スポークVPCを所有するアカウントのID。 `ACCOUNT_SPOKE_C_ID` のように、わかりやすい名前で自由に追加できます。 |

### TGWハブ定義 (`TGW_*`)

`TGW_1_...`, `TGW_2_...` のように、インデックスを付けて複数のTGWを定義できます。

| 項目名 | 詳細説明 |
| :--- | :--- |
| `TGW_1_ACCOUNT_ID_VAR` | このTGWを所有するアカウントの変数名 (`ACCOUNT_HUB_ID`など)。 |
| `TGW_1_REGION` | TGWを作成するAWSリージョン (例: `ap-northeast-1`)。 |
| `TGW_1_NAME` | TGWのリソース名。 |
| `TGW_1_ASN` | TGWのプライベートASN。 |
| `TGW_1_DESCRIPTION` | TGWの説明。 |

### TGWピアリング定義 (`PEERING_*`)

`PEERING_1_...` のように、インデックスを付けて複数のピアリング接続を定義できます。

| 項目名 | 詳細説明 |
| :--- | :--- |
| `PEERING_1_ENABLED` | このピアリング定義を有効にするか (`true` / `false`)。 |
| `PEERING_1_TGW_A_INDEX` | ピアリングする一方のTGWのインデックス (例: `1`は`TGW_1`を指す)。 |
| `PEERING_1_TGW_B_INDEX` | ピアリングするもう一方のTGWのインデックス (例: `2`は`TGW_2`を指す)。 |
| `PEERING_1_NAME` | ピアリングアタッチメントのリソース名。 |

### VPCスポークアタッチメント定義 (`VPC_*`)

`VPC_1_...`, `VPC_2_...` のように、インデックスを付けてTGWに接続したいVPCをすべて定義します。

| 項目名 | 詳細説明 |
| :--- | :--- |
| `VPC_1_ENABLED` | このVPCアタッチメント定義を有効にするか (`true` / `false`)。 |
| `VPC_1_ACCOUNT_ID_VAR` | このVPCを所有するアカウントの変数名 (`ACCOUNT_HUB_ID`, `ACCOUNT_SPOKE_B_ID`など)。 |
| `VPC_1_ATTACH_TO_TGW_INDEX` | 接続先のTGWのインデックス (例: `1`は`TGW_1`に接続)。 |
| `VPC_1_VPC_ID` | アタッチするVPCのID。 |
| `VPC_1_VPC_CIDR` | VPCのCIDRブロック。ルーティング設定に使用されます。 |
| `VPC_1_ATTACHMENT_NAME` | VPCアタッチメントのリソース名。 |
| `VPC_1_ROUTE_TABLE_IDS` | TGWへのルートを追加するVPCルートテーブルのID。複数ある場合はスペース区切り。 |
| `VPC_1_ENI_SUBNET_NAMES` | TGWアタッチメント用に作成するENIサブネットの名前。スペース区切り。 |
| `VPC_1_ENI_SUBNET_CIDRS` | 上記サブネットのCIDRブロック。スペース区切りで、名前の数と一致させる必要があります。 |
| `VPC_1_ENI_SUBNET_AZS` | 上記サブネットのアベイラビリティゾーン。スペース区切りで、名前の数と一致させる必要があります。 |
| `VPC_1_CROSS_ACCOUNT_RAM_SHARE_NAME` | **クロスアカウント接続の場合のみ設定。** RAMでTGWを共有する際のリソース共有名を指定します。 |
