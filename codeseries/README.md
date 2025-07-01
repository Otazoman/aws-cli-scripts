#TION` | 実行する操作を指定します。 | 必須 | `add` (作成/更新) または `remove` (削除) を指定します。 |
| `PROJECT_NAME` | CodeBuildプロジェクトの名前。 | 必須 | |
| `SOURCE_TYPE` | ソースプロバイダーのタイプ。 | 必須 | `S3`, `CODECOMMIT`, `GITHUB`, `GITHUB_ENTERPRISE`, `BITBUCKET` など。 |
| `SOURCE_LOCATION` | ソースコードの場所。 | 必須 | `S3`の場合は `バケット名/オブジェクトキー`、`GITHUB`の場合はリポジトリのHTTPSクローンURLを指定します。 |
| `IMAGE` | ビルド環境で使用するDockerイメージ。 | 必須 | 例: `aws/codebuild/standard:5.0`。AWS提供のイメージまたはカスタムイメージを指定します。 |
| `COMPUTE_TYPE` | ビルドに使用するコンピューティングタイプ。 | 必須 | 例: `BUILD_GENERAL1_SMALL`, `BUILD_GENERAL1_MEDIUM`。 |
| `ENVIRONMENT_TYPE` | ビルド環境のタイプ。 | 必須 | 例: `LINUX_CONTAINER`, `WINDOWS_CONTAINER`, `ARM_CONTAINER`。 |
| `SERVICE_ROLE_NAME` | CodeBuildが使用するIAMサービスロールの名前。 | `add`の場合必須 | スクリプトはこの名前からARNを検索します。ロールは事前に作成されている必要があります。 |
| `BUILDSPEC` | ビルドスペックファイルの場所。 | 必須 | ソースコード内のファイルパス (例: `buildspec.yml`) またはインラインでYAMLを記述します。 |
| `ARTIFACTS_TYPE` | ビルド成果物のタイプ。 | 必須 | `NO_ARTIFACTS` (成果物なし) または `S3` を指定します。 |
| `ARTIFACTS_LOCATION` | ビルド成果物の出力先。 | `ARTIFACTS_TYPE`が`S3`の場合必須 | S3バケット名を指定します。バケットが存在しない場合はスクリプトが作成を試みます。 |
| `AWS_REGION` | プロジェクトを作成するAWSリージョン。 | 任意 | 未指定の場合は、スクリプト内で定義されたデフォルトリージョン (`ap-northeast-1`) が使用されます。 |


## codedeploy_apps.csv  

| 列名 | 説明 | 必須/任意 | 補足 |
| :--- | :--- | :--- | :--- |
| `ACTION` | 実行する操作を指定します。 | 必須 | `add` (作成/更新) または `remove` (削除) を指定します。 |
| `COMPUTE_PLATFORM` | CodeDeployが使用するコンピューティングプラットフォーム。 | 必須 | `ECS`, `Server` (EC2/オンプレミス), `Lambda` のいずれかを指定します。 |
| `APPLICATION_NAME` | CodeDeployアプリケーションの名前。 | 必須 | |
| `AWS_REGION` | リソースを作成するAWSリージョン。 | 必須 | 例: `ap-northeast-1` |
| `DEPLOYMENT_GROUP_NAME` | デプロイグループの名前。 | 必須 | |
| `ROLE_NAME` | CodeDeployが使用するIAMサービスロールの名前。 | `add`の場合必須 | |
| `TAGS` | アプリケーションとデプロイグループに付与するタグ。 | 任意 | `キー1:値1;キー2:値2` のようにセミコロン区切りで指定します。 |
| `SERVICE_NAME` | ECSサービスの名前。 | `ECS`の場合必須 | |
| `CLUSTER_NAME` | ECSクラスターの名前。 | `ECS`の場合必須 | |
| `TARGET_GROUP_NAME_BLUE` | Blue環境のターゲットグループ名。 | `ECS`と`Server`の`BLUE_GREEN`の場合必須 | `Server`の`IN_PLACE`でELBと連携する場合にも使用します。 |
| `TARGET_GROUP_NAME_GREEN` | Green環境のターゲットグループ名。 | `ECS`と`Server`の`BLUE_GREEN`の場合必須 | |
| `LB_NAME` | ロードバランサーの名前。 | `ECS`と`Server`の`BLUE_GREEN`の場合必須 | |
| `PROD_LISTENER_PORT` | 本番トラフィック用のリスナーポート。 | `ECS`と`Server`の`BLUE_GREEN`の場合必須 | |
| `PROD_LISTENER_PROTOCOL` | 本番トラフィック用のリスナープロトコル。 | `ECS`と`Server`の`BLUE_GREEN`の場合必須 | `HTTP`, `HTTPS`など。 |
| `TEST_LISTENER_PORT` | テストトラフィック用のリスナーポート。 | `ECS`と`Server`の`BLUE_GREEN`の場合必須 | |
| `TEST_LISTENER_PROTOCOL` | テストトラフィック用のリスナープロトコル。 | `ECS`と`Server`の`BLUE_GREEN`の場合必須 | `HTTP`, `HTTPS`など。 |
| `AUTO_SCALING_GROUP` | デプロイ対象のAuto Scalingグループ名。 | `Server`の場合任意 | `ec2-tag-filters`と同時に指定可能です。 |
| `DEPLOYMENT_CONFIG` | デプロイ設定の名前。 | 任意 | 例: `CodeDeployDefault.AllAtOnce`。未指定の場合はデフォルト値が使用されます。 |
| `EC2_TAG_KEY` | EC2インスタンスを特定するためのタグのキー。 | `Server`の場合任意 | `AUTO_SCALING_GROUP`と併用しない場合は、インスタンスを特定するために必須です。 |
| `EC2_TAG_VALUE` | EC2インスタンスを特定するためのタグの値。 | `Server`の場合任意 | |
| `EC2_TAG_TYPE` | EC2タグフィルターのタイプ。 | `Server`の場合任意 | `KEY_ONLY`, `VALUE_ONLY`, `KEY_AND_VALUE` のいずれかを指定します。 |
| `LAMBDA_ALIAS` | デプロイ対象のLambda関数のエイリアス名。 | `Lambda`の場合必須 | |
| `CURRENT_VERSION` | 現在のトラフィックが向いているLambdaのバージョン。 | `Lambda`の場合必須 | |
| `TARGET_VERSION` | 新しくデプロイするLambdaのバージョン。 | `Lambda`の場合必須 | |
| `DEPLOYMENT_TYPE` | EC2 (`Server`) のデプロイタイプ。 | `Server`の場合必須 | `BLUE_GREEN` または `IN_PLACE` を指定します。 |

## codebuild_projects.csv  


