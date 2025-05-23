# CSV  


スクリプトに指定するCSVファイルは、以下の列を持つ必要があります。ヘッダー行 (`REGION,NAME,TYPE,FAMILY,DESCRIPTION,PARAMS_FILE`) はスクリプトによりスキップされます。

| 列名          | 説明                                                                                                                            | 必須/任意 | 備考                                                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `REGION`      | パラメータグループを作成するAWSリージョンを指定します。                                                                           | 必須      | 例: `ap-northeast-1`, `us-east-1`                                                                                                |
| `NAME`        | 作成するパラメータグループの名前を指定します。                                                                                    | 必須      |                                                                                                                                    |
| `TYPE`        | 作成するパラメータグループのタイプを指定します。                                                                                  | 必須      | 有効な値: `rds-cluster` (RDSクラスターパラメータグループ), `rds-instance` (RDSインスタンスパラメータグループ), `elasticache` (ElastiCacheパラメータグループ) |
| `FAMILY`      | パラメータグループが対象とするデータベースエンジンとバージョン（ファミリー）を指定します。                                                | 必須      | 例: `aurora-mysql8.0`, `aurora-postgresql15`, `redis6.x` など。対象のAWSサービスに応じた正しいファミリー名を指定してください。                             |
| `DESCRIPTION` | パラメータグループの説明を指定します。                                                                                            | 必須      |                                                                                                                                    |
| `PARAMS_FILE` | このパラメータグループに適用するパラメータが記述されたCSVファイルのパスを指定します。パラメータを適用しない場合は空欄にしてください。 | 任意      | パスは、スクリプトファイルが存在するディレクトリからの相対パス、または絶対パスで指定します。パラメータファイルのフォーマットはサービスタイプによって異なります。 |

**パラメータファイル (`PARAMS_FILE` で指定するファイル) のフォーマットについて:**

`PARAMS_FILE` で指定するCSVファイルの内容は、パラメータグループのタイプ (`TYPE`) によって異なります。

* **ElasticCache (`type: elasticache`) のパラメータファイルフォーマット:**
    `パラメータ名,値` のCSV形式。ヘッダー行はスキップされます。コメント行 (`#` で始まる行) や空行はスキップされます。  

| 列名         | 説明                                                                     | 必須/任意 | 補足                                                                   |
| :----------- | :----------------------------------------------------------------------- | :-------- | :--------------------------------------------------------------------- |
| `PARAM_NAME` | 設定を変更するパラメータの名前です。                                         | 必須      | `modify-cache-parameter-group` コマンドの `--parameter-name-values` 引数で使用されます。 |
| `VALUE`      | パラメータに設定する値です。                                             | 必須      | `modify-cache-parameter-group` コマンドの `--parameter-name-values` 引数で使用されます。 |



* **RDS Cluster (`type: rds-cluster`) および RDS Instance (`type: rds-instance`) のパラメータファイルフォーマット:**
    `パラメータ名,値,適用方法` のCSV形式。ヘッダー行はスキップされます。コメント行 (`#` で始まる行) や空行はスキップされます。
    `適用方法 (ApplyMethod)` は `immediate` または `pending-reboot` を指定します。

`PARAMS_FILE` で指定するCSVファイルは、以下の列を持つ必要があります。

| 列名           | 説明                                                                                                   | 必須/任意 | 補足                                                                 |
| :------------- | :----------------------------------------------------------------------------------------------------- | :-------- | :------------------------------------------------------------------- |
| `PARAM_NAME`   | 設定を変更するパラメータの名前です。                                                                       | 必須      | `modify-db-parameter-group` または `modify-db-cluster-parameter-group` コマンドの `--parameters` 引数で使用されます。 |
| `VALUE`        | パラメータに設定する値です。                                                                           | 必須      | `modify-db-parameter-group` または `modify-db-cluster-parameter-group` コマンドの `--parameters` 引数で使用されます。 |
| `APPLY_METHOD` | パラメータ変更をいつ適用するかを指定します。`immediate` または `pending-reboot` のいずれかです。                       | 必須      | `modify-db-parameter-group` または `modify-db-cluster-parameter-group` コマンドの `--parameters` 引数で使用されます。 |

**補足事項:**

* スクリプトは、まず指定されたパラメータグループが存在するか確認し、存在しない場合のみ作成します。既存のパラメータグループに対しては、作成ステップはスキップされますが、`PARAMS_FILE` が指定されていればパラメータの変更は適用されます。
* `PARAMS_FILE` が指定されていない行については、パラメータグループの作成のみ（必要であれば）行われ、パラメータの変更はスキップされます。
* `PARAMS_FILE` のパスは、メインのCSVファイルがあるディレクトリからの相対パスとして優先的に解決され、見つからない場合はスクリプトがあるディレクトリからの相対パスとして試行されます。 


