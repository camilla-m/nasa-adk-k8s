output "image" {
  description = "Endereço da imagem Docker dos agentes"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.nasa.repository_id}/nasa-agents:v1"
}

output "get_credentials" {
  description = "Comando para o kubectl falar com o cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.nasa.name} --region ${var.region}"
}
