terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Estado remoto cifrado con bloqueo (descomentar tras crear la cuenta de
  # almacenamiento del estado; ver README). El estado CONTIENE secretos
  # (valor de random_password), por eso nunca va a Git.
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate<suffix>"
  #   container_name       = "tfstate"
  #   key                  = "caribeshop.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  storage_use_azuread = true

  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}