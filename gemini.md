TerraformとGitHub Actionsで作るサーバー再起動ワークフロー手順書**

### **はじめに**

この手順書は、Slackからスラッシュコマンドを実行することで、オンプレミスのDebianサーバーを安全に再起動し、GitHubリポジトリ内の`rebootlist.md`ファイルに記載されたディレクトリのDocker Composeプロジェクトを自動で立ち上げるための、完全なガイドです。

**ワークフローの全体像**

1.  **Slack**: ユーザーが `/server-reboot` を実行。
2.  **Pipedream**: Slackからのリクエストを受け取り、GitHubへ安全にAPIリクエストを送信。
3.  **GitHub Actions**: Pipedreamからのリクエストをトリガーにワークフローを開始。
4.  **自己ホストランナー**: サーバー上で待機しているランナーがジョブを受け取り、再起動コマンドを実行。
5.  **サーバー (systemd)**: 再起動後、OSの仕組み（systemd）がDocker Composeを自動実行。

-----

### **ステップ1：事前準備**

作業を始める前に、以下のアカウントと情報をご用意ください。

  * **GitHubアカウント**:
      * ワークフローを管理するリポジトリ (`dokkiitech/ServerRebooter`) を作成しておきます。
      * **Personal Access Token (PAT)** を[ここから作成](https://github.com/settings/tokens/new)し、`repo` スコープにチェックを入れて生成します。このトークンは後で複数回使用します。
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

1.  リポジトリに `.github/workflows/reboot.yml` というパスでファイルを作成します。

2.  以下の内容を貼り付けます。

    ```yaml
    name: Server Reboot Workflow

    on:
      repository_dispatch:
        types: [reboot-server]

    jobs:
      reboot:
        name: Reboot Server
        runs-on: self-hosted

        steps:
          - name: Send reboot command
            run: |
              echo "Received a request from Slack. Rebooting the server..."
              sudo shutdown -r +0

          - name: Send notification to Slack
            if: always()
            uses: slackapi/slack-github-action@v1.25.0
            with:
              payload: |
                {
                  "text": "サーバーの再起動コマンドを実行しました。数分後にDockerコンテナが自動で起動します。"
                }
            env:
              SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
    ```

3.  リポジトリの `Settings` \> `Secrets and variables` \> `Actions` に移動し、`New repository secret` をクリックします。

      * **Name**: `SLACK_WEBHOOK_URL`
      * **Secret**: 事前準備で取得したSlackのWebhook URL

-----

### **ステップ7：SlackとPipedreamの連携**

1.  **Slackスラッシュコマンドの作成**:
      * [Slack Appの管理画面](https://api.slack.com/apps)で `Slash Commands` \> `Create New Command` を選択。
      * **Command**: `/server-reboot`
      * **Request URL**: **この後のPipedreamで生成するURLを一時的に入力します。**
      * **Short Description**: サーバーを再起動します。
2.  **Pipedreamワークフローの作成**:
      * Pipedreamで新しいワークフローを作成し、トリガーとして `HTTP / Webhook` を選択します。
      * 表示された**Webhook URLをコピー**し、Slackスラッシュコマンドの **Request URL** に設定し直します。
      * Pipedreamで `+` を押し `Code` を追加、以下のNode.jsコードを貼り付けます。
        ```javascript
        import { axios } from "@pipedream/platform";

        export default defineComponent({
          async run({ steps, $ }) {
            // Slackに即時応答を返す
            await $.respond({
              status: 200,
              body: {
                response_type: "in_channel",
                text: "了解しました。GitHub Actionsにサーバー再起動をリクエストしました。",
              },
            });

            await axios($, {
              method: "POST",
              url: `https://api.github.com/repos/dokkiitech/ServerRebooter/dispatches`,
              headers: {
                "Accept": "application/vnd.github.v3+json",
                "Authorization": `Bearer ${process.env.GITHUB_PAT}`,
              },
              data: {
                event_type: "reboot-server",
              },
            });
          },
        });
        ```
      * 左メニューの `Environment Variables` で `GITHUB_PAT` という環境変数を作成し、値に**事前準備で取得したGitHub PAT**を設定します。
      * `Deploy` をクリックしてワークフローを有効化します。

-----

### **ステップ8：実行と今後の運用**

1.  **実行**: Slackで `/server-reboot` を実行し、全自動でサーバーが再起動され、`rebootlist.md` に記載のコンテナが起動することを確認します。
2.  **今後の運用**:
      * 起動対象のプロジェクトを追加・削除したい場合は、**`rebootlist.md` ファイルを編集してGitHubにプッシュするだけ**です。
      * 次回の再起動時から、新しいリストが自動的に適用されます。