# Material de demostración — Infraestructura para TI (UTB)

Código de las dos demostraciones guiadas. Las instrucciones paso a paso están en
las guías del profesor (`Guia_Demo_Seguridad.docx` y `Guia_Demo_Escalamiento_HA.docx`).

## demo-seguridad/

| Carpeta | Uso |
|---|---|
| `01-inseguro/` | Anti-patrones intencionales. **Solo se escanea** con Checkov; no se despliega. |
| `02-seguro/` | Versión segura: VM sin IP pública con identidad administrada, Key Vault (RBAC, firewall, purge protection), Storage sin llaves, NSG con filtrado de salida, Log Analytics. |
| `03-policy/` | Azure Policy como código: Deny de blobs públicos + etiqueta obligatoria. |
| `.github/workflows/` | Pipeline: Checkov informativo, Checkov bloqueante con SARIF y `terraform plan` con OIDC. |

```bash
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
pip install checkov
checkov -d demo-seguridad/01-inseguro --framework terraform --compact
cd demo-seguridad/02-seguro && cp terraform.tfvars.example terraform.tfvars   # editar my_ip
terraform init && terraform apply
```

## demo-escalamiento/

| Carpeta | Uso |
|---|---|
| `terraform/` | VM Scale Set multi-zona (min 2 / max 4), Load Balancer Standard con sonda `/health`, autoscale por CPU (60 % / 25 %), reparación automática. |
| `app/app.py` | App sin dependencias: `/`, `/api/info`, `/work?ms=N` (consume CPU), `/health`. Se instala por cloud-init. |
| `locust/locustfile.py` | Carga con registro por backend (`BACKEND <instancia>`) y perfil opcional `LOCUST_PERFIL=escalones`. |

```bash
cd demo-escalamiento/terraform && terraform init && terraform apply
pip install locust
locust -f ../locust/locustfile.py --host http://$(terraform output -raw lb_ip)
```

Probado: `app.py` y `locustfile.py` ejecutados localmente; ambos `cloud-init` renderizados con
`templatefile` y validados; `02-seguro` pasa Checkov sin hallazgos (riesgos aceptados documentados
con `#checkov:skip`). Requiere provider `azurerm ~> 4.0`.

**Destruya los recursos al terminar** (`terraform destroy`).

## Proyecto integrador: `caribeshop/`

La plataforma integrada (seguridad + escalamiento + HA) está en la carpeta `caribeshop/`.
Ver `caribeshop/README.md` para despliegue y pruebas. Las demos originales se conservan como referencia.
