variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"  # Seoul region
}

variable "stage" {
  description = "Prefix for resource names"
  type        = string
  default     = "flowise"
}

variable "allowed_cidr" {
  description = "CIDR allowed to access Flowise on port 3000. Use your IP: curl ifconfig.me"
  type        = string
  default     = "0.0.0.0/0" # Restrict to your IP for security, e.g. "203.0.113.5/32"
}
