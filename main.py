import requests

MCP_SERVER_URL = "http://localhost:7070"
CLUSTER_NAME = "casbx-mgmt-plane-us-central1"
ES_ENDPOINT = "http://localhost:9200/es1/_cluster/health"

def send_report(cluster, service, healthy, details=""):
    payload = {
        "cluster": cluster,
        "service": service,
        "healthy": healthy,
        "details": details,
    }
    try:
        requests.post(f"{MCP_SERVER_URL}/report", json=payload, timeout=3)
    except Exception as e:
        print(f"Failed to send report for {service}: {e}")

def check_vault():
    try:
        resp = requests.get("http://localhost:8200/v1/sys/health", timeout=5)
        return resp.status_code == 200
    except Exception as e:
        print(f"Vault check error: {e}")
        return False

def check_consul():
    try:
        resp = requests.get("http://localhost:8500/v1/status/leader", timeout=5)
        return resp.status_code == 200 and "8300" in resp.text
    except Exception as e:
        print(f"Consul check error: {e}")
        return False

def check_elasticsearch():
    try:
        resp = requests.get(ES_ENDPOINT, timeout=5, verify=False)
        return resp.status_code == 200 and '"status"' in resp.text
    except Exception as e:
        print(f"Elasticsearch check error: {e}")
        return False

def main():
    vault_healthy = check_vault()
    print(f"Vault healthy: {vault_healthy}")
    send_report(CLUSTER_NAME, "vault", vault_healthy)

    consul_healthy = check_consul()
    print(f"Consul healthy: {consul_healthy}")
    send_report(CLUSTER_NAME, "consul", consul_healthy)

    es_healthy = check_elasticsearch()
    print(f"Elasticsearch healthy: {es_healthy}")
    send_report(CLUSTER_NAME, "elasticsearch", es_healthy)

if __name__ == "__main__":
    main()
