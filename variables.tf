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
