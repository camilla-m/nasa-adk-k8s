terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

# 1. APIs que o projeto precisa
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",        # GKE
    "artifactregistry.googleapis.com", # registro de imagens Docker
    "cloudbuild.googleapis.com",       # build da imagem na nuvem
    "aiplatform.googleapis.com",       # Vertex AI (Gemini)
  ])
  service            = each.value
  disable_on_destroy = false
}

# 2. Repositório para a imagem Docker dos agentes
resource "google_artifact_registry_repository" "nasa" {
  repository_id = "nasa-agents"
  location      = var.region
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# 3. Cluster GKE Autopilot: o Google cuida dos nós, a gente só manda os pods
resource "google_container_cluster" "nasa" {
  name                = "nasa-agents"
  location            = var.region
  enable_autopilot    = true
  deletion_protection = false
  depends_on          = [google_project_service.apis]
}

# 4. Permite que o ServiceAccount do Kubernetes (namespace nasa, SA nasa-agents)
#    chame o Gemini no Vertex AI, via Workload Identity. Sem chave, sem secret.
resource "google_project_iam_member" "agents_vertex" {
  project    = var.project_id
  role       = "roles/aiplatform.user"
  member     = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/nasa/sa/nasa-agents"
  depends_on = [google_container_cluster.nasa]
}

# 5. Permite que o Cloud Build (que roda como a SA padrão do Compute)
#    publique a imagem no Artifact Registry e escreva logs
resource "google_project_iam_member" "cloudbuild" {
  for_each = toset([
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
    "roles/storage.objectViewer",
  ])
  project    = var.project_id
  role       = each.value
  member     = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
  depends_on = [google_project_service.apis]
}
