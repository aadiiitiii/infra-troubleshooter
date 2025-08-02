#!/bin/bash

set -e

echo "🚀 Starting Infra Auto-Troubleshooter (Fast Mode)"

# Cleanup function
cleanup() {
  echo ""
  echo "🧹 Cleaning up..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  pkill -f "python3 mcp_server.py" 2>/dev/null || true
  pkill -f "python3 agent.py" 2>/dev/null || true
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Kill old processes
echo "🔪 Killing old processes..."
pkill -f "kubectl port-forward" 2>/dev/null || true
pkill -f "python3 mcp_server.py" 2>/dev/null || true
pkill -f "python3 agent.py" 2>/dev/null || true
sleep 2

# Check dependencies
echo "🔍 Checking dependencies..."
command -v kubectl >/dev/null || { echo "❌ kubectl not found"; exit 1; }
command -v nc >/dev/null || { echo "❌ nc not found"; exit 1; }

# Install Python deps if needed
if ! python3 -c "import fastapi, uvicorn, requests" 2>/dev/null; then
    echo "📦 Installing Python deps..."
    pip3 install -r requirements.txt
fi

# Function to check if service exists
service_exists() {
    local svc=$1
    local ns=$2
    kubectl get svc $svc -n $ns >/dev/null 2>&1
}

# Function to start port-forward with timeout
start_port_forward() {
    local service=$1
    local namespace=$2
    local svc_name=$3
    local port=$4
    local timeout=${5:-10}
    
    if service_exists $svc_name $namespace; then
        echo "🔁 Starting $service port-forward..."
        kubectl port-forward svc/$svc_name -n $namespace $port:$port > ${service}.log 2>&1 &
        
        # Wait for port with timeout
        local count=0
        while ! nc -z localhost $port 2>/dev/null && [ $count -lt $timeout ]; do
            sleep 1
            count=$((count + 1))
        done
        
        if nc -z localhost $port 2>/dev/null; then
            echo "✅ $service ready ($port)"
            return 0
        else
            echo "⚠️ $service timeout ($port)"
            return 1
        fi
    else
        echo "⚠️ $service not found in cluster, skipping"
        return 1
    fi
}

echo ""
echo "📋 Checking available services..."
service_exists "vault" "vault" && echo "✅ Vault found" || echo "❌ Vault not found"
service_exists "consul-server" "consul" && echo "✅ Consul found" || echo "❌ Consul not found"
service_exists "elasticsearch-master" "elasticsearch" && echo "✅ Elasticsearch found" || echo "❌ Elasticsearch not found"

echo ""
echo "🔁 Starting port-forwards (parallel)..."

# Start all port-forwards in parallel with shorter timeouts
start_port_forward "vault" "vault" "vault" "8200" 15 &
start_port_forward "consul" "consul" "consul-server" "8500" 15 &
start_port_forward "elasticsearch" "elasticsearch" "elasticsearch-master" "9200" 15 &

# Wait for port-forwards to complete
wait

echo ""
echo "🚀 Starting MCP Server..."
python3 mcp_server.py > mcp_server.log 2>&1 &
MCP_PID=$!

# Wait for MCP Server with shorter timeout
echo "⏳ Waiting for MCP Server..."
timeout=15
while ! nc -z localhost 7070 2>/dev/null && [ $timeout -gt 0 ]; do
    sleep 1
    timeout=$((timeout - 1))
done

if nc -z localhost 7070 2>/dev/null; then
    echo "✅ MCP Server ready"
else
    echo "❌ MCP Server failed to start"
    echo "Last 5 lines of mcp_server.log:"
    tail -5 mcp_server.log 2>/dev/null || echo "No log found"
    exit 1
fi

echo ""
echo "🩺 Starting Health Agent..."
python3 agent.py > agent.log 2>&1 &
AGENT_PID=$!

echo ""
echo "🎉 Startup complete!"
echo "📊 Dashboard: http://localhost:7070/dashboard"
echo "⏱️ Total startup time: ~30-45 seconds"

echo ""
echo "📋 Service Status:"
nc -z localhost 8200 && echo "  ✅ Vault (8200)" || echo "  ❌ Vault (8200)"
nc -z localhost 8500 && echo "  ✅ Consul (8500)" || echo "  ❌ Consul (8500)"
nc -z localhost 9200 && echo "  ✅ Elasticsearch (9200)" || echo "  ❌ Elasticsearch (9200)"
nc -z localhost 7070 && echo "  ✅ MCP Server (7070)" || echo "  ❌ MCP Server (7070)"

echo ""
echo "Press Ctrl+C to stop. Monitoring every 30 seconds..."

# Simple monitoring loop
while true; do
    sleep 30
    if ! kill -0 $MCP_PID 2>/dev/null; then
        echo "❌ MCP Server died"
        exit 1
    fi
    if ! kill -0 $AGENT_PID 2>/dev/null; then
        echo "❌ Agent died" 
        exit 1
    fi
done
