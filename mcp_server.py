from fastapi import FastAPI, Request, BackgroundTasks
from fastapi.templating import Jinja2Templates
from fastapi.responses import JSONResponse
import subprocess
import signal
import psutil
from typing import Dict, Tuple, Optional
import os
import logging
import asyncio
import time

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()
templates = Jinja2Templates(directory="templates")

# In-memory stores
status: Dict[str, Dict] = {}
remediation_log = []

CLUSTER_NAME = os.getenv("CLUSTER_NAME", "casbx-mgmt-plane-us-central1")

# Port-forward mapping
PORT_FORWARDS = {
    "vault": {"namespace": "vault", "service": "vault", "port": 8200},
    "consul": {"namespace": "consul", "service": "consul-server", "port": 8500},
    "elasticsearch": {"namespace": "elasticsearch", "service": "elasticsearch-master", "port": 9200}
}

def find_elasticsearch_resources() -> Tuple[Optional[str], Optional[str], Optional[str]]:
    """Dynamically find Elasticsearch StatefulSet and Service with retries"""
    
    # Possible namespace and resource name combinations
    search_configs = [
        ("elasticsearch", "elasticsearch-master", "elasticsearch-master"),
        ("elasticsearch", "elasticsearch", "elasticsearch"),
        ("elasticsearch", "elasticsearch-master", "elasticsearch"),  # Mixed names
        ("elasticsearch", "elasticsearch-master", "elasticsearch-master"),
        ("default", "elasticsearch", "elasticsearch"),
        ("logging", "elasticsearch", "elasticsearch"),
    ]
    
    # Try multiple times with delays to handle fast pod creation
    for attempt in range(3):
        logger.info(f"Elasticsearch detection attempt {attempt + 1}/3")
        
        for namespace, sts_name, svc_name in search_configs:
            try:
                logger.debug(f"Checking {namespace}/{sts_name}")
                
                # Check if namespace exists first
                ns_result = subprocess.run(
                    ["kubectl", "get", "namespace", namespace],
                    capture_output=True, text=True, timeout=5
                )
                
                if ns_result.returncode != 0:
                    logger.debug(f"Namespace {namespace} not found")
                    continue
                
                # Check if StatefulSet exists
                sts_result = subprocess.run(
                    ["kubectl", "get", "statefulset", sts_name, "-n", namespace],
                    capture_output=True, text=True, timeout=5
                )
                
                if sts_result.returncode == 0:
                    logger.info(f"Found StatefulSet: {sts_name} in namespace {namespace}")
                    
                    # Now find the corresponding service
                    # Try the exact service name first
                    svc_result = subprocess.run(
                        ["kubectl", "get", "service", svc_name, "-n", namespace],
                        capture_output=True, text=True, timeout=5
                    )
                    
                    if svc_result.returncode == 0:
                        logger.info(f"Found Service: {svc_name} in namespace {namespace}")
                        return namespace, sts_name, svc_name
                    else:
                        # If exact service name not found, try to find any elasticsearch service
                        all_svc_result = subprocess.run(
                            ["kubectl", "get", "svc", "-n", namespace, "-o", "name"],
                            capture_output=True, text=True, timeout=5
                        )
                        
                        if all_svc_result.returncode == 0:
                            for line in all_svc_result.stdout.strip().split('\n'):
                                service_name = line.replace('service/', '')
                                if 'elasticsearch' in service_name.lower():
                                    logger.info(f"Found Elasticsearch service: {service_name} in namespace {namespace}")
                                    return namespace, sts_name, service_name
                        
                        # If no service found, use the StatefulSet name as fallback
                        logger.warning(f"No service found for {sts_name}, will use StatefulSet name")
                        return namespace, sts_name, sts_name
                        
            except Exception as e:
                logger.debug(f"Error checking {namespace}/{sts_name}: {e}")
                continue
        
        # Wait before next attempt
        if attempt < 2:
            logger.info("Waiting 5 seconds before next detection attempt...")
            time.sleep(5)
    
    logger.warning("Elasticsearch StatefulSet/Service not found in any expected location after all attempts")
    return None, None, None

@app.get("/")
async def root():
    return {"message": "MCP Infra Auto-Troubleshooter server running", "cluster": CLUSTER_NAME}

@app.get("/health")
async def health():
    return {"status": "healthy", "services_monitored": len(status)}

@app.get("/dashboard")
async def dashboard(request: Request):
    return templates.TemplateResponse("dashboard.html", {
        "request": request,
        "status": status,
        "remediation_log": remediation_log
    })

@app.post("/report")
async def receive_report(report: dict):
    key = f"{report['cluster']}-{report['service']}"
    status[key] = {
        "healthy": report.get("healthy", False),
        "details": report.get("details", ""),
        "consul_host": report.get("consul_host", "N/A")
    }
    logger.info(f"Received report for {key}: {'healthy' if report.get('healthy') else 'unhealthy'}")
    return {"message": "Report received", "key": key}

@app.get("/api/status")
async def get_status():
    """API endpoint to get current status"""
    return {
        "cluster": CLUSTER_NAME,
        "status": status, 
        "remediation_log": remediation_log,
        "total_services": len(status),
        "healthy_services": sum(1 for s in status.values() if s.get("healthy", False))
    }

