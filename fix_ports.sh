#!/bin/bash

echo "🔧 Fixing Port-forwards After Remediation"
echo "========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to restart port-forward
restart_port_forward() {
    local service=$1
    local namespace=$2
    local svc_name=$3
    local port=$4
    
    echo -e "${BLUE}🔄 Restarting $service port-forward...${NC}"
    
    # Kill existing port-forwards for this service
    echo "  Killing existing $service port-forwards..."
    pkill -f "kubectl port-forward.*$svc_name.*$port" 2>/dev/null || true
    pkill -f "kubectl port-forward.*$port" 2>/dev/null || true
    sleep 3
    
    # Check if service exists
    echo "  Checking if service $svc_name exists in namespace $namespace..."
    if kubectl get svc $svc_name -n $namespace >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ Service found${NC}"
        
        # Start new port-forward
        echo "  Starting port-forward: kubectl port-forward svc/$svc_name -n $namespace $port:$port"
        kubectl port-forward svc/$svc_name -n $namespace $port:$port > ${service}.log 2>&1 &
        local pf_pid=$!
        
        # Wait for port to be available
        local timeout=15
        echo "  ⏳ Waiting for port $port to be ready..."
        while ! nc -z localhost $port 2>/dev/null; do
            sleep 1
            timeout=$((timeout - 1))
            if [ $timeout -eq 0 ]; then
                echo -e "  ${RED}❌ Port-forward failed to start after 15 seconds${NC}"
                echo "  Check the log: tail ${service}.log"
                return 1
            fi
            echo -n "."
        done
        
        echo ""
        echo -e "  ${GREEN}✅ $service port-forward restarted successfully (PID: $pf_pid)${NC}"
        return 0
    else
        echo -e "  ${RED}❌ Service $svc_name not found in namespace $namespace${NC}"
        return 1
    fi
}

# Function to find and restart Elasticsearch
fix_elasticsearch() {
    echo -e "${BLUE}🔍 Finding and fixing Elasticsearch...${NC}"
    
    # Try to find Elasticsearch service in common locations
    local es_configs=(
        "elasticsearch:elasticsearch-master"
        "elasticsearch:elasticsearch"
        "elasticsearch:elasticsearch-master"
        "elasticsearch:elasticsearch"
        "default:elasticsearch"
        "logging:elasticsearch"
    )
    
    for config in "${es_configs[@]}"; do
        local ns=$(echo $config | cut -d':' -f1)
        local svc=$(echo $config | cut -d':' -f2)
        
        echo "  Trying $ns/$svc..."
        if kubectl get svc $svc -n $ns >/dev/null 2>&1; then
            echo -e "  ${GREEN}✅ Found Elasticsearch: $svc in namespace $ns${NC}"
            restart_port_forward "elasticsearch" "$ns" "$svc" "9200"
            return $?
        fi
    done
    
    echo -e "  ${RED}❌ Elasticsearch service not found in any expected location${NC}"
    echo "  💡 Try: kubectl get svc -A | grep -i elastic"
    return 1
}

# Function to check port health
check_port_health() {
    local service=$1
    local port=$2
    local endpoint=$3
    
    if nc -z localhost $port 2>/dev/null; then
        echo -e "  Port $port: ${GREEN}✅ Open${NC}"
        
        # If endpoint provided, test it too
        if [ ! -z "$endpoint" ]; then
            if curl -s "$endpoint" >/dev/null 2>&1; then
                echo -e "  Endpoint: ${GREEN}✅ Responding${NC}"
            else
                echo -e "  Endpoint: ${YELLOW}⚠️ Port open but service not responding${NC}"
            fi
        fi
        return 0
    else
        echo -e "  Port $port: ${RED}❌ Closed${NC}"
        return 1
    fi
}

# Main execution
echo ""
echo "📋 Current port status:"
echo "======================="

# Check current port status
echo "Vault (8200):"
check_port_health "vault" "8200" "http://localhost:8200/v1/sys/health"

echo ""
echo "Consul (8500):"
check_port_health "consul" "8500" "http://localhost:8500/v1/status/leader"

echo ""
echo "Elasticsearch (9200):"
check_port_health "elasticsearch" "9200" "http://localhost:9200/_cluster/health"

