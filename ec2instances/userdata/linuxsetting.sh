#!/bin/bash
# Amazon Linux 2023 ユーザーデータスクリプト
# Apache (httpd), rsyslog インストール, タイムゾーン設定

set -e

# ログ出力設定
# user-data の実行ログを /var/log/user-data.log に出力し、
# さらに systemd-journald を通じて CloudWatch Logs (設定されていれば) にも送信
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Starting user-data script at $(date)"

# 1. パッケージインストール
echo "=== Installing Packages (httpd, rsyslog, firewalld) ==="
# dnf パッケージマネージャーを使用
# Apache は httpd というパッケージ名です
# firewall設定のために firewalld もインストール
dnf update -y # システムを最新の状態に更新
dnf install -y httpd rsyslog firewalld

# 2. タイムゾーン設定
echo "=== Timezone Configuration ==="
# timedatectl コマンドを使用
timedatectl set-timezone Asia/Tokyo
echo "Timezone set to Asia/Tokyo."

# 3. サービスの有効化と起動
echo "=== Enabling and Starting Services ==="
# systemctl コマンドを使用
systemctl enable httpd    # Apache (httpd) サービスをOS起動時に有効化
systemctl start httpd     # Apache (httpd) サービスを開始
echo "Apache (httpd) service enabled and started."

systemctl enable rsyslog  # rsyslog サービスをOS起動時に有効化
systemctl start rsyslog   # rsyslog サービスを開始
echo "Rsyslog service enabled and started."

# firewalld サービスを有効化し起動 (インストール後)
systemctl enable firewalld
systemctl start firewalld
echo "Firewalld service enabled and started."

# 4. ファイアウォール設定 (firewalld を使用)
echo "=== Firewall Configuration (firewalld) ==="
# public ゾーンで HTTP (ポート 80) を許可 (永続化)
firewall-cmd --zone=public --add-service=http --permanent
# 設定をリロードして反映
firewall-cmd --reload
echo "Firewall rule for HTTP (port 80) applied."

# 5. 完了処理
echo "=== Setup Completed ==="
echo "User-data script finished successfully at $(date)" > /var/log/user-data-completion.log