@app.post("/remediate/{service}")
async def remediate_service(service: str, background_tasks: BackgroundTasks):
    logger.info(f"Starting remediation for service: {service}")
    background_tasks.add_task(remediate, service)
    return {"message": f"Remediation started for {service}", "service": service}

def get_statefulset_replicas(name: str, namespace: str) -> int:
    """Get current replica count for a StatefulSet"""
    try:
        result = subprocess.run(
            ["kubectl", "get", "statefulset", name, "-n", namespace, "-o", "jsonpath={.spec.replicas}"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return int(result.stdout.strip())
        return 0
    except Exception as e:
        logger.error(f"Error getting replicas for {name}: {e}")
        return 0

def scale_statefulset(name: str, namespace: str, replicas: int) -> bool:
    """Scale a StatefulSet to specified replicas"""
    try:
        result = subprocess.run(
            ["kubectl", "scale", "statefulset", name, "-n", namespace, f"--replicas={replicas}"],
            check=True, capture_output=True, text=True, timeout=30
        )
        logger.info(f"Scaled {name} in {namespace} to {replicas} replicas: {result.stdout.strip()}")
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Error scaling {name}: {e.stderr.strip() if e.stderr else str(e)}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error scaling {name}: {e}")
        return False

def kill_port_forward(service: str):
    """Kill existing port-forward for a service"""
    try:
        port = PORT_FORWARDS[service]["port"]
        # Kill by port pattern
        result = subprocess.run(
            ["pkill", "-f", f"kubectl port-forward.*{port}"],
            capture_output=True, text=True
        )
        logger.info(f"Killed existing port-forward for {service} on port {port}")
        time.sleep(2)  # Give it time to die
    except Exception as e:
        logger.error(f"Error killing port-forward for {service}: {e}")

def start_port_forward(service: str, namespace: str = None, svc_name: str = None):
    """Start port-forward for a service"""
    try:
        # Use provided values or defaults
        if namespace and svc_name:
            ns = namespace
            service_name = svc_name
        else:
            config = PORT_FORWARDS[service]
            ns = config["namespace"]
            service_name = config["service"]
        
        port = PORT_FORWARDS[service]["port"]
        
        # Kill any existing port-forward first
        kill_port_forward(service)
        
        # Start new port-forward
        logfile = f"{service}.log"
        cmd = [
            "kubectl", "port-forward", f"svc/{service_name}", 
            f"{port}:{port}", "-n", ns
        ]
        
        logger.info(f"Starting port-forward: {' '.join(cmd)}")
        
        with open(logfile, "a") as f:
            process = subprocess.Popen(cmd, stdout=f, stderr=f)
        
        # Wait a moment to see if it starts successfully
        time.sleep(3)
        
        # Check if the process is still running
        if process.poll() is None:
            logger.info(f"Started port-forward for {service} on port {port} (PID: {process.pid})")
            return True
        else:
            logger.error(f"Port-forward for {service} failed to start")
            return False
        
    except Exception as e:
        logger.error(f"Error starting port-forward for {service}: {e}")
        return False

async def remediate(service: str):
    try:
        logger.info(f"Executing remediation for {service}")
        
        if service == "vault":
            namespace = "vault"
            statefulset_name = "vault"
            service_name = "vault"
            default_replicas = 1
            
        elif service == "consul":
            namespace = "consul"
            statefulset_name = "consul-server"
            service_name = "consul-server"
            default_replicas = 3
            
        elif service == "elasticsearch":
            logger.info("Starting Elasticsearch resource detection...")
            
            # First, let's see what we have in the elasticsearch namespace
            logger.info("Listing all resources in elasticsearch namespace:")
            try:
                all_resources = subprocess.run(
                    ["kubectl", "get", "all", "-n", "elasticsearch"],
                    capture_output=True, text=True, timeout=10
                )
                if all_resources.returncode == 0:
                    logger.info(f"Resources in elasticsearch namespace:\n{all_resources.stdout}")
                else:
                    logger.warning("No resources found in elasticsearch namespace or namespace doesn't exist")
            except Exception as e:
                logger.error(f"Error listing elasticsearch resources: {e}")
            
            # Try dynamic detection
            namespace, statefulset_name, service_name = find_elasticsearch_resources()
            default_replicas = 3
            
            if not namespace or not statefulset_name:
                # Last resort: try common combinations even if detection failed
                logger.warning("Dynamic detection failed, trying common patterns...")
                
                common_patterns = [
                    ("elasticsearch", "elasticsearch-master"),
                    ("elasticsearch", "elasticsearch"),
                    ("elasticsearch", "elasticsearch-master"),
                ]
                
                for ns, sts in common_patterns:
                    try:
                        check = subprocess.run(
                            ["kubectl", "get", "statefulset", sts, "-n", ns],
                            capture_output=True, text=True, timeout=5
                        )
                        if check.returncode == 0:
                            namespace = ns
                            statefulset_name = sts
                            service_name = sts  # Use same name for service
                            logger.info(f"Found Elasticsearch with pattern: {ns}/{sts}")
                            break
                    except:
                        continue
                
                if not namespace:
                    # Give detailed error with what we tried
                    error_details = "Tried these combinations:\n"
                    for ns, sts in common_patterns:
                        error_details += f"  - {ns}/{sts}\n"
                    raise Exception(f"Elasticsearch not found. {error_details}Run 'kubectl get statefulset -A | grep -i elastic' to find it manually.")
                
        else:
            remediation_log.append({
                "cluster": CLUSTER_NAME,
                "service": service,
                "status": "failed",
                "message": f"No remediation implemented for service '{service}'"
            })
            logger.warning(f"No remediation available for service: {service}")
            return

        logger.info(f"Using configuration: namespace={namespace}, statefulset={statefulset_name}, service={service_name}")

        # Check if StatefulSet exists
        check_sts = subprocess.run(
            ["kubectl", "get", "statefulset", statefulset_name, "-n", namespace],
            capture_output=True, text=True, timeout=10
        )
        
        if check_sts.returncode != 0:
            raise Exception(f"StatefulSet {statefulset_name} not found in namespace {namespace}. Error: {check_sts.stderr.strip()}")

        # Check current replica count
        current_replicas = get_statefulset_replicas(statefulset_name, namespace)
        logger.info(f"{service} current replicas: {current_replicas}")
        
        # If scaled to 0, scale back up first
        if current_replicas == 0:
            logger.info(f"{service} is scaled to 0, scaling back up to {default_replicas}")
            if not scale_statefulset(statefulset_name, namespace, default_replicas):
                raise Exception(f"Failed to scale {service} back up")
            
            # Wait for pods to start - longer for Elasticsearch
            wait_time = 60 if service == "elasticsearch" else 30
            logger.info(f"Waiting {wait_time} seconds for {service} pods to start...")
            await asyncio.sleep(wait_time)
        
        # Now perform rollout restart
        logger.info(f"Performing rollout restart for {service}")
        result = subprocess.run(
            ["kubectl", "rollout", "restart", f"statefulset/{statefulset_name}", "-n", namespace], 
            check=True, capture_output=True, text=True, timeout=60
        )
        
        # Wait for rollout to complete - longer for Elasticsearch
        rollout_wait = 90 if service == "elasticsearch" else 30
        logger.info(f"Waiting {rollout_wait} seconds for {service} rollout to complete...")
        await asyncio.sleep(rollout_wait)
        
        # Wait for service to be ready
        logger.info(f"Checking if {service} service is ready...")
        for i in range(6):  # 1 minute max
            try:
                check_svc = subprocess.run(
                    ["kubectl", "get", "svc", service_name, "-n", namespace],
                    capture_output=True, text=True, timeout=5
                )
                if check_svc.returncode == 0:
                    logger.info(f"Service {service_name} is ready")
                    break
                else:
                    logger.debug(f"Service check attempt {i+1}/6 failed")
            except:
                pass
            await asyncio.sleep(10)
        
        # Restart port-forward
        logger.info(f"Restarting port-forward for {service}")
        if start_port_forward(service, namespace, service_name):
            port_msg = f" Port-forward restarted on port {PORT_FORWARDS[service]['port']}."
        else:
            port_msg = " Warning: Failed to restart port-forward - you may need to restart manually."
        
        # Log success
        message = f"Remediation completed for {service}."
        if current_replicas == 0:
            message += f" Scaled from 0 to {default_replicas} replicas and restarted."
        else:
            message += " Performed rolling restart."
        message += port_msg
        message += f" Found in namespace: {namespace} as StatefulSet: {statefulset_name}."
        
        remediation_log.append({
            "cluster": CLUSTER_NAME,
            "service": service,
            "status": "success",
            "message": message
        })
        logger.info(f"Successfully remediated {service}")
        
    except subprocess.CalledProcessError as e:
        error_msg = f"Kubectl command failed: {e.stderr.strip() if e.stderr else str(e)}"
        remediation_log.append({
            "cluster": CLUSTER_NAME,
            "service": service,
            "status": "failed",
            "message": error_msg
        })
        logger.error(f"Remediation failed for {service}: {error_msg}")
    except subprocess.TimeoutExpired:
        error_msg = "Remediation command timed out"
        remediation_log.append({
            "cluster": CLUSTER_NAME,
            "service": service,
            "status": "failed",
            "message": error_msg
        })
        logger.error(f"Remediation timed out for {service}")
    except Exception as e:
        error_msg = f"Unexpected error during remediation: {str(e)}"
        remediation_log.append({
            "cluster": CLUSTER_NAME,
            "service": service,
            "status": "failed",
            "message": error_msg
        })
        logger.error(f"Unexpected error during remediation of {service}: {error_msg}")

if __name__ == "__main__":
    import uvicorn
    print(f"Starting MCP Server on http://0.0.0.0:7070")
    print(f"Dashboard: http://localhost:7070/dashboard")
    print(f"API Status: http://localhost:7070/api/status")
    uvicorn.run(app, host="0.0.0.0", port=7070, log_level="info")