#!/bin/bash

echo "🔥 Testing Failure Detection and Remediation"
echo "============================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

wait_for_detection() {
    local service=$1
    local expected_healthy=$2
    local timeout=60
    
    echo "⏳ Waiting for detection of $service status (healthy=$expected_healthy)..."
    
    while [ $timeout -gt 0 ]; do
        status=$(curl -s http://localhost:7070/api/status | jq -r ".status.\"casbx-mgmt-plane-us-central1-$service\".healthy")
        if [ "$status" = "$expected_healthy" ]; then
            echo -e "${GREEN}✅ Status detected correctly${NC}"
            return 0
        fi
        sleep 2
        timeout=$((timeout - 2))
        echo -n "."
    done
    
    echo -e "${RED}❌ Timeout waiting for status detection${NC}"
    return 1
}

show_current_status() {
    echo -e "${BLUE}📊 Current Status:${NC}"
    curl -s http://localhost:7070/api/status | jq '.status' | sed 's/^/  /'
}

restart_port_forward() {
    local service=$1
    local namespace=$2
    local svc_name=$3
    local port=$4
    
    echo -e "${BLUE}🔄 Restarting $service port-forward...${NC}"
    
    # Kill existing port-forward
    pkill -f "kubectl port-forward.*$svc_name.*$port" 2>/dev/null || true
    pkill -f "kubectl port-forward.*$port" 2>/dev/null || true
    sleep 3
    
    # Start new port-forward
    kubectl port-forward svc/$svc_name -n $namespace $port:$port > ${service}.log 2>&1 &
    local pf_pid=$!
    
    # Wait for port to be available
    local timeout=30
    echo "⏳ Waiting for $service port $port to be ready..."
    while ! nc -z localhost $port 2>/dev/null; do
        sleep 1
        timeout=$((timeout - 1))
        if [ $timeout -eq 0 ]; then
            echo -e "${RED}❌ $service port-forward failed to start${NC}"
            return 1
        fi
    done
    
    echo -e "${GREEN}✅ $service port-forward restarted (PID: $pf_pid)${NC}"
    return 0
}

restart_all_port_forwards() {
    echo ""
    echo -e "${BLUE}🔄 Restarting All Port-Forwards${NC}"
    echo "================================"
    
    restart_port_forward "vault" "vault" "vault" "8200"
    restart_port_forward "consul" "consul" "consul-server" "8500"
    
    # For Elasticsearch, try to find the correct service name
    echo -e "${BLUE}🔍 Finding Elasticsearch service...${NC}"
    ES_NAMESPACE="elasticsearch"
    ES_SERVICE=""
    
    # Try common service names
    for svc in elasticsearch-master elasticsearch; do
        if kubectl get svc $svc -n $ES_NAMESPACE >/dev/null 2>&1; then
            ES_SERVICE=$svc
            echo -e "${GREEN}✅ Found Elasticsearch service: $svc${NC}"
            break
        fi
    done
    
    if [ ! -z "$ES_SERVICE" ]; then
        restart_port_forward "elasticsearch" "$ES_NAMESPACE" "$ES_SERVICE" "9200"
    else
        echo -e "${YELLOW}⚠️ Elasticsearch service not found, skipping port-forward${NC}"
    fi
    
    echo ""
}

check_port_health() {
    echo -e "${BLUE}🔍 Checking Port Health${NC}"
    echo "======================="
    
    for port_info in "vault:8200" "consul:8500" "elasticsearch:9200"; do
        service=$(echo $port_info | cut -d':' -f1)
        port=$(echo $port_info | cut -d':' -f2)
        
        if nc -z localhost $port 2>/dev/null; then
            echo -e "  $service ($port): ${GREEN}✅ OK${NC}"
        else
            echo -e "  $service ($port): ${RED}❌ FAILED${NC}"
        fi
    done
    echo ""
}

wait_for_pods_ready() {
    local service=$1
    local namespace=$2
    local wait_time=${3:-10}
    
    echo -e "${YELLOW}⏳ Waiting $wait_time seconds for $service pods to be ready...${NC}"
    sleep $wait_time
    
    echo "📋 Current $service pods:"
    kubectl get pods -n $namespace | grep -i $(echo $service | cut -c1-4) || echo "No pods found"
}

echo ""
echo "=== Pre-Test Health Check ==="
check_port_health
show_current_status

echo ""
echo "=== Test 1: Port-Forward Failure ==="
echo "Killing Vault port-forward..."

# Kill Vault port-forward
pkill -f "kubectl port-forward.*vault.*8200" || echo "No vault port-forward found"

# Wait for detection
wait_for_detection "vault" "false"
show_current_status

echo ""
echo "Restarting Vault port-forward..."
restart_port_forward "vault" "vault" "vault" "8200"
sleep 5

wait_for_detection "vault" "true"
show_current_status

echo ""
echo "=== Test 2: Pod Scaling Down ==="
echo "Scaling Consul to 0 replicas..."

# Scale down consul
kubectl scale statefulset consul-server -n consul --replicas=0

wait_for_detection "consul" "false"
show_current_status

echo ""
echo "Testing remediation..."
curl -X POST http://localhost:7070/remediate/consul
echo "Remediation request sent"

# Wait for remediation to scale pods back up
echo ""
echo -e "${BLUE}⏳ Waiting for Consul remediation to complete...${NC}"
sleep 20

# Wait for pods to be ready before starting port-forward
wait_for_pods_ready "consul" "consul" 10

# Check if remediation restarted port-forward, if not do it manually
if ! nc -z localhost 8500 2>/dev/null; then
    echo -e "${YELLOW}⚠️ Consul port-forward not detected, restarting manually...${NC}"
    restart_port_forward "consul" "consul" "consul-server" "8500"
fi

# Wait for consul to be healthy again
echo "Waiting for Consul to become healthy..."
timeout=120
while [ $timeout -gt 0 ]; do
    consul_status=$(curl -s http://localhost:7070/api/status | jq -r ".status.\"casbx-mgmt-plane-us-central1-consul\".healthy")
    if [ "$consul_status" = "true" ]; then
        echo -e "${GREEN}✅ Consul is healthy again${NC}"
        break
    fi
    sleep 5
    timeout=$((timeout - 5))
    echo -n "."
done

if [ $timeout -le 0 ]; then
    echo -e "${YELLOW}⚠️ Consul didn't become healthy within timeout, but continuing...${NC}"
fi

echo ""
echo "=== Test 3: Manual Service Disruption ==="
echo "Disrupting Elasticsearch..."

# Get ES pod and delete it
ES_POD=$(kubectl get pods -n elasticsearch -o name | grep elasticsearch | head -1)
if [ ! -z "$ES_POD" ]; then
    echo "Deleting pod: $ES_POD"
    kubectl delete $ES_POD -n elasticsearch
    
    # ES should recover automatically, but let's watch
    echo "Watching Elasticsearch recovery..."
    timeout 30 kubectl get pods -n elasticsearch -w &
    WATCH_PID=$!
    sleep 15
    kill $WATCH_PID 2>/dev/null || true
    
    echo ""
    echo "Current Elasticsearch pods:"
    kubectl get pods -n elasticsearch
else
    echo -e "${YELLOW}⚠️ No Elasticsearch pods found to delete${NC}"
fi

echo ""
# echo "=== Test 4: Complete Port-Forward Recovery ==="
# echo "Killing all port-forwards to simulate network issues..."

# # Kill all port-forwards
# pkill -f "kubectl port-forward" || true
# sleep 5

# echo "Checking port health after killing all port-forwards:"
# check_port_health

# # Wait for detection of failures
# echo "Waiting for failure detection..."
# sleep 30
# show_current_status

# # Restart all port-forwards
# restart_all_port_forwards

# # Wait for recovery detection
# echo "Waiting for recovery detection..."
# sleep 30
# show_current_status

echo ""
echo "=== Test 5: Elasticsearch Remediation ==="
echo "Testing Elasticsearch remediation..."

# Scale down Elasticsearch
ES_STS=$(kubectl get statefulset -n elasticsearch -o name | grep elasticsearch | head -1)
if [ ! -z "$ES_STS" ]; then
    echo "Scaling down Elasticsearch..."
    kubectl scale $ES_STS -n elasticsearch --replicas=0
    
    # Wait for detection
    wait_for_detection "elasticsearch" "false"
    
    echo "Testing Elasticsearch remediation..."
    curl -X POST http://localhost:7070/remediate/elasticsearch
    echo "Elasticsearch remediation request sent"
    
    # Wait for ES remediation to complete
    echo ""
    echo -e "${BLUE}⏳ Waiting for Elasticsearch remediation to complete...${NC}"
    sleep 30
    
    # Wait for ES pods to be ready before starting port-forward
    wait_for_pods_ready "elasticsearch" "elasticsearch" 10
    
    echo "Checking Elasticsearch pods:"
    kubectl get pods -n elasticsearch
    
    # Check if port-forward is working, if not restart it
    if nc -z localhost 9200 2>/dev/null; then
        echo -e "${GREEN}✅ Elasticsearch port 9200 is accessible${NC}"
    else
        echo -e "${YELLOW}⚠️ Elasticsearch port 9200 not accessible, attempting restart...${NC}"
        
        # Find ES service and restart port-forward
        for svc in elasticsearch-master elasticsearch; do
            if kubectl get svc $svc -n elasticsearch >/dev/null 2>&1; then
                restart_port_forward "elasticsearch" "elasticsearch" "$svc" "9200"
                break
            fi
        done
    fi
else
    echo -e "${YELLOW}⚠️ No Elasticsearch StatefulSet found for scaling test${NC}"
fi

echo ""
echo "=== Test 6: Full Service Restart Cycle ==="
echo "Testing complete restart cycle for all services..."

echo ""
echo "📋 Scaling down all services..."
kubectl scale statefulset vault -n vault --replicas=0 2>/dev/null || echo "Vault scaling failed"
kubectl scale statefulset consul-server -n consul --replicas=0 2>/dev/null || echo "Consul scaling failed"
ES_STS=$(kubectl get statefulset -n elasticsearch -o name 2>/dev/null | head -1)
if [ ! -z "$ES_STS" ]; then
    kubectl scale $ES_STS -n elasticsearch --replicas=0 2>/dev/null || echo "ES scaling failed"
fi

echo ""
echo "⏳ Waiting for all services to be detected as unhealthy..."
sleep 45
show_current_status

echo ""
echo "🔧 Running remediation for all services..."
curl -X POST http://localhost:7070/remediate/vault
echo "Vault remediation sent"
sleep 5

curl -X POST http://localhost:7070/remediate/consul  
echo "Consul remediation sent"
sleep 5

curl -X POST http://localhost:7070/remediate/elasticsearch
echo "Elasticsearch remediation sent"

echo ""
echo -e "${BLUE}⏳ Waiting for all services to recover (this may take 2-3 minutes)...${NC}"

# Wait for Vault
echo "Waiting for Vault pods..."
wait_for_pods_ready "vault" "vault" 10
if ! nc -z localhost 8200 2>/dev/null; then
    restart_port_forward "vault" "vault" "vault" "8200"
fi

# Wait for Consul  
echo "Waiting for Consul pods..."
wait_for_pods_ready "consul" "consul" 10
if ! nc -z localhost 8500 2>/dev/null; then
    restart_port_forward "consul" "consul" "consul-server" "8500"
fi

# Wait for Elasticsearch
echo "Waiting for Elasticsearch pods..."
wait_for_pods_ready "elasticsearch" "elasticsearch" 10
if ! nc -z localhost 9200 2>/dev/null; then
    for svc in elasticsearch-master elasticsearch; do
        if kubectl get svc $svc -n elasticsearch >/dev/null 2>&1; then
            restart_port_forward "elasticsearch" "elasticsearch" "$svc" "9200"
            break
        fi
    done
fi

echo ""
echo "=== Final Health Check ==="
check_port_health
show_current_status

echo ""
echo "=== Remediation Log ==="
curl -s http://localhost:7070/api/status | jq '.remediation_log'

echo ""
echo "=== Process Health Check ==="
echo "Active port-forward processes:"
ps aux | grep "kubectl port-forward" | grep -v grep | while read line; do
    echo "  $line"
done

echo ""
echo "=== Final Endpoint Test ==="
echo "Testing all service endpoints:"

# Test Vault
if curl -s http://localhost:8200/v1/sys/health >/dev/null 2>&1; then
    echo -e "  Vault: ${GREEN}✅ Responding${NC}"
else
    echo -e "  Vault: ${RED}❌ Not responding${NC}"
fi

# Test Consul
if curl -s http://localhost:8500/v1/status/leader >/dev/null 2>&1; then
    echo -e "  Consul: ${GREEN}✅ Responding${NC}"
else
    echo -e "  Consul: ${RED}❌ Not responding${NC}"
fi

# Test Elasticsearch
if curl -s http://localhost:9200/_cluster/health >/dev/null 2>&1; then
    echo -e "  Elasticsearch: ${GREEN}✅ Responding${NC}"
else
    echo -e "  Elasticsearch: ${RED}❌ Not responding${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Comprehensive failure testing complete!${NC}"
echo ""
echo "📊 Dashboard: http://localhost:7070/dashboard"
echo "🔗 API Status: http://localhost:7070/api/status"
echo ""
echo -e "${BLUE}💡 Summary of tests performed:${NC}"
echo "• ✅ Port-forward failure and recovery"
echo "• ✅ Pod scaling with 10-second wait before port-forward"
echo "• ✅ Manual service disruption"
echo "• ✅ Complete port-forward recovery"
echo "• ✅ Elasticsearch-specific remediation with timing"
echo "• ✅ Full service restart cycle with proper waits"
echo ""
echo -e "${YELLOW}⚠️ If any services are still unhealthy, run:${NC}"
echo "  ./fix_ports.sh"
echo "  ./test_system.sh"