echo ""
echo "📝 Current port-forward processes:"
ps aux | grep "kubectl port-forward" | grep -v grep | while read line; do
    echo "  $line"
done

echo ""
echo "🔧 Starting port-forward fixes..."
echo "================================="

# Fix Vault
echo ""
echo "1. Fixing Vault..."
if ! check_port_health "vault" "8200" >/dev/null 2>&1; then
    restart_port_forward "vault" "vault" "vault" "8200"
else
    echo -e "  ${GREEN}✅ Vault port-forward already working${NC}"
fi

# Fix Consul
echo ""
echo "2. Fixing Consul..."
if ! check_port_health "consul" "8500" >/dev/null 2>&1; then
    restart_port_forward "consul" "consul" "consul-server" "8500"
else
    echo -e "  ${GREEN}✅ Consul port-forward already working${NC}"
fi

# Fix Elasticsearch
echo ""
echo "3. Fixing Elasticsearch..."
if ! check_port_health "elasticsearch" "9200" >/dev/null 2>&1; then
    fix_elasticsearch
else
    echo -e "  ${GREEN}✅ Elasticsearch port-forward already working${NC}"
fi

echo ""
echo "⏳ Waiting 5 seconds for port-forwards to stabilize..."
sleep 5

echo ""
echo "🧪 Final port health check:"
echo "==========================="

all_good=true

echo "Vault (8200):"
if ! check_port_health "vault" "8200" "http://localhost:8200/v1/sys/health"; then
    all_good=false
fi

echo ""
echo "Consul (8500):"
if ! check_port_health "consul" "8500" "http://localhost:8500/v1/status/leader"; then
    all_good=false
fi

echo ""
echo "Elasticsearch (9200):"
if ! check_port_health "elasticsearch" "9200" "http://localhost:9200/_cluster/health"; then
    all_good=false
fi

echo ""
echo "📊 MCP Server (7070):"
if nc -z localhost 7070 2>/dev/null; then
    echo -e "  ${GREEN}✅ MCP Server accessible${NC}"
    if curl -s http://localhost:7070/health >/dev/null 2>&1; then
        echo -e "  ${GREEN}✅ MCP Server responding${NC}"
    else
        echo -e "  ${YELLOW}⚠️ MCP Server port open but not responding${NC}"
    fi
else
    echo -e "  ${RED}❌ MCP Server not accessible${NC}"
    echo "  💡 Try: python3 mcp_server.py > mcp_server.log 2>&1 &"
    all_good=false
fi

echo ""
echo "📈 Updated port-forward processes:"
ps aux | grep "kubectl port-forward" | grep -v grep | while read line; do
    echo "  $line"
done

echo ""
if [ "$all_good" = true ]; then
    echo -e "${GREEN}🎉 All port-forwards are working correctly!${NC}"
    echo ""
    echo "🌐 You can now access:"
    echo "  • Dashboard: http://localhost:7070/dashboard"
    echo "  • API Status: http://localhost:7070/api/status"
    echo "  • Vault: http://localhost:8200/v1/sys/health"
    echo "  • Consul: http://localhost:8500/v1/status/leader"
    echo "  • Elasticsearch: http://localhost:9200/_cluster/health"
else
    echo -e "${YELLOW}⚠️ Some port-forwards are still not working properly.${NC}"
    echo ""
    echo -e "${BLUE}💡 Troubleshooting steps:${NC}"
    echo "1. Check if services exist in Kubernetes:"
    echo "   kubectl get svc -n vault,consul,elasticsearch"
    echo ""
    echo "2. Check if pods are running:"
    echo "   kubectl get pods -n vault,consul,elasticsearch"
    echo ""
    echo "3. Check log files for errors:"
    echo "   tail -10 vault.log consul.log es.log"
    echo ""
    echo "4. Manually restart a specific service:"
    echo "   kubectl port-forward svc/vault -n vault 8200:8200 &"
    echo ""
    echo "5. Check for port conflicts:"
    echo "   netstat -tlnp | grep -E ':(8200|8500|9200|7070)'"
fi

echo ""
echo "✅ Port-forward fix complete!"
