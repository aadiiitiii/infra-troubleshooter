# Infra Auto-Troubleshooter 🚀

A comprehensive **Infrastructure Monitoring and Auto-Remediation System** built for Kubernetes environments. This tool automatically detects service failures, provides real-time monitoring through a web dashboard, and can automatically restart failed services.

## 🎯 Overview

The Infra Auto-Troubleshooter monitors critical infrastructure services (Vault, Consul, Elasticsearch) running in Kubernetes and provides:

- **Real-time health monitoring** with visual dashboard
- **Automatic failure detection** via continuous health checks
- **Auto-remediation capabilities** to restart failed services
- **Port-forward management** for local access to cluster services
- **Comprehensive failure testing** to validate system resilience

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Web Dashboard │    │   MCP Server    │    │  Health Agent   │
│  (Bootstrap UI) │◄───┤  (FastAPI)      │◄───┤  (Monitoring)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                              │                         │
                              ▼                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                           │
│  ┌─────────┐    ┌─────────┐    ┌─────────────────┐              │
│  │  Vault  │    │ Consul  │    │ Elasticsearch   │              │
│  │ (8200)  │    │ (8500)  │    │     (9200)      │              │
│  └─────────┘    └─────────┘    └─────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │
                    Port-forwards for local access
```

## 📁 Project Structure

```
infra-troubleshooter/
├── 📄 README.md                # This file
├── 📄 requirements.txt         # Python dependencies
├── 🐍 mcp_server.py            # FastAPI server (monitoring & remediation)
├── 🐍 agent.py                 # Health monitoring agent
├── 🐍 main.py                  # Legacy monitoring script
├── 🎨 templates/
│   └── dashboard.html          # Web dashboard UI
├── 🚀 run_all.sh               # Main startup script
├── 🧪 test_system.sh           # System health verification
├── 🔥 test_failures.sh         # Comprehensive failure testing
├── 🔧 fix_ports.sh             # Port-forward troubleshooting
```

## 🚀 Quick Start

### Prerequisites
- **Kubernetes cluster** with kubectl configured
- **Python 3.7+** with pip
- **netcat (nc)** for port checking
- **curl** and **jq** for API testing
- Services deployed: Vault, Consul, Elasticsearch

### 1. Clone and Setup
```bash
cd AI_workspace/saas-security-hackathon/null-pointer-hackathon/infra-troubleshooter
pip3 install -r requirements.txt
```

### 2. Start the System
```bash
# Make scripts executable
chmod +x *.sh

# Start all services (recommended)
./run_all.sh

```

### 3. Access the Dashboard
Open your browser to: **http://localhost:7070/dashboard**

### 4. Verify Everything Works
```bash
# In a new terminal
./test_system.sh
```

## 🎮 Usage Guide

### 🌐 Web Dashboard Features

The dashboard provides:
- **Service Health Status** - Real-time status of all monitored services
- **Auto-refresh** - Configurable auto-refresh (preserves state across reloads)
- **Remediation Buttons** - One-click service restart for unhealthy services
- **Remediation Log** - History of all remediation actions
- **Detailed Status** - Hover over details for comprehensive health information

### 📊 API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Root endpoint with system info |
| `/health` | GET | Server health check |
| `/dashboard` | GET | Web dashboard UI |
| `/api/status` | GET | Complete system status (JSON) |
| `/report` | POST | Submit health report (used by agent) |
| `/remediate/{service}` | POST | Trigger service remediation |

### 🔧 Command Line Tools

#### System Health Check
```bash
./test_system.sh
# Verifies all components are running correctly
```

#### Port-Forward Troubleshooting
```bash
./fix_ports.sh
# Restarts broken port-forwards after pod restarts
```

#### Comprehensive Testing
```bash
./test_failures.sh
# Simulates various failure scenarios and tests recovery
```

## 🧪 Testing Scenarios

The system includes comprehensive testing for various failure scenarios:

### 🔥 Failure Testing (`test_failures.sh`)

1. **Port-Forward Failure** - Simulates network connectivity issues
2. **Pod Scaling Down** - Tests service unavailability and auto-scaling
3. **Manual Service Disruption** - Simulates pod crashes
4. **Complete Port-Forward Recovery** - Tests full connectivity restoration
5. **Elasticsearch-Specific Testing** - Tests ES remediation with proper timing
6. **Full Service Restart Cycle** - Comprehensive end-to-end testing

### ⚡ Quick Manual Tests

```bash
# Kill a port-forward and watch detection
pkill -f "kubectl port-forward.*vault.*8200"

# Scale down a service and test remediation
kubectl scale statefulset consul-server -n consul --replicas=0
curl -X POST http://localhost:7070/remediate/consul

