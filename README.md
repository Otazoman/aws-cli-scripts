# AWS CLI Scripts for Bulk Resource Management

## 概要 (Overview)

このリポジトリは、AWSリソースをCSVファイルベースで一括管理するためのシェルスクリプト群です。AWS CLIを活用し、各サービスのリソースの作成 (`add`) および削除 (`remove`) を簡単に行うことができます。

各スクリプトは対応するCSVファイルを読み込み、定義されたリソース情報を元にAWSの各種サービスを操作します。

## 主な特徴 (Features)

- **CSVによる一括管理**: 各サービスのリソース定義をCSVファイルで行うため、大量のリソースを一度に、かつ宣言的に管理できます。
- **多様なAWSサービスに対応**: VPC、EC2、ECS、CodeDeploy、CodeBuildなど、基本的なインフラからCI/CDパイプラインまで幅広くカバーしています。
- **冪等性の考慮**: スクリプトはリソースの存在確認を行い、存在しない場合のみ作成を試みるなど、繰り返し実行しても問題が起きにくいように設計されています。（一部スクリプトを除く）
- **シンプルな操作**: 各ディレクトリに移動し、CSVを編集してシェルスクリプトを実行するだけの簡単なステップで操作が完了します。

## 対応サービス一覧 (Covered Services)

- Auto Scaling
- CodeSeries (CodeBuild, CodeDeploy)
- EC2 Instances
- ECS (Elastic Container Service)
- EFS (Elastic File System)
- ElastiCache
- ELB (Elastic Load Balancing)
- IAM (Identity and Access Management)
- Parameter Group (RDS, ElastiCacheなど)
- RDS Aurora
- S3 (Simple Storage Service)
- Secrets Manager
- Security Groups
- Subnet Group (RDS, ElastiCacheなど)
- Systems Manager
- VPC

## 基本的な使用方法 (General Usage)

1.  **ディレクトリへ移動**: 管理したいサービスのディレクトリに移動します。
    ```bash
    cd <サービス名のディレクトリ>
    # 例: cd codeseries
    ```

2.  **CSVファイルの編集**: ディレクトリ内にある `*.csv` ファイルを編集し、作成または削除したいリソースの情報を定義します。
    ```csv
    ACTION,PROJECT_NAME,SOURCE_TYPE,...
    add,my-project,GITHUB,...
    remove,old-project,GITHUB,...
    ```

3.  **スクリプトの実行**: `operate_*.sh` スクリプトに、編集したCSVファイルを引数として渡して実行します。
    ```bash
    ./<スクリプト名>.sh <CSVファイル名>
    # 例: ./operate_codebuild.sh codebuild_projects.csv
    ```

## 具体例: CodeBuildプロジェクトの作成 (Example)

`codeseries` ディレクトリを使用して、CodeBuildプロジェクトを一括で作成する例です。

1.  `codeseries` ディレクトリに移動します。
    ```bash
    cd codeseries
    ```

2.  `codebuild_projects.csv` を以下のように編集します。
    ```csv
    ACTION,PROJECT_NAME,SOURCE_TYPE,SOURCE_LOCATION,IMAGE,COMPUTE_TYPE,ENVIRONMENT_TYPE,SERVICE_ROLE_NAME,BUILDSPEC,ARTIFACTS_TYPE,ARTIFACTS_LOCATION,AWS_REGION
    add,MyWebApp-Build,GITHUB,https://github.com/your-account/my-webapp.git,aws/codebuild/standard:5.0,BUILD_GENERAL1_SMALL,LINUX_CONTAINER,CodeBuildServiceRole,buildspec.yml,S3,my-webapp-artifacts,ap-northeast-1
    add,MyAPI-Build,GITHUB,https://github.com/your-account/my-api.git,aws/codebuild/standard:5.0,BUILD_GENERAL1_SMALL,LINUX_CONTAINER,CodeBuildServiceRole,buildspec.yml,NO_ARTIFACTS,,ap-northeast-1
    ```

3.  スクリプトを実行してプロジェクトを作成します。
    ```bash
    ./operate_codebuild.sh codebuild_projects.csv
    ```
    スクリプトが実行され、CSVに定義された2つのCodeBuildプロジェクトが作成されます。

## 前提条件 (Prerequisites)

- **AWS CLI**: AWS CLIがインストールされ、認証情報が設定済みであること。
- **Shell環境**: `bash` が動作するシェル環境。
- **IAM権限**: スクリプトが操作するAWSリソースに対する適切なIAM権限が付与されていること。


