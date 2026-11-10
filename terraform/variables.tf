variable "project_id" {
  description = "ID do projeto no Google Cloud"
  type        = string
}

variable "region" {
  description = "Região do cluster e do registro de imagens"
  type        = string
  default     = "us-central1"
}
