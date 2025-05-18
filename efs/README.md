# CSV


| 項目名                         | 必須 | 説明                                                                                       | 補足・例                                                                 |
|--------------------------------|------|--------------------------------------------------------------------------------------------|---------------------------------------------------------------------------|
| ACTION                         | はい | EFSファイルシステムに対して実行する操作を指定                                             | `add`（作成）、`remove`（削除）                                          |
| REGION                         | はい | EFSファイルシステムを作成または削除するAWSリージョンを指定                                 | 例: `ap-northeast-1`（東京）、`us-east-1`（バージニア北部）             |
| EFS_NAME                       | はい | EFSの「Name」タグに設定される名前                                                         | 一意で分かりやすい名前を推奨                                              |
| ENCRYPTED                     | 任意 | 暗号化を有効にするか指定                                                                  | `TRUE`, `FALSE`, `YES`, `NO`, `1`, `0` など                               |
| PERFORMANCE_MODE              | add時必須 | パフォーマンスモードを指定                                                                 | `generalPurpose`, `maxIO`                                                |
| THROUGHPUT_MODE               | add時必須 | スループットモードを指定                                                                  | `bursting`, `provisioned`, `elastic`                                     |
| PROVISIONED_THROUGHPUT_MIBPS | 条件付き | `THROUGHPUT_MODE=provisioned` のときのみ必須                                               | 例: `20`（20 MiB/s）                                                      |
| LC_TRANSITION_IA_DAYS         | 任意 | Infrequent Access（IA）ストレージへの移行日数を指定                                       | 例: `30`（30日後にIAへ）                                                  |
| LC_TRANSITION_ARCHIVE_DAYS    | 任意 | Archiveストレージへの移行日数を指定                                                       | 例: `90`（90日後にアーカイブへ）                                          |
| LC_TRANSITION_PRIMARY_ON_ACCESS | 任意 | IAやアーカイブからのアクセス時にプライマリへ戻すか指定                                     | `TRUE`, `FALSE` など                                                      |
| BACKUP_ENABLED                | 任意 | AWS Backupを有効にするか指定                                                              | `TRUE`, `FALSE` など                                                      |
| SUBNETS                       | 条件付き | マウントターゲットを作成するサブネットIDまたは名前（複数指定時はセミコロン区切り）        | 例: `subnet-abc123;subnet-def456`                                         |
| SECURITY_GROUPS               | 条件付き | マウントターゲットのセキュリティグループIDまたは名前（複数指定時はセミコロン区切り）      | 例: `sg-abc123;efs-sg`                                                    |
| ACCESS_POINTS                 | 任意 | アクセスポイントを指定（複数指定時はセミコロン区切り、形式は `パス|名前`）               | 例: `/data|data-ap;/logs|logs-ap`                                        |

