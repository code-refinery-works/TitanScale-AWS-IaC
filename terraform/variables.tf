variable "project"     { type = string; default = "megascale" }
variable "region"      { type = string; default = "ap-northeast-1" }
variable "app_port"    { type = number; default = 8080 }
variable "app_image"   { type = string; default = "nginx:latest"; description = "ECR image URI for the application" }
variable "db_password" { type = string; sensitive = true; description = "Aurora master password (min 8 chars)" }