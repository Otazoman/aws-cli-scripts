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

# templates.csv  

|列名|説明|必須|補足|
|:----|:----|:----|:----|
|ACTION|実行するアクション。|はい|ADD (追加/更新): 指定された起動テンプレートが存在しない場合は新規作成し、存在する場合は内容を比較して必要に応じて新しいバージョンを作成、または指定されたTARGET_VERSIONをデフォルトに設定します。 REMOVE (削除): 指定された起動テンプレートを削除します。 その他の値が指定された場合は警告ログを出力し、その行の処理をスキップします。|
|REGION|AWSのリージョンコード（例: ap-northeast-1）。|はい|起動テンプレートを管理するAWSリージョンを指定します。|
|TEMPLATE_NAME|起動テンプレートの名前。|はい|固有の起動テンプレート名を指定します。この名前で起動テンプレートの存在確認や操作が行われます。|
|IMAGEID|EC2インスタンスが起動する際に使用するAMI (Amazon Machine Image) のID。例: ami-026c39f4021df9abe|いいえ|ADDアクションで新しい起動テンプレートを作成する場合や、既存テンプレートの新しいバージョンを作成する場合に必要です。ADDアクションでTARGET_VERSIONが指定されている場合は、この値は既存バージョンをデフォルトに設定するために使われるため、実際のAMI変更には影響しません。|
|INSTANCE_TYPE|EC2インスタンスのタイプ（例: t3.micro, t2.small）。|いいえ|ADDアクションで新しい起動テンプレートを作成する場合や、既存テンプレートの新しいバージョンを作成する場合に必要です。ADDアクションでTARGET_VERSIONが指定されている場合は、この値は既存バージョンをデフォルトに設定するために使われるため、実際のインスタンスタイプ変更には影響しません。|
|VERSION_DESCRIPTION|起動テンプレートのバージョンに付与する説明。|いいえ|ADDアクションで新しい起動テンプレートを作成する場合や、新しいバージョンを作成する場合に設定されます。省略された場合は、initial-creation-YYYYMMDD-HHMMSSまたはupdated-from-csv-YYYYMMDD-HHMMSSのような形式で自動生成されます。|
|TARGET_VERSION|ADDアクションで、既存の起動テンプレートの特定のバージョンをデフォルトとして設定したい場合にそのバージョン番号を指定します。|いいえ|この項目を空にすると、スクリプトはIMAGEIDまたはINSTANCE_TYPEが変更された場合に新しいバージョンを作成し、それをデフォルトに設定します。 もしここにバージョン番号（例: 2, 3）を指定した場合、スクリプトは新しいバージョンを作成せず、指定されたTARGET_VERSIONの起動テンプレートバージョンをデフォルトに設定しようとします。 したがって、指定されたTARGET_VERSIONがまだ存在しない場合は、InvalidLaunchTemplateId.VersionNotFoundエラーが発生します。この場合は、まずTARGET_VERSIONを空にした行で新しいバージョンを作成し、その後に改めてTARGET_VERSIONを指定してデフォルトにするという手順が必要です。|

