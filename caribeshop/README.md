# CaribeShop - Plataforma segura, escalable y altamente disponible

Proyecto integrador (Tercer Parcial) para la asignatura Infraestructura para TI (UTB).
Fusiona las demostraciones `demo-seguridad` y `demo-escalamiento` en una sola plataforma en Azure,
desplegada completamente con Terraform.

## Arquitectura

- Internet -> IP publica Standard (zonal-redundante) -> Load Balancer Standard (sonda `/health`)
- VM Scale Set (>= 2 zonas, min 2, autoscale por CPU, reparacion automatica)
  - identidad administrada, sin IP publica, sin SSH expuesto
- Subred `snet-app` con NSG de minimo privilegio (HTTP desde Internet + sondas del LB; egress por etiquetas de servicio)
- Key Vault (RBAC, purge protection, firewall subred + IP operador, secreto con expiracion)
- Storage Account (sin llaves compartidas, firewall, cifrado doble)
- Log Analytics (diagnostic settings de Key Vault y Storage)
- Azure Policy (Deny blobs publicos + etiqueta obligatoria `responsable`) asignada al RG
- Alerta de Azure Monitor por CPU sostenida con notificacion por correo

## Como desplegar

```bash
cd caribeshop/terraform
cp terraform.tfvars.example terraform.tfvars   # editar my_ip y alert_email
terraform init
terraform plan
terraform apply
```

Autenticacion: `az login` + variable de entorno `ARM_SUBSCRIPTION_ID`.
El backend remoto usa el Storage Account `statefordgarzautb`, contenedor `tfstate`; la identidad
que ejecuta Terraform requiere el rol `Storage Blob Data Contributor` en ese contenedor.

## Como destruir

```bash
cd caribeshop/terraform
terraform destroy
```

## Variables requeridas

- `my_ip`: lista de IPs publicas del operador (para firewalls de Key Vault y Storage).
- `location`, `prefix`, `ssh_public_key_path`, `vm_size`, `zones`, `min_instances`, `max_instances`,
  `cpu_scale_out`, `cpu_scale_in`, `alert_email`, `tags`.

## Pruebas

```bash
pip install locust
locust -f ../locust/locustfile.py --host http://$(terraform output -raw lb_ip)
# Perfil escalonado:
LOCUST_PERFIL=escalones locust -f ../locust/locustfile.py --host http://$(terraform output -raw lb_ip)
```

CSV/HTML se guardan en `../evidencias/`.

## Checklist de seguridad (linea base)

- [x] Toda la infraestructura en Terraform; estado remoto (backend azurerm), nunca en Git
- [x] Sin credenciales en el codigo
- [x] VNet con subred de aplicacion; NSG de minimo privilegio; ninguna VM con IP publica; SSH/RDP no expuestos
- [x] App lee secreto desde Key Vault con identidad administrada; KV con RBAC, purge protection, firewall, secreto con expiracion
- [x] Identidad del VMSS solo puede leer secretos (Key Vault Secrets User)
- [x] Azure Policy con efecto Deny asignada al RG
- [x] Diagnostic settings del Key Vault hacia Log Analytics
- [x] VMSS en >= 2 zonas, min 2 instancias
- [x] Balanceador con sonda de salud `/health`
- [x] Autoscale con histéresis y cooldowns; `ignore_changes = [instances]`
- [x] Reparacion automatica habilitada
- [x] Alerta de Azure Monitor con notificacion por correo
- [x] cloud-init configura la VM sin pasos manuales

## GitHub Actions

El workflow valida formato, configuraciones y Checkov en cada PR. En PRs internos también ejecuta
`terraform plan`. En un push a `master`, espera a que el plan termine antes de solicitar aprobación
del environment `azure-apply`; después vuelve a planificar y aplica. Ver el README de la raíz para
los Repository secrets y variables requeridos.