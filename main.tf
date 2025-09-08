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
    port        = var.server_port
    private_key = file(var.private_key_path)
  }
}
