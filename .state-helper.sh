#!/bin/bash

# ════════════════════════════════════════════════════════════
# Pod-Specific State Management Helper
# ════════════════════════════════════════════════════════════
# This script ensures each pod uses its own Terraform state file
# to prevent state confusion when switching between pods.
#
# Usage:
#   source .state-helper.sh
#   setup_pod_state     # Call at the start of deployment scripts
#   cleanup_pod_state   # Call during cleanup
# ════════════════════════════════════════════════════════════

# Get pod number from terraform.tfvars
get_pod_number() {
    if [ -f "terraform.tfvars" ]; then
        grep -E '^pod_number' terraform.tfvars 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' "'
    fi
}

# Setup pod-specific state directory and symlink
setup_pod_state() {
    local POD_NUM=$(get_pod_number)
    
    if [ -z "$POD_NUM" ]; then
        echo "❌ Error: Pod number not found in terraform.tfvars"
        echo "   Run ./1-init-lab.sh first"
        return 1
    fi
    
    # Create pod-specific state directory
    local STATE_DIR=".terraform/states/pod${POD_NUM}"
    mkdir -p "$STATE_DIR"
    
    # If there's a state file in the wrong location, move it
    if [ -f "terraform.tfstate" ] && [ ! -L "terraform.tfstate" ]; then
        # Check if this state belongs to current pod
        local STATE_POD=$(grep -o '"pod_number":\s*[0-9]*' terraform.tfstate 2>/dev/null | grep -o '[0-9]*' | head -1)
        
        if [ "$STATE_POD" = "$POD_NUM" ]; then
            echo "📦 Moving existing state to pod${POD_NUM} directory..."
            mv terraform.tfstate "$STATE_DIR/"
            [ -f "terraform.tfstate.backup" ] && mv terraform.tfstate.backup "$STATE_DIR/"
        else
            echo "⚠️  WARNING: Existing state is for pod${STATE_POD}, not pod${POD_NUM}"
            echo "   Moving old state to .terraform/states/pod${STATE_POD}/"
            mkdir -p ".terraform/states/pod${STATE_POD}"
            mv terraform.tfstate ".terraform/states/pod${STATE_POD}/"
            [ -f "terraform.tfstate.backup" ] && mv terraform.tfstate.backup ".terraform/states/pod${STATE_POD}/"
        fi
    fi
    
    # Create symlink to pod-specific state
    if [ ! -L "terraform.tfstate" ]; then
        ln -sf "$STATE_DIR/terraform.tfstate" terraform.tfstate
        echo "✅ Using pod-specific state: $STATE_DIR/terraform.tfstate"
    else
        # Verify symlink points to correct pod
        local LINK_TARGET=$(readlink terraform.tfstate)
        if [[ "$LINK_TARGET" != *"pod${POD_NUM}"* ]]; then
            echo "⚠️  Symlink points to wrong pod, fixing..."
            rm terraform.tfstate
            ln -sf "$STATE_DIR/terraform.tfstate" terraform.tfstate
            echo "✅ Fixed symlink to: $STATE_DIR/terraform.tfstate"
        fi
    fi
    
    # Also handle backup state
    if [ -f "$STATE_DIR/terraform.tfstate.backup" ] && [ ! -L "terraform.tfstate.backup" ]; then
        rm -f terraform.tfstate.backup
        ln -sf "$STATE_DIR/terraform.tfstate.backup" terraform.tfstate.backup 2>/dev/null
    fi
    
    return 0
}

# List all pod states
list_pod_states() {
    echo "════════════════════════════════════════════════════════════"
    echo "Pod State Files"
    echo "════════════════════════════════════════════════════════════"
    
    if [ -d ".terraform/states" ]; then
        for pod_dir in .terraform/states/pod*; do
            if [ -d "$pod_dir" ]; then
                local POD_NUM=$(basename "$pod_dir" | sed 's/pod//')
                local STATE_FILE="$pod_dir/terraform.tfstate"
                
                if [ -f "$STATE_FILE" ]; then
                    local SIZE=$(du -h "$STATE_FILE" | cut -f1)
                    local MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$STATE_FILE" 2>/dev/null || stat -c "%y" "$STATE_FILE" 2>/dev/null | cut -d' ' -f1-2)
                    echo "Pod $POD_NUM: $SIZE ($MODIFIED)"
                else
                    echo "Pod $POD_NUM: (empty)"
                fi
            fi
        done
    else
        echo "No pod-specific states found"
    fi
    
    echo ""
    local CURRENT_POD=$(get_pod_number)
    if [ -n "$CURRENT_POD" ]; then
        echo "Current pod: $CURRENT_POD"
    fi
}

# Cleanup pod-specific state
cleanup_pod_state() {
    local POD_NUM=${1:-$(get_pod_number)}
    
    if [ -z "$POD_NUM" ]; then
        echo "❌ Error: No pod number provided or found in terraform.tfvars"
        return 1
    fi
    
    local STATE_DIR=".terraform/states/pod${POD_NUM}"
    
    if [ -d "$STATE_DIR" ]; then
        echo "🗑️  Removing state for pod${POD_NUM}..."
        rm -rf "$STATE_DIR"
        echo "✅ State cleaned for pod${POD_NUM}"
    else
        echo "ℹ️  No state found for pod${POD_NUM}"
    fi
    
    # Clean up symlinks if they point to this pod
    if [ -L "terraform.tfstate" ]; then
        local LINK_TARGET=$(readlink terraform.tfstate)
        if [[ "$LINK_TARGET" == *"pod${POD_NUM}"* ]]; then
            rm -f terraform.tfstate terraform.tfstate.backup
            echo "✅ Removed symlinks"
        fi
    fi
    
    return 0
}

# Verify current state matches current pod
verify_pod_state() {
    local CURRENT_POD=$(get_pod_number)
    
    if [ -z "$CURRENT_POD" ]; then
        echo "❌ No pod number in terraform.tfvars"
        return 1
    fi
    
    if [ ! -f "terraform.tfstate" ]; then
        echo "ℹ️  No state file (fresh deployment)"
        return 0
    fi
    
    # Check if state file has resources and what pod they belong to
    if [ -f "terraform.tfstate" ] && [ ! -L "terraform.tfstate" ]; then
        local STATE_POD=$(grep -o '"pod_number":\s*[0-9]*' terraform.tfstate 2>/dev/null | grep -o '[0-9]*' | head -1)
        
        if [ -n "$STATE_POD" ] && [ "$STATE_POD" != "$CURRENT_POD" ]; then
            echo "❌ STATE MISMATCH DETECTED!"
            echo "   terraform.tfvars: pod${CURRENT_POD}"
            echo "   terraform.tfstate: pod${STATE_POD}"
            echo ""
            echo "This will cause resource conflicts!"
            echo "Run: source .state-helper.sh && setup_pod_state"
            return 1
        fi
    fi
    
    echo "✅ State is correct for pod${CURRENT_POD}"
    return 0
}

# Export functions
export -f get_pod_number
export -f setup_pod_state
export -f list_pod_states
export -f cleanup_pod_state
export -f verify_pod_state

