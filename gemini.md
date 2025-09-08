## TerraformとGitHub Actionsで作るサーバー再起動ワークフロー手順書**

### **はじめに**

この手順書は、Slackコマンドを起点としてオンプレミスのDebianサーバーを再起動し、GitHubリポジトリ内の`rebootlist.md`ファイルに記載されたディレクトリのDocker Composeプロジェクトを自動で立ち上げる、拡張性の高いワークフローを構築します。

**ワークフローの全体像**

1.  **Slack**: ユーザーが `/server-reboot` を実行。
2.  **Pipedream**: SlackからのリクエストをGitHubへ安全に転送。
3.  **GitHub Actions**: ワークフローを開始し、自己ホストランナーに再起動を指示。
4.  **サーバー**:
      * **再起動**: ランナーが再起動コマンドを実行。
      * **起動後**: `systemd`サービスが自動起動。
      * **設定更新**: GitHubから`rebootlist.md`を含むリポジトリを`git pull`で最新化。
      * **コンテナ起動**: `rebootlist.md`のリストに従い、各ディレクトリで`docker compose up -d`を順番に実行。

-----

### **ステップ1：事前準備**

作業を始める前に、以下のアカウントと情報をご用意ください。

  * **GitHubアカウント**:
      * ワークフローを管理するリポジトリ (`dokkiitech/ServerRebooter`) を作成しておきます。
      * **Personal Access Token (PAT)** を[ここから作成](https://github.com/settings/tokens/new)し、`repo` スコープにチェックを入れて生成します。
  * **SSHデプロイキー**:
      * 手元のPCで `ssh-keygen -t ed25519 -f ./rebooter_key` を実行し、`rebooter_key`（秘密鍵）と `rebooter_key.pub`（公開鍵）を作成します。
      * 作成した**公開鍵** (`rebooter_key.pub`) の中身を、GitHubリポジトリの `Settings` \> `Deploy keys` \> `Add deploy key` から登録します（書き込み権限は不要）。
  * **Terraform Cloudアカウント**:
      * [公式サイト](https://app.terraform.io/)からサインアップ（無料）しておきます。
  * **Slackワークスペース**:
      * **Slack App**を作成し、**Incoming Webhooks**を有効化して**Webhook URL**をコピーしておきます。
  * **Pipedreamアカウント**:
      * [公式サイト](https://pipedream.com/)からサインアップ（無料）しておきます。

-----

### **ステップ2：Terraform Cloudの設定**

機密情報をTerraform Cloudで安全に一元管理します。

1.  **Workspaceの作成**:
      * Terraform CloudでOrganizationとWorkspace (`ServerRebooter`) を作成します（CLI-driven workflow）。
2.  **変数の設定**:
      * 作成したWorkspaceの `Variables` ページで、以下の3つの変数を `Terraform Variables` として追加します。

| Key | Value | Sensitive |
| :--- | :--- | :--- |
| `github_pat` | 事前準備で取得したPAT (`ghp_...`) | **✅ ON** |
| `deploy_key_private`| `rebooter_key`（秘密鍵）ファイルの中身 | **✅ ON** |
| `server_ip` | オンプレサーバーのIPアドレス | **🔲 OFF** |

-----

### **ステップ3：Terraformコードの準備**

手元のPCに作業ディレクトリを作成し、以下の3つのファイルを用意します。

#### **`main.tf`**

```terraform
terraform {
  cloud {
    organization = "dokkiitech-org" # ご自身のOrganization名に変更

    workspaces {
      name = "ServerRebooter"
    }
  }
}

provider "ssh" {}

resource "null_resource" "setup_server" {
  provisioner "file" {
    content     = var.deploy_key_private
    destination = "/home/dokkiitech/.ssh/id_rebooter_key"
  }

  provisioner "file" {
    source      = "install.sh"
    destination = "/tmp/install.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chown dokkiitech:dokkiitech /home/dokkiitech/.ssh/id_rebooter_key",
      "chmod 600 /home/dokkiitech/.ssh/id_rebooter_key",
      "chmod +x /tmp/install.sh",
      "/tmp/install.sh '${var.github_repo_url}' '${var.github_pat}'"
    ]
  }

  connection {
    type        = "ssh"
    user        = var.server_user
    host        = var.server_ip
    private_key = file(var.private_key_path)
  }
}
```

#### **`variables.tf`**

```terraform
variable "server_ip" {
  type = string
}

variable "github_pat" {
  type      = string
  sensitive = true
}

variable "deploy_key_private" {
  type      = string
  sensitive = true
}

variable "server_user" {
  default = "dokkiitech"
}

variable "private_key_path" {
  default = "~/.ssh/id_rsa"
}

variable "github_repo_url" {
  default = "https://github.com/dokkiitech/ServerRebooter"
}
```

#### **`install.sh`**

```bash
#!/bin/bash
set -e

# --- Terraformから渡される引数 ---
GH_REPO_URL=$1
GH_TOKEN=$2
GH_RUNNER_VERSION="2.317.0" # 最新版は適宜確認

# --- 1. 依存パッケージとGitのインストール ---
echo ">>> Installing dependencies and Git..."
sudo apt-get update
sudo apt-get install -y curl jq git

# --- 2. GitHub Actions Runnerのインストールと設定 ---
echo ">>> Installing GitHub Actions Runner..."
cd /home/dokkiitech
mkdir -p actions-runner && cd actions-runner
curl -o actions-runner-linux-x64-${GH_RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${GH_RUNNER_VERSION}/actions-runner-linux-x64-${GH_RUNNER_VERSION}.tar.gz
tar xzf ./actions-runner-linux-x64-${GH_RUNNER_VERSION}.tar.gz

echo ">>> Configuring and installing runner service..."
./config.sh --url ${GH_REPO_URL} --token ${GH_TOKEN} --unattended --name $(hostname) --work _work
sudo ./svc.sh install
sudo ./svc.sh start

# --- 3. 設定用リポジトリのクローン ---
echo ">>> Cloning config repository..."
ssh-keyscan github.com >> /home/dokkiitech/.ssh/known_hosts
git clone git@github.com:dokkiitech/ServerRebooter.git /home/dokkiitech/ServerRebooter_config || true

# --- 4. 再起動後にrebootlist.mdを読み込む仕組みを作成 ---
echo ">>> Creating dynamic post-reboot docker-compose service..."

sudo bash -c 'cat > /usr/local/bin/post_reboot_docker.sh' << EOF
#!/bin/bash
sleep 10
echo "Updating config repo and starting Docker Compose projects..."
CONFIG_REPO_PATH="/home/dokkiitech/ServerRebooter_config"
REBOOT_LIST_FILE="\$CONFIG_REPO_PATH/rebootlist.md"

cd \$CONFIG_REPO_PATH
git fetch
git reset --hard origin/main

if [ -f "\$REBOOT_LIST_FILE" ]; then
    while IFS= read -r dir; do
      if [[ -n "\$dir" && ! "\$dir" =~ ^# ]]; then
        echo "--> Starting compose in: \$dir"
        if [ -d "\$dir" ]; then
          cd "\$dir" && docker compose up -d
        else
          echo "    WARNING: Directory not found: \$dir"
        fi
      fi
    done < "\$REBOOT_LIST_FILE"
else
    echo "WARNING: rebootlist.md not found!"
fi

echo "All specified Docker Compose projects started."
EOF

sudo chmod +x /usr/local/bin/post_reboot_docker.sh

sudo bash -c 'cat > /etc/systemd/system/post-reboot-docker.service' << EOF
[Unit]
Description=Start Docker Compose projects on boot
After=network.target docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/post_reboot_docker.sh
RemainAfterExit=true
StandardOutput=journal
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable post-reboot-docker.service

echo ">>> Setup complete!"
```

-----

### **ステップ4：`rebootlist.md`の作成**

GitHubリポジトリ (`dokkiitech/ServerRebooter`) のルートに `rebootlist.md` ファイルを作成し、起動したいディレクトリの絶対パスを1行ずつ記述します。

**`rebootlist.md` の記述例:**

```markdown
# Docker Composeプロジェクトの起動リスト
# このファイルに記載されたディレクトリを上から順に起動します。

/home/dokkiitech/BridgeMe-Back
/home/dokkiitech/n8n
```

-----

### **ステップ5：Terraformの実行**

ターミナルでTerraformコードがあるディレクトリに移動し、以下のコマンドでサーバーをセットアップします。

1.  **Terraform Cloudへログイン**: `terraform login`
2.  **初期化と適用**: `terraform init` 後、 `terraform apply`

-----

### **ステップ6：GitHub Actionsワークフローの設定**

リポジトリの `.github/workflows/reboot.yml` にワークフローを作成し、リポジトリのSecretsに `SLACK_WEBHOOK_URL` を登録します。（この手順は[以前の回答](https://www.google.com/search?q=%23)から変更ありません）

-----

### **ステップ7：SlackとPipedreamの連携**

Slackスラッシュコマンド (`/server-reboot`) を作成し、PipedreamのWebhook経由でGitHub Actionsをトリガーします。（この手順も[以前の回答](https://www.google.com/search?q=%23)から変更ありません）

-----

### **ステップ8：実行と今後の運用**

1.  **実行**: Slackで `/server-reboot` を実行し、全自動でサーバーが再起動され、`rebootlist.md` に記載のコンテナが起動することを確認します。
2.  **今後の運用**:
      * 起動対象のプロジェクトを追加・削除したい場合は、**`rebootlist.md` ファイルを編集してGitHubにプッシュするだけ**です。
      * 次回の再起動時から、新しいリストが自動的に適用されます。