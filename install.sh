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
