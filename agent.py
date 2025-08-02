import requests
import time
import os

MCP_SERVER_URL = "http://localhost:7070"
CLUSTER_NAME = os.getenv("CLUSTER_NAME", "<your-cluster-name>")
ES_ENDPOINT = "http://localhost:9200/_cluster/health"
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "30"))  # seconds

def send_report(cluster, service, healthy, details="", consul_host="N/A"):
    payload = {
        "cluster": cluster,
        "service": service,
        "healthy": healthy,
        "details": details,
        "consul_host": consul_host
    }
    try:
        requests.post(f"{MCP_SERVER_URL}/report", json=payload, timeout=3)
        print(f"✅ Sent report for {service}: {'healthy' if healthy else 'unhealthy'}")
    except Exception as e:
        print(f"❌ Failed to send report for {service}: {e}")

def check_vault():
    try:
        resp = requests.get("http://localhost:8200/v1/sys/health", timeout=5)
        if resp.status_code == 200:
            return True, "Vault is responding normally"
        else:
            return False, f"Vault returned status code {resp.status_code}"
    except requests.exceptions.ConnectionError:
        return False, "Connection refused - Vault may be down"
    except requests.exceptions.Timeout:
        return False, "Request timeout - Vault may be slow"
    except Exception as e:
        return False, f"Vault check error: {str(e)}"

def check_consul():
    try:
        resp = requests.get("http://localhost:8500/v1/status/leader", timeout=5)
        if resp.status_code == 200 and resp.text.strip():
            leader = resp.text.strip().replace('"', '')
            return True, f"Consul leader: {leader}"
        else:
            return False, "No Consul leader found"
    except requests.exceptions.ConnectionError:
        return False, "Connection refused - Consul may be down"
    except requests.exceptions.Timeout:
        return False, "Request timeout - Consul may be slow"
    except Exception as e:
        return False, f"Consul check error: {str(e)}"

def check_elasticsearch():
    try:
        resp = requests.get(ES_ENDPOINT, timeout=5, verify=False)
        if resp.status_code == 200:
            data = resp.json()
            status = data.get('status', 'unknown')
            cluster_name = data.get('cluster_name', 'unknown')
            if status == 'green':
                return True, f"Elasticsearch cluster '{cluster_name}' is green"
            elif status == 'yellow':
                return False, f"Elasticsearch cluster '{cluster_name}' is yellow (degraded)"
            else:
                return False, f"Elasticsearch cluster '{cluster_name}' is {status}"
        else:
            return False, f"Elasticsearch returned status code {resp.status_code}"
    except requests.exceptions.ConnectionError:
        return False, "Connection refused - Elasticsearch may be down"
    except requests.exceptions.Timeout:
        return False, "Request timeout - Elasticsearch may be slow"
    except Exception as e:
        return False, f"Elasticsearch check error: {str(e)}"

def main():
    print(f"🩺 Starting Infrastructure Health Agent")
    print(f"📊 Reporting to: {MCP_SERVER_URL}")
    print(f"🔄 Check interval: {CHECK_INTERVAL} seconds")
    print(f"🏗️ Cluster: {CLUSTER_NAME}")
    print("")
    
    while True:
        try:
            # Check Vault
            vault_healthy, vault_details = check_vault()
            send_report(CLUSTER_NAME, "vault", vault_healthy, vault_details, "localhost:8200")

            # Check Consul
            consul_healthy, consul_details = check_consul()
            send_report(CLUSTER_NAME, "consul", consul_healthy, consul_details, "localhost:8500")

            # Check Elasticsearch
            es_healthy, es_details = check_elasticsearch()
            send_report(CLUSTER_NAME, "elasticsearch", es_healthy, es_details, "localhost:9200")

            print(f"🔄 Next check in {CHECK_INTERVAL} seconds...")
            time.sleep(CHECK_INTERVAL)
            
        except KeyboardInterrupt:
            print("\n🛑 Agent stopped by user")
            break
        except Exception as e:
            print(f"❌ Unexpected error in main loop: {e}")
            time.sleep(5)  # Short sleep before retrying

if __name__ == "__main__":
    main()