# Delete a pod and watch auto-recovery
kubectl delete pod -n vault $(kubectl get pods -n vault -o name | head -1)
```

## 🔧 Configuration

### Environment Variables
```bash
export CLUSTER_NAME="your-cluster-name"           # Default: casbx-mgmt-plane-us-central1
export CHECK_INTERVAL="30"                        # Health check interval in seconds
```

### Service Configuration
The system monitors these services by default:

| Service | Namespace | Port | Health Endpoint |
|---------|-----------|------|-----------------|
| Vault | vault | 8200 | `/v1/sys/health` |
| Consul | consul | 8500 | `/v1/status/leader` |
| Elasticsearch | elasticsearch | 9200 | `/_cluster/health` |

### Customizing Monitored Services

Edit `mcp_server.py` to modify the `PORT_FORWARDS` configuration:

```python
PORT_FORWARDS = {
    "vault": {"namespace": "vault", "service": "vault", "port": 8200},
    "consul": {"namespace": "consul", "service": "consul-server", "port": 8500},
    "elasticsearch": {"namespace": "elasticsearch", "service": "elasticsearch-master", "port": 9200},
    # Add your services here
}
```

## 🛠️ Troubleshooting

### Common Issues

#### Port-forwards not starting
```bash
# Check if services exist
kubectl get svc -A | grep -E "(vault|consul|elasticsearch)"

# Check for port conflicts
netstat -tlnp | grep -E ":(7070|8200|8500|9200)"

# Fix broken port-forwards
./fix_ports.sh
```

#### Services showing as unhealthy
```bash
# Check pod status
kubectl get pods -n vault,consul,elasticsearch

# Check service endpoints directly
curl http://localhost:8200/v1/sys/health
curl http://localhost:8500/v1/status/leader  
curl http://localhost:9200/_cluster/health
```

#### MCP Server not starting
```bash
# Check logs
tail -10 mcp_server.log

# Check if port is in use
lsof -i :7070

# Restart manually
pkill -f "python3 mcp_server.py"
python3 mcp_server.py > mcp_server.log 2>&1 &
```

### Log Files

All components write to individual log files:
- `vault.log` - Vault port-forward logs
- `consul.log` - Consul port-forward logs  
- `es.log` - Elasticsearch port-forward logs
- `mcp_server.log` - MCP server application logs
- `agent.log` - Health monitoring agent logs

### Debug Commands

```bash
# Check all processes
ps aux | grep -E "(kubectl|python3)" | grep -v grep

# Check port status
nc -z localhost 8200 8500 9200 7070

# View real-time logs
tail -f *.log

# Check Kubernetes resources
kubectl get all -n vault,consul,elasticsearch
```

## 🔐 Security Considerations

- **No Authentication** - This is a development/demo tool
- **kubectl Access** - Requires cluster admin permissions for remediation
- **Port-forwards** - Creates local access to cluster services
- **SSL Verification** - Disabled for Elasticsearch connections (`verify=False`)

**⚠️ Warning: This tool is designed for development/testing environments. Do not use in production without proper security hardening.**

## 🚀 Advanced Features

### Auto-Refresh Dashboard
- **Persistent State** - Auto-refresh preference survives page reloads
- **Tab Management** - Pauses when tab is hidden to save resources
- **Visual Feedback** - Shows countdown timer and active status

### Smart Service Discovery
- **Dynamic Detection** - Automatically finds services in various namespaces
- **Fallback Mechanisms** - Tries multiple naming conventions
- **Error Recovery** - Graceful handling of missing services

### Intelligent Remediation
- **Scaling Detection** - Identifies services scaled to 0 replicas
- **Progressive Recovery** - Scales up before restarting
- **Port-forward Management** - Automatically restarts connectivity after remediation
- **Timing Optimization** - Different wait times for different services (ES gets longer)

## 📈 Monitoring and Metrics

### Health Check Metrics
- **Response Time** - HTTP endpoint response timing
- **Service Status** - Binary healthy/unhealthy state
- **Cluster Health** - Elasticsearch cluster color status
- **Leadership** - Consul leader election status
- **Initialization** - Vault seal/unseal status

### Remediation Metrics
- **Success Rate** - Track remediation success/failure
- **Recovery Time** - Time from failure to recovery
- **Failure Patterns** - Common failure scenarios
- **Action History** - Complete audit log of remediation actions

## 🤝 Contributing

### Adding New Services

1. **Update PORT_FORWARDS** in `mcp_server.py`
2. **Add health check** in `agent.py`
3. **Add remediation logic** in `mcp_server.py`
4. **Update test scripts** to include new service

### Extending Functionality

- **Custom Health Checks** - Add service-specific health validation
- **Alert Integrations** - Connect to Slack, PagerDuty, etc.
- **Metrics Export** - Integration with Prometheus/Grafana
- **Advanced Remediation** - Custom recovery procedures per service

## 📜 License

This project is intended for educational and demonstration purposes.

## 🆘 Support

If you encounter issues:

1. **Run diagnostics**: `./test_system.sh`
2. **Check logs**: `tail -f *.log`
3. **Fix ports**: `./fix_ports.sh`
4. **Test recovery**: `./test_failures.sh`

---

**Happy Monitoring! 🎉**

*Built with ❤️ by Aditi Joshi*
