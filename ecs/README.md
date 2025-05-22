# CSV

| 項目名 | 必須/任意 | 説明 | 補足 |
|--------|-----------|------|------|
| REGION | 必須 | AWSリージョン名 | 例: `ap-northeast-1` |
| ACTION | 必須 | 実行するアクション | `add`(作成/更新) または `remove`(削除)。`remove`時はサービス削除前にオートスケーリングポリシー解除→desired-count=0→サービス削除の流れで処理 |
| CLUSTER_NAME | 必須 | ECSクラスター名 | 既存のECSクラスターを指定 |
| TASK_DEFINITION_NAME | 必須 | タスク定義名とリビジョン | `family:revision`形式 (例: `sample-fargate:7`)。更新時はこのリビジョンに切り替え |
| SERVICE_NAME | 必須 | 作成するECSサービス名 |  |
| LAUNCH_TYPE | 必須 | 起動タイプ | `FARGATE` または `EC2` |
| DESIRED_COUNT | 必須 | 希望するタスク数 | `add`時は初期タスク数、`remove`時は0固定 |
| SUBNETS | 必須 | サブネットIDまたはNameタグ | 複数指定時はセミコロン区切り (例: `subnet-123;subnet-456`)。ID(`subnet-xxx`)かNameタグ値どちらでも可 |
| SECURITY_GROUPS | 必須 | セキュリティグループIDまたはNameタグ | 複数指定時はセミコロン区切り (例: `sg-123;webserver-sg`)。ID(`sg-xxx`)かグループ名どちらでも可 |
| PUBLIC_IP | 必須 | パブリックIP割り当て | `ENABLED`(割り当てる) または `DISABLED`(割り当てない) |
| TARGET_GROUP | 必須 | ターゲットグループARNまたは名前 | 例: `arn:aws:elasticloadbalancing:...` または `tg-ecs`。ALB/NLBと連携必須の場合に指定 |
| CONTAINER_NAME | 必須 | コンテナ名 | ターゲットグループと連携するコンテナ名。タスク定義内のコンテナ名と一致させる |
| CONTAINER_PORT | 必須 | コンテナポート | ターゲットグループと連携するポート番号 (例: `80`) |
| HEALTH_CHECK_PERIOD | 任意 | ヘルスチェック猶予期間(秒) | デフォルト`60`秒。サービス初回起動時のヘルスチェック開始待機時間 |
| MIN_CAPACITY | 必須 | オートスケーリング最小タスク数 | `0`以上で指定。`remove`時は無視 |
| MAX_CAPACITY | 必須 | オートスケーリング最大タスク数 | `MIN_CAPACITY`以上で指定。`remove`時は無視 |
| TARGET_VALUE | 必須 | オートスケーリングターゲット値(%) | CPU使用率の閾値 (例: `70.0` = 70%) |
| SCALE_OUT_COOLDOWN | 必須 | スケールアウトクールダウン(秒) | スケールアウト後の待機時間 (例: `300` = 5分) |
| SCALE_IN_COOLDOWN | 必須 | スケールインクールダウン(秒) | スケールイン後の待機時間 (例: `600` = 10分) |
| TAGS | 任意 | タグ付け | `Key:Value`形式 (例: `Environment:Production`)。複数指定時はセミコロン区切り (例: `Env:Prod;Team:Dev`) |
