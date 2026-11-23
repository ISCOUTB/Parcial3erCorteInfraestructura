variable "location" {
  description = "Región con zonas de disponibilidad (eastus2, centralus, brazilsouth, ...). Verifique las permitidas en su suscripción."
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  type    = string
  default = "hademo"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

variable "vm_size" {
  description = "Standard_B1s cabe en la cuota de Azure for Students. Alternativa: Standard_B2ats_v2 / Standard_B2s (más vCPU por instancia, menos instancias)."
  type        = string
  default     = "Standard_B1s"
}

variable "zones" {
  description = "Zonas de disponibilidad para repartir las instancias. Use [] si la región no tiene zonas."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "min_instances" {
  description = "Mínimo de instancias. 2 = alta disponibilidad (sobrevive a la caída de una)."
  type        = number
  default     = 2
}

variable "max_instances" {
  description = "Máximo de instancias. Revise su cuota: az vm list-usage -l <region> -o table"
  type        = number
  default     = 4
}

variable "cpu_scale_out" {
  description = "% de CPU promedio (ventana de 5 min) que dispara el scale-out"
  type        = number
  default     = 60
}

variable "cpu_scale_in" {
  description = "% de CPU promedio (ventana de 5 min) que dispara el scale-in"
  type        = number
  default     = 25
}

variable "alert_email" {
  description = "Correo para notificaciones de autoscaling (opcional)"
  type        = string
  default     = ""
}
