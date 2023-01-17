resource "kubernetes_secret_v1" "registry-secret" {
    metadata {
        name = "f5demos-registry-secret"
        namespace = var.namespace
        annotations = {}
    }
    data = {
        ".dockerconfigjson" = base64decode(var.registry_config_json)
    }
    type = "kubernetes.io/dockerconfigjson"
}