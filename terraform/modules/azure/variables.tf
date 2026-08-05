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

variable "vm_size" {
  description = "VMSS instance size. Standard_B1s has zero quota for this subscription in swedencentral (and every other region with open quota lacks Log Analytics/DCR support -- see main.tf); Standard_B2ts_v2 is the confirmed-available burstable size here instead."
  type        = string
  default     = "Standard_B2ts_v2"
}

variable "instance_count" {
  description = "Number of VMSS instances"
  type        = number
  default     = 1
}
