# --- Infrastructure ---

k8s_yaml("infra/postgres.yaml")
k8s_yaml("infra/minio.yaml")
k8s_yaml("infra/kafka.yaml")
k8s_yaml("infra/keycloak.yaml")
k8s_yaml(local(
    "kubectl create secret generic gee-sa-key" +
    " --from-file=gee-sa-key.json=../secrets/gee-sa-key.json" +
    " --dry-run=client -o yaml",
    quiet=True,
))

k8s_resource("postgres", labels=["infra"], port_forwards=["15432:5432"])
k8s_resource("minio", labels=["infra"], port_forwards=["9000:9000", "9001:9001"])
k8s_resource("kafka", labels=["infra"], port_forwards=["9092:9092"])
k8s_resource("kafka-init-topics", labels=["infra"], resource_deps=["kafka"])
k8s_resource("keycloak", labels=["infra"], port_forwards=["8180:8080"])
k8s_yaml("infra/seed-models-job.yaml")

# --- ML Modules ---

modules = {
    "m1-health-stress": {
        "path": "../m1-health-stress",
        "training_port": 8001,
        "inference_port": 8002,
    },
    "m2-irrigation-wateruse": {
        "path": "../m2-irrigation-wateruse",
        "training_port": 8003,
        "inference_port": 8004,
    },
    "m3-soil-degradation": {
        "path": "../m3-soil-degradation",
        "training_port": 8005,
        "inference_port": 8006,
    },
}

for name, cfg in modules.items():
    mod_path = cfg["path"]

    training_image = name + "-training"

    docker_build(
        training_image,
        context=mod_path,
        dockerfile=mod_path + "/services/training/Dockerfile",
        live_update=[
            sync(mod_path + "/services/training/", "/app/"),
        ],
    )

    k8s_yaml(mod_path + "/k8s/configmap.yaml")
    k8s_yaml(mod_path + "/k8s/secrets.enc.yaml")

    k8s_yaml(blob("""
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}-training
  labels:
    app: {name}
    component: training
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {name}
      component: training
  template:
    metadata:
      labels:
        app: {name}
        component: training
    spec:
      containers:
        - name: training
          image: {image}
          ports:
            - containerPort: {port}
          envFrom:
            - configMapRef:
                name: {name}-config
            - secretRef:
                name: {name}-secrets
---
apiVersion: v1
kind: Service
metadata:
  name: {name}-training
spec:
  type: ClusterIP
  selector:
    app: {name}
    component: training
  ports:
    - port: {port}
      targetPort: {port}
""".format(
        name=name,
        image=training_image,
        port=cfg["training_port"],
    )))

    k8s_resource(
        name + "-training",
        labels=[name],
        port_forwards=[str(cfg["training_port"]) + ":" + str(cfg["training_port"])],
        resource_deps=["postgres", "minio"],
    )

    inference_image = name + "-inference"

    docker_build(
        inference_image,
        context=mod_path,
        dockerfile=mod_path + "/services/inference/Dockerfile",
        live_update=[
            sync(mod_path + "/services/inference/", "/app/"),
        ],
    )

    k8s_yaml(mod_path + "/k8s/deployment.yaml")
    k8s_yaml(mod_path + "/k8s/service.yaml")

    k8s_resource(
        name + "-inference",
        labels=[name],
        port_forwards=[str(cfg["inference_port"]) + ":" + str(cfg["inference_port"])],
        resource_deps=["postgres", "minio"],
    )

k8s_resource("seed-models", labels=["infra"],
    resource_deps=[
        "m1-health-stress-training", "m1-health-stress-inference",
        "m2-irrigation-wateruse-training", "m2-irrigation-wateruse-inference",
        "m3-soil-degradation-training", "m3-soil-degradation-inference",
    ])

# --- Backend ---

docker_build(
    "registry.local/aggrov2/backend",
    context="../backend",
    dockerfile="../backend/Dockerfile",
)

k8s_yaml("../backend/k8s/configmap.yaml")
k8s_yaml("../backend/k8s/secrets.enc.yaml")
k8s_yaml("../backend/k8s/deployment.yaml")
k8s_yaml("../backend/k8s/service.yaml")

k8s_resource("backend", labels=["backend"],
    port_forwards=["8080:8080"],
    resource_deps=["postgres", "minio", "kafka", "keycloak"])

# --- Ingestion Worker ---

docker_build(
    "ingestion-worker",
    context="../ingestion",
    dockerfile="../ingestion/Dockerfile",
    live_update=[
        sync("../ingestion/worker/", "/app/worker/"),
        sync("../ingestion/common/", "/app/common/"),
        sync("../ingestion/gee/", "/app/gee/"),
    ],
)

k8s_yaml("../ingestion/k8s/configmap.yaml")
k8s_yaml("../ingestion/k8s/secrets.enc.yaml")
k8s_yaml("../ingestion/k8s/worker-deployment.yaml")

k8s_resource("ingestion-worker", labels=["ingestion"],
    resource_deps=["postgres", "kafka", "minio"])

# --- Frontend ---

docker_build(
    "frontend",
    context="../frontend",
    dockerfile="../frontend/Dockerfile",
    live_update=[
        sync("../frontend/src/", "/usr/share/nginx/html/"),
    ],
)

k8s_yaml("../frontend/k8s/deployment.yaml")
k8s_yaml("../frontend/k8s/service.yaml")

k8s_resource("frontend", labels=["frontend"],
    port_forwards=["3000:3000"],
    resource_deps=["backend", "keycloak"])
