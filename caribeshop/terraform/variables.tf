variable "location" {
  description = "Region de Azure con zonas de disponibilidad (eastus2, centralus, brazilsouth...)."
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = "Prefijo corto para nombrar recursos."
  type        = string
  default     = "caribeshop"
}

variable "my_ip" {
  description = "IPs publicas del equipo que ejecuta Terraform (curl -s ifconfig.me). Lista."
  type        = list(string)
}

variable "ssh_public_key_path" {
  description = "Ruta a la llave publica SSH."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "vm_size" {
  description = "Tamano de instancia del VMSS (Standard_B1s cabe en cuota de Azure for Students)."
  type        = string
  default     = "Standard_B1s"
}

variable "zones" {
  description = "Zonas de disponibilidad para repartir las instancias. Use [] si la region no tiene zonas."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "min_instances" {
  description = "Minimo de instancias (2 = alta disponibilidad)."
  type        = number
  default     = 2
}

variable "max_instances" {
  description = "Maximo de instancias. Revisar cuota: az vm list-usage -l <region> -o table."
  type        = number
  default     = 4
}

variable "cpu_scale_out" {
  description = "Porcentaje de CPU promedio (ventana 5 min) que dispara scale-out."
  type        = number
  default     = 60
}

variable "cpu_scale_in" {
  description = "Porcentaje de CPU promedio (ventana 5 min) que dispara scale-in."
  type        = number
  default     = 25
}

variable "alert_email" {
  description = "Correo para notificaciones de autoscaling y alertas (opcional)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Etiquetas de gobierno. La etiqueta 'responsable' es obligatoria por Policy."
  type        = map(string)
  default = {
    curso       = "infraestructura-ti"
    tema        = "caribeshop"
    ambiente    = "produccion"
    responsable = "equipo-caribeshop"
  }
}