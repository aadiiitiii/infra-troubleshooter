#!/bin/bash

echo "🧪 Testing Infra Auto-Troubleshooter System"
echo "==========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

test_passed=0
test_total=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    test_total=$((test_total + 1))
    echo -n "Testing $test_name... "
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ PASS${NC}"
        test_passed=$((test_passed + 1))
    else
        echo -e "${RED}❌ FAIL${NC}"
    fi
}

echo ""
echo "1. Port Connectivity Tests"
echo "-------------------------"
run_test "Vault (8200)" "nc -z localhost 8200"
run_test "Consul (8500)" "nc -z localhost 8500"
run_test "Elasticsearch (9200)" "nc -z localhost 9200"
run_test "MCP Server (7070)" "nc -z localhost 7070"

echo ""
echo "2. API Endpoint Tests"
echo "--------------------"
run_test "Root endpoint" "curl -s http://localhost:7070/ | grep -q message"
run_test "Health endpoint" "curl -s http://localhost:7070/health | grep -q status"
run_test "API Status endpoint" "curl -s http://localhost:7070/api/status | grep -q cluster"
run_test "Dashboard endpoint" "curl -s http://localhost:7070/dashboard | grep -q title"

echo ""
echo "3. Service Health Tests"
echo "----------------------"
run_test "Vault health" "curl -s http://localhost:8200/v1/sys/health"
run_test "Consul leader" "curl -s http://localhost:8500/v1/status/leader | grep -q :"
run_test "Elasticsearch health" "curl -s http://localhost:9200/_cluster/health | grep -q status"

echo ""
echo "4. Process Tests"
echo "---------------"
run_test "Vault port-forward" "pgrep -f 'kubectl port-forward.*vault.*8200'"
run_test "Consul port-forward" "pgrep -f 'kubectl port-forward.*consul.*8500'"
run_test "ES port-forward" "pgrep -f 'kubectl port-forward.*elasticsearch.*9200'"
run_test "MCP Server process" "pgrep -f 'python3 mcp_server.py'"
run_test "Agent process" "pgrep -f 'python3 agent.py'"

echo ""
echo "5. Log File Tests"
echo "----------------"
run_test "Vault log exists" "test -f vault.log"
run_test "Consul log exists" "test -f consul.log"
run_test "ES log exists" "test -f es.log"
run_test "MCP Server log exists" "test -f mcp_server.log"
run_test "Agent log exists" "test -f agent.log"

echo ""
echo "6. Detailed Service Information"
echo "------------------------------"

echo -e "${BLUE}📊 Current API Status:${NC}"
curl -s http://localhost:7070/api/status 2>/dev/null | jq '.' 2>/dev/null || echo "❌ API Status failed or jq not available"

echo ""
echo -e "${BLUE}🔍 Process Details:${NC}"
echo "Port-forward processes:"
ps aux | grep "kubectl port-forward" | grep -v grep | while read line; do
    echo "  $line"
done

echo ""
echo "Python processes:"
ps aux | grep -E "(mcp_server|agent)" | grep -v grep | while read line; do
    echo "  $line"
done

echo ""
echo -e "${BLUE}📋 Log File Sizes:${NC}"
for log in vault.log consul.log es.log mcp_server.log agent.log; do
    if [ -f "$log" ]; then
        size=$(wc -l < "$log")
        echo "  $log: $size lines"
    else
        echo "  $log: Not found"
    fi
done

echo ""
echo -e "${BLUE}🔗 Port Status:${NC}"
for port in 8200 8500 9200 7070; do
    if nc -z localhost $port 2>/dev/null; then
        echo -e "  Port $port: ${GREEN}✅ Open${NC}"
    else
        echo -e "  Port $port: ${RED}❌ Closed${NC}"
    fi
done

echo ""
echo "==========================================="
echo -e "Test Results: ${GREEN}$test_passed${NC}/${test_total} tests passed"

if [ $test_passed -eq $test_total ]; then
    echo -e "${GREEN}🎉 All tests passed! System is working correctly.${NC}"
    echo ""
    echo "🌐 Dashboard: http://localhost:7070/dashboard"
    echo "📊 API Status: http://localhost:7070/api/status"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "1. Open the dashboard in your browser"
    echo "2. Wait 30-60 seconds for monitoring data to appear"
    echo "3. Run './test_failures.sh' to test failure scenarios"
    
elif [ $test_passed -gt $((test_total * 2 / 3)) ]; then
    echo -e "${YELLOW}⚠️ Most tests passed, but some issues detected.${NC}"
    echo ""
    echo "The system might still be starting up. Wait a moment and try again."
    
else
    echo -e "${RED}❌ Multiple tests failed. System may not be working correctly.${NC}"
    echo ""
    echo -e "${YELLOW}Troubleshooting steps:${NC}"
    echo "1. Check if run_all.sh is still running"
    echo "2. Look at recent log entries:"
    echo "   tail -10 mcp_server.log"
    echo "   tail -10 agent.log"
    echo "3. Verify Kubernetes services exist:"
    echo "   kubectl get svc -n vault,consul,elasticsearch"
    echo "4. Check for port conflicts:"
    echo "   netstat -tlnp | grep -E ':(7070|8200|8500|9200)'"
fi

echo ""
echo -e "${BLUE}💡 Quick checks:${NC}"
echo "• Monitor status: curl -s http://localhost:7070/api/status | jq '.status'"
echo "• View logs: tail -f agent.log"
echo "• Kill a service: pkill -f 'kubectl port-forward.*vault.*8200'"
echo "• Test remediation: curl -X POST http://localhost:7070/remediate/vault"
