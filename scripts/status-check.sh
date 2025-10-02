#!/bin/bash

# Litmus Status Check Script
# This script checks the current status of Litmus installation

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="litmus"
RELEASE_NAME="chaos"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo "========================================"
    echo "  Litmus Chaos Engineering Status"
    echo "========================================"
    echo ""
}

check_cluster_access() {
    log_info "Checking cluster access..."
    if kubectl cluster-info &> /dev/null; then
        local cluster_info
        cluster_info=$(kubectl cluster-info | head -1)
        log_success "Connected to cluster: $cluster_info"
    else
        log_error "Cannot connect to Kubernetes cluster"
        return 1
    fi
}

check_namespace() {
    log_info "Checking namespace..."
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        local age
        age=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}')
        log_success "Namespace '$NAMESPACE' exists (created: $age)"
    else
        log_warning "Namespace '$NAMESPACE' does not exist"
        return 1
    fi
}

check_helm_release() {
    log_info "Checking Helm release..."
    if helm list -n "$NAMESPACE" | grep -q "$RELEASE_NAME"; then
        local release_info
        release_info=$(helm list -n "$NAMESPACE" | grep "$RELEASE_NAME")
        log_success "Helm release found:"
        echo "  $release_info"
        
        # Get detailed status
        echo ""
        log_info "Helm release status:"
        helm status "$RELEASE_NAME" -n "$NAMESPACE"
    else
        log_warning "Helm release '$RELEASE_NAME' not found"
        return 1
    fi
}

check_pods() {
    log_info "Checking pod status..."
    if kubectl get pods -n "$NAMESPACE" &> /dev/null; then
        echo ""
        kubectl get pods -n "$NAMESPACE"
        echo ""
        
        # Count running pods
        local total_pods running_pods
        total_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers | wc -l)
        running_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers | grep "Running" | wc -l)
        
        if [[ $running_pods -eq $total_pods ]]; then
            log_success "All $total_pods pods are running"
        else
            log_warning "$running_pods/$total_pods pods are running"
            
            # Show non-running pods
            log_info "Non-running pods:"
            kubectl get pods -n "$NAMESPACE" --no-headers | grep -v "Running" || echo "  None"
        fi
    else
        log_warning "No pods found in namespace '$NAMESPACE'"
        return 1
    fi
}

check_services() {
    log_info "Checking services..."
    if kubectl get svc -n "$NAMESPACE" &> /dev/null; then
        echo ""
        kubectl get svc -n "$NAMESPACE"
        echo ""
        
        # Check frontend service specifically
        if kubectl get svc chaos-litmus-frontend-service -n "$NAMESPACE" &> /dev/null; then
            local service_type port
            service_type=$(kubectl get svc chaos-litmus-frontend-service -n "$NAMESPACE" -o jsonpath='{.spec.type}')
            
            case $service_type in
                "NodePort")
                    port=$(kubectl get svc chaos-litmus-frontend-service -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
                    log_success "Frontend service available on NodePort: $port"
                    log_info "Access via: kubectl port-forward svc/chaos-litmus-frontend-service 9091:9091 -n $NAMESPACE"
                    ;;
                "LoadBalancer")
                    local external_ip
                    external_ip=$(kubectl get svc chaos-litmus-frontend-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
                    if [[ -n "$external_ip" ]]; then
                        log_success "Frontend service available on LoadBalancer: $external_ip:9091"
                    else
                        log_warning "LoadBalancer external IP pending"
                    fi
                    ;;
                "ClusterIP")
                    log_info "Frontend service is ClusterIP only"
                    log_info "Access via: kubectl port-forward svc/chaos-litmus-frontend-service 9091:9091 -n $NAMESPACE"
                    ;;
            esac
        fi
    else
        log_warning "No services found in namespace '$NAMESPACE'"
        return 1
    fi
}

