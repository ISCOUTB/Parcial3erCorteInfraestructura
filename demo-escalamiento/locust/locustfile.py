"""
Prueba de carga para la demo de autoscaling.

Uso (interfaz web en http://localhost:8089):
    pip install locust
    locust -f locustfile.py --host http://<IP_PUBLICA_DEL_LB>

Uso sin interfaz (útil en Azure Load Testing o en CI):
    locust -f locustfile.py --host http://<IP> --headless -u 60 -r 5 -t 15m

Además de las métricas normales, cada respuesta registra una fila
"BACKEND <nombre-instancia>" en la tabla de estadísticas, de modo que en
vivo se ve cuántas instancias atienden tráfico y cómo se reparte.
"""
import os

from locust import HttpUser, LoadTestShape, between, events, task

TRABAJO_MS = int(os.environ.get("TRABAJO_MS", "150"))


def registrar_backend(user, resp):
    host = resp.headers.get("X-Served-By", "desconocido")
    user.environment.events.request.fire(
        request_type="BACKEND",
        name=host,
        response_time=resp.elapsed.total_seconds() * 1000,
        response_length=0,
        exception=None,
        context={},
    )


class UsuarioWeb(HttpUser):
    wait_time = between(0.5, 1.5)

    @task(1)
    def pagina(self):
        with self.client.get("/api/info", name="/api/info", catch_response=True) as r:
            if r.status_code == 200:
                registrar_backend(self, r)
                r.success()
            else:
                r.failure(f"HTTP {r.status_code}")

    @task(5)
    def trabajo(self):
        with self.client.get(f"/work?ms={TRABAJO_MS}", name="/work", catch_response=True) as r:
            if r.status_code == 200:
                registrar_backend(self, r)
                r.success()
            else:
                r.failure(f"HTTP {r.status_code}")


# ---------------------------------------------------------------------
# Perfil de carga escalonado (opcional): se activa con  LOCUST_PERFIL=escalones
# Sube la carga por etapas, la sostiene para que Azure Monitor la "vea"
# y luego la baja para observar el scale-in.
# ---------------------------------------------------------------------
if os.environ.get("LOCUST_PERFIL") == "escalones":

    class Escalones(LoadTestShape):
        #       (fin_en_segundos, usuarios, tasa_de_creacion)
        etapas = [
            (120, 10, 2),    # calentamiento
            (720, 60, 5),    # carga sostenida -> dispara scale-out
            (900, 100, 5),   # pico
            (1500, 5, 5),    # enfriamiento -> dispara scale-in
        ]

        def tick(self):
            t = self.get_run_time()
            for fin, usuarios, tasa in self.etapas:
                if t < fin:
                    return usuarios, tasa
            return None


@events.test_start.add_listener
def al_iniciar(environment, **kwargs):
    print(f"Iniciando prueba contra {environment.host} con TRABAJO_MS={TRABAJO_MS}")
