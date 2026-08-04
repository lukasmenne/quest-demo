variable "image" {
  description = "Container image reference, e.g. ghcr.io/lukasmenne/quest-demo:sha-abc123"
  type        = string
}

variable "secret_word" {
  description = "Value for the SECRET_WORD environment variable, exercised by /secret_word"
  type        = string
  sensitive   = true
}

variable "app_port" {
  description = "Port the app listens on inside the container"
  type        = number
  default     = 3000
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