check_storage() {
    log_info "Checking persistent storage..."
    if kubectl get pvc -n "$NAMESPACE" &> /dev/null; then
        echo ""
        kubectl get pvc -n "$NAMESPACE"
        echo ""
        
        local bound_pvcs total_pvcs
        total_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers | wc -l)
        bound_pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers | grep "Bound" | wc -l)
        
        if [[ $bound_pvcs -eq $total_pvcs ]]; then
            log_success "All $total_pvcs PVCs are bound"
        else
            log_warning "$bound_pvcs/$total_pvcs PVCs are bound"
        fi
    else
        log_warning "No PVCs found in namespace '$NAMESPACE'"
    fi
}

check_crds() {
    log_info "Checking Custom Resource Definitions..."
    local litmus_crds
    litmus_crds=$(kubectl get crd | grep -E "litmuschaos|argoproj" | wc -l)
    
    if [[ $litmus_crds -gt 0 ]]; then
        log_success "Found $litmus_crds Litmus/Argo CRDs"
        kubectl get crd | grep -E "litmuschaos|argoproj" | head -5
        if [[ $litmus_crds -gt 5 ]]; then
            echo "  ... and $((litmus_crds - 5)) more"
        fi
    else
        log_warning "No Litmus CRDs found"
    fi
}

show_access_info() {
    echo ""
    log_info "Access Information:"
    echo "==================="
    echo ""
    
    if kubectl get svc chaos-litmus-frontend-service -n "$NAMESPACE" &> /dev/null; then
        echo -e "${GREEN}Port Forward Access:${NC}"
        echo "  kubectl port-forward svc/chaos-litmus-frontend-service 9091:9091 -n $NAMESPACE"
        echo "  URL: http://localhost:9091"
        echo ""
        
        local service_type
        service_type=$(kubectl get svc chaos-litmus-frontend-service -n "$NAMESPACE" -o jsonpath='{.spec.type}')
        
        if [[ "$service_type" == "NodePort" ]]; then
            local nodeport
            nodeport=$(kubectl get svc chaos-litmus-frontend-service -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
            echo -e "${GREEN}NodePort Access:${NC}"
            echo "  http://<node-ip>:$nodeport"
            echo ""
        fi
        
        echo -e "${GREEN}Default Credentials:${NC}"
        echo "  Username: admin"
        echo "  Password: litmus"
    else
        log_warning "Frontend service not found"
    fi
}

show_quick_commands() {
    echo ""
    log_info "Quick Commands:"
    echo "==============="
    echo ""
    echo "# Access Litmus UI:"
    echo "kubectl port-forward svc/chaos-litmus-frontend-service 9091:9091 -n $NAMESPACE"
    echo ""
    echo "# Watch pods:"
    echo "kubectl get pods -n $NAMESPACE -w"
    echo ""
    echo "# Check logs:"
    echo "kubectl logs -n $NAMESPACE deployment/chaos-litmus-server"
    echo "kubectl logs -n $NAMESPACE deployment/chaos-litmus-frontend"
    echo ""
    echo "# Reinstall (see official docs):"
    echo "https://docs.litmuschaos.io/docs/getting-started/installation"
    echo ""
    echo "# Uninstall (see official docs):"
    echo "https://docs.litmuschaos.io/docs/user-guides/uninstall-litmus"
}

main() {
    print_header
    
    local status=0
    
    check_cluster_access || status=1
    echo ""
    
    check_namespace || status=1
    echo ""
    
    check_helm_release || status=1
    echo ""
    
    check_pods || status=1
    echo ""
    
    check_services || status=1
    echo ""
    
    check_storage
    echo ""
    
    check_crds
    
    if [[ $status -eq 0 ]]; then
        show_access_info
        show_quick_commands
        echo ""
        log_success "Litmus appears to be installed and running correctly!"
    else
        echo ""
        log_warning "Litmus installation has some issues. Check the output above."
        echo ""
        echo "To reinstall, see official docs:"
        echo "  https://docs.litmuschaos.io/docs/getting-started/installation"
    fi
    
    return $status
}

# Run main function
main "$@"