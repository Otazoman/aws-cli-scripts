# asg_config.csv

## Auto Scaling Group 設定用CSVファイル項目説明表

| 列名 | 説明 | 必須 | 補足 |
|:---|:---|:---|:---|
| **ACTION** | 実行するアクション。`add` (作成/更新) または `remove` (削除) を指定します。 | はい | `add` アクションの場合、既存のAuto Scaling Groupがあれば更新を試み、なければ新規作成します。<br> `remove` アクションの場合、指定されたASGを強制削除します。 |
| **REGION** | Auto Scaling Group をデプロイするAWSリージョン。 | はい | 例: `ap-northeast-1` |
| **AUTOSCALING_GROUP_NAME** | Auto Scaling Group の名前。 | はい | 各リージョンで一意である必要があります。 |
| **LAUNCH_TEMPLATE_NAME** | 使用する起動テンプレートの名前。 | はい | |
| **LAUNCH_TEMPLATE_VERSION** | 起動テンプレートのバージョン。 | いいえ | 指定しない場合、`$Latest` (最新バージョン) が使用されます。 |
| **MIN_SIZE** | Auto Scaling Group の最小インスタンス数。 | はい | |
| **MAX_SIZE** | Auto Scaling Group の最大インスタンス数。 | はい | |
| **DESIRED_CAPACITY** | Auto Scaling Group が最初に起動する希望するインスタンス数。 | はい | |
| **SUBNETS** | インスタンスを起動するサブネットの**名前**または**ID**。複数の場合はセミコロン (`;`) で区切ります。 | はい | 例: `subnet-xxxxxxxxxxxxxxxxx;my-public-subnet`。<br> サブネット名を指定した場合、スクリプトは対応するIDを解決しようとします。 |
| **HEALTH_CHECK_TYPE** | ヘルスチェックのタイプ。`EC2` または `ELB` を指定します。 | いいえ | 指定しない場合、デフォルトは `EC2` です。<br> `ELB` を指定する場合は、関連するターゲットグループが設定されている必要があります。 |
| **HEALTH_CHECK_GRACE_PERIOD** | ヘルスチェックの猶予期間（秒）。インスタンスが起動してからヘルスチェックを開始するまでの時間。 | いいえ | デフォルトは300秒です。 |
| **DEFAULT_INSTANCE_WARMUP** | 新しいインスタンスが稼働中と見なされるまでのデフォルトのウォームアップ時間（秒）。 | いいえ | この期間中、インスタンスはスケーリングポリシーのクールダウンやヘルスチェックの評価に影響を与えません。 |
| **CAPACITY_REBALANCE** | スポットインスタンスをより新しいキャパシティと置き換える容量リバランスを有効にするか。`true` または `false`。 | いいえ | デフォルトは `false` です。 |
| **NEW_INSTANCES_PROTECTED_FROM_SCALE_IN** | 新しいインスタンスがスケールインイベントから保護されるか。`true` または `false`。 | いいえ | デフォルトは `false` です。 |
| **MAINTENANCE_POLICY_TYPE** | インスタンスのメンテナンスポリシーのタイプ。`None`, `LaunchBeforeTerminate`, `TerminateBeforeLaunch`, `Custom` を指定します。 | いいえ | `None` または空の場合、ポリシーは設定されません。<br> `LaunchBeforeTerminate` の場合、新しいインスタンスが起動してから古いインスタンスが終了します。`MaxHealthyPercentage` と合わせて使用します。<br> `TerminateBeforeLaunch` の場合、古いインスタンスが終了してから新しいインスタンスが起動します。`MinHealthyPercentage` と合わせて使用します。<br> `Custom` の場合、`MinHealthyPercentage` と `MaxHealthyPercentage` の両方を指定する必要があります。 |
| **MIN_HEALTHY_PERCENTAGE** | メンテナンスイベント中に正常なインスタンスの最小割合（%）。`MAINTENANCE_POLICY_TYPE` が `TerminateBeforeLaunch` または `Custom` の場合に関連します。 | いいえ | `MAINTENANCE_POLICY_TYPE` が `TerminateBeforeLaunch` の場合、指定がないとデフォルトで `90` が使用されます。<br> `Custom` の場合は必須です。 |
| **MAX_HEALTHY_PERCENTAGE** | メンテナンスイベント中に正常なインスタンスの最大割合（%）。`MAINTENANCE_POLICY_TYPE` が `LaunchBeforeTerminate` または `Custom` の場合に関連します。 | いいえ | `MAINTENANCE_POLICY_TYPE` が `LaunchBeforeTerminate` の場合、指定がないとデフォルトで `110` が使用されます。<br> `Custom` の場合は必須です。 |
| **TAGS** | Auto Scaling Group とそれにアタッチされるインスタンスに適用するタグ。`Key=Value` または `Key=Value,PropagateAtLaunch=true/false` 形式で指定し、複数指定の場合はセミコロン (`;`) で区切ります。 | いいえ | `PropagateAtLaunch` は、このタグを起動されたインスタンスに伝播させるか否か（`true` または `false`）を制御します。省略した場合のデフォルトは `true` です。<br> 例: `Name=MyWebApp;Environment=Prod;Owner=AdminTeam,PropagateAtLaunch=false` |
| **TARGET_GROUP_ARNS** | インスタンスを登録するターゲットグループの**ARN**または**名前**。複数の場合はセミコロン (`;`) で区切ります。 | いいえ | ALB/NLB のターゲットグループにASGインスタンスを登録する場合に使用します。<br> 名前を指定した場合、スクリプトは対応するARNを解決しようとします。<br> 例: `arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/my-tg/xxxxxxxxxxxxxxxxx` または `my-target-group-name` |
| **LOAD_BALANCER_TARGET_GROUP_ARNS** | (非推奨) Classic Load Balancer または ALB/NLB ターゲットグループのARN。セミコロン (`;`) で区切ります。 | いいえ | AWS CLI では `--load-balancer-target-group-arns` は非推奨となっています。代わりに `TARGET_GROUP_ARNS` を使用してください。**このスクリプトでは現在処理されません。** |
| **METRICS_GRANULARITY** | メトリクス収集の粒度。`1Minute` を指定します。 | いいえ | `METRICS` と合わせて設定します。 |
| **METRICS** | 収集するメトリクスのリスト。スペース区切りで指定します。 | いいえ | 例: `GroupMinSize GroupMaxSize GroupInServiceInstances` など。<br> 利用可能なメトリクスについてはAWSのドキュメントを参照してください。 |
| **POLICY_NAME** | 設定するスケーリングポリシーの名前。 | いいえ | `POLICY_TYPE` と合わせて設定します。 |
| **POLICY_TYPE** | スケーリングポリシーのタイプ。`TargetTrackingScaling` を指定します。 | いいえ | 他のタイプ（例: `SimpleScaling`, `StepScaling`）も存在しますが、このスクリプトでは `TargetTrackingScaling` のみが実装されています。 |
| **TARGET_TRACKING_METRIC_TYPE** | ターゲット追跡スケーリングポリシーで使用するメトリクスタイプ。`ASGAverageCPUUtilization` など。 | いいえ | `POLICY_TYPE` が `TargetTrackingScaling` の場合に必須です。<br> 利用可能なメトリクスタイプについてはAWSのドキュメントを参照してください。 |
| **TARGET_TRACKING_TARGET_VALUE** | ターゲット追跡スケーリングポリシーの目標値。 | いいえ | `POLICY_TYPE` が `TargetTrackingScaling` の場合に必須です。 |
| **DISABLE_SCALE_IN_BOOLEAN** | ターゲット追跡スケーリングポリシーでスケールインを無効にするか。`true` または `false`。 | いいえ | デフォルトは `false` です。`POLICY_TYPE` が `TargetTrackingScaling` の場合に関連します。 |


