# Manage Talos Linux VMs on remote Proxmox hosts via SSH
set unstable
set dotenv-load := true
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# -----------------------------
# Proxmox connection
# -----------------------------

pve_host := env('PVE_HOST', '')
pve_user := env('PVE_USER', '')
sudo := if pve_user == "root" { "" } else { "sudo" }


# -----------------------------
# VM defaults
# -----------------------------

talos_version := env('TALOS_VERSION', '') || '1.13.0'
talos_storage := env('TALOS_STORAGE', '') || 'local-lvm'
talos_bridge := env('TALOS_BRIDGE', '') || 'vmbr0'
talos_iso := env('TALOS_ISO', '') || 'local:iso/talos-metal-amd64.iso'

# Image factory image (qcow2 on proxmox local storage)
# Set this if using imported disk images instead of ISO boot
talos_image := env('TALOS_IMAGE', '') || '/var/lib/vz/template/qcow2/talos-{{ talos_version }}.qcow2'

# Control plane defaults
cp_vmids := env('TALOS_CP_VMIDS', '') || '300'
cp_names := env('TALOS_CP_NAMES', '') || 'talos-cp-01'
cp_cores := env('TALOS_CP_CORES', '') || '2'
cp_memory := env('TALOS_CP_MEMORY', '') || '4096'
cp_disk := env('TALOS_CP_DISK', '') || '50'

# Worker defaults
worker_vmids := env('TALOS_WORKER_VMIDS', '') || '105'
worker_names := env('TALOS_WORKER_NAMES', '') || 'talos-worker-01'
worker_cores := env('TALOS_WORKER_CORES', '') || '4'
worker_memory := env('TALOS_WORKER_MEMORY', '') || '16364'
worker_disk := env('TALOS_WORKER_DISK', '') || '100'

all_vmids := cp_vmids + "," + worker_vmids

# -----------------------------
# SSH helper
# -----------------------------

[private]
_require-host:
    #!/usr/bin/env bash
    if [ -z "{{ pve_host }}" ]; then
        echo "PVE_HOST is not set. Export it or add it to .env"
        exit 1
    fi

# Run a command on the proxmox host
[private]
_ssh +cmd:
    just _require-host
    ssh {{ pve_user }}@{{ pve_host }} {{ sudo }} {{ cmd }}

# -----------------------------
# VM lifecycle
# -----------------------------

# Create all Talos VMs (control plane + workers)
create-vms:
    just create-cp-vms
    just create-worker-vms

create-cp-vms:
    just _create-vm-group "{{ cp_vmids }}" "{{ cp_names }}" "{{ cp_cores }}" "{{ cp_memory }}" "{{ cp_disk }}" "controlplane"

create-worker-vms:
    just _create-vm-group "{{ worker_vmids }}" "{{ worker_names }}" "{{ worker_cores }}" "{{ worker_memory }}" "{{ worker_disk }}" "worker"

[private]
_create-vm-group vmids names cores memory disk role:
    #!/usr/bin/env bash
    just _require-host

    IFS=',' read -ra VMIDS <<< "{{ vmids }}"
    IFS=',' read -ra NAMES <<< "{{ names }}"

    if [ "${#VMIDS[@]}" -ne "${#NAMES[@]}" ]; then
        echo "VMIDS and NAMES for '{{ role }}' must have the same number of entries"
        exit 1
    fi

    for i in "${!VMIDS[@]}"; do
        echo "Creating {{ role }} VM ${NAMES[$i]} (VMID ${VMIDS[$i]})..."
        just _create-vm \
            "${VMIDS[$i]}" "${NAMES[$i]}" \
            "{{ cores }}" "{{ memory }}" "{{ disk }}" \
            "{{ role }}"
    done

[private]
_create-vm vmid name cores memory disk role:
    #!/usr/bin/env bash
    if ssh {{ pve_user }}@{{ pve_host }} "{{ sudo }} qm status {{ vmid }}" 2>/dev/null; then
        echo "VM {{ vmid }} ({{ name }}) already exists, skipping"
        exit 0
    fi

    ssh {{ pve_user }}@{{ pve_host }} bash <<'REMOTE'
    set -euo pipefail

    # Create VM shell (no disk yet)
    {{ sudo }} qm create {{ vmid }} \
        --name {{ name }} \
        --tags "talos,{{ role }}" \
        --cpu host \
        --cores {{ cores }} \
        --memory {{ memory }} \
        --scsihw virtio-scsi-pci \
        --net0 virtio,bridge={{ talos_bridge }} \
        --ostype l26 \
        --agent enabled=1

    # Import the qcow2 as the boot disk
    {{ sudo }} qm importdisk {{ vmid }} {{ talos_image }} {{ talos_storage }}

    # Attach the imported disk and set boot order
    {{ sudo }} qm set {{ vmid }} --scsi0 {{ talos_storage }}:vm-{{ vmid }}-disk-0
    {{ sudo }} qm set {{ vmid }} --boot order=scsi0

    # Resize to requested size
    {{ sudo }} qm resize {{ vmid }} scsi0 {{ disk }}G
    REMOTE

    echo "Created VM {{ name }} ({{ vmid }})"

# Start all Talos VMs
start-vms:
    #!/usr/bin/env bash
    just _require-host
    IFS=',' read -ra ALL <<< "{{ all_vmids }}"
    for vmid in "${ALL[@]}"; do
        echo "Starting VM $vmid..."
        just _ssh "qm start $vmid" || echo "VM $vmid may already be running"
    done

# Stop all Talos VMs
stop-vms:
    #!/usr/bin/env bash
    just _require-host
    IFS=',' read -ra ALL <<< "{{ all_vmids }}"
    for vmid in "${ALL[@]}"; do
        echo "Stopping VM $vmid..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
    done

# Destroy all Talos VMs (stop + delete + purge disks)
destroy-vms:
    #!/usr/bin/env bash
    just _require-host
    IFS=',' read -ra ALL <<< "{{ all_vmids }}"
    for vmid in "${ALL[@]}"; do
        echo "Destroying VM $vmid..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
        just _ssh "qm destroy $vmid --purge" 2>/dev/null || true
    done

# Resize a VM's primary disk
resize-disk vmid additional_gb:
    just _require-host
    just _ssh "qm resize {{ vmid }} scsi0 +{{ additional_gb }}G"

# -----------------------------
# Querying
# -----------------------------

# List all Talos-tagged VMs on the host
list-vms:
    #!/usr/bin/env bash
    just _require-host
    echo "Talos VMs on {{ pve_host }}:"
    ssh {{ pve_user }}@{{ pve_host }} bash <<'REMOTE'
    {{ sudo }} qm list | head -1
    for vmid in $({{ sudo }} qm list | tail -n+2 | awk '{print $1}'); do
        tags=$({{ sudo }} qm config "$vmid" | grep -oP '^tags:\s*\K.*' || true)
        if echo "$tags" | grep -q "talos"; then
            {{ sudo }} qm list | awk -v id="$vmid" '$1 == id'
        fi
    done
    REMOTE

# Show status of all cluster VMs
status:
    #!/usr/bin/env bash
    just _require-host
    IFS=',' read -ra ALL <<< "{{ all_vmids }}"
    printf "%-8s %-20s %-10s\n" "VMID" "NAME" "STATUS"
    printf "%-8s %-20s %-10s\n" "----" "----" "------"
    for vmid in "${ALL[@]}"; do
        info=$(ssh  {{ pve_user }}@{{ pve_host }} \
            "{{ sudo }} qm status $vmid --verbose" 2>/dev/null) || { printf "%-8s %-20s %-10s\n" "$vmid" "?" "NOT FOUND"; continue; }
        name=$(echo "$info" | grep -oP '^name:\s*\K.*' || echo "?")
        status=$(echo "$info" | grep -oP '^status:\s*\K.*' || echo "?")
        printf "%-8s %-20s %-10s\n" "$vmid" "$name" "$status"
    done

# Get the IP address of a VM via QEMU guest agent
get-ip vmid:
    #!/usr/bin/env bash
    just _require-host
    ssh {{ pve_user }}@{{ pve_host }} \
        "{{ sudo }} qm guest cmd {{ vmid }} network-get-interfaces" \
        | jq -r '.[] | select(.name != "lo") | ."ip-addresses"[] | select(."ip-address-type" == "ipv4") | ."ip-address"'

# Get IPs for all cluster VMs
get-ips:
    #!/usr/bin/env bash
    just _require-host
    IFS=',' read -ra CP_IDS <<< "{{ cp_vmids }}"
    IFS=',' read -ra W_IDS <<< "{{ worker_vmids }}"
    IFS=',' read -ra CP_N <<< "{{ cp_names }}"
    IFS=',' read -ra W_N <<< "{{ worker_names }}"

    echo "Control plane:"
    for i in "${!CP_IDS[@]}"; do
        ip=$(just get-ip "${CP_IDS[$i]}" 2>/dev/null || echo "unavailable")
        echo "  ${CP_N[$i]} (${CP_IDS[$i]}): $ip"
    done

    echo "Workers:"
    for i in "${!W_IDS[@]}"; do
        ip=$(just get-ip "${W_IDS[$i]}" 2>/dev/null || echo "unavailable")
        echo "  ${W_N[$i]} (${W_IDS[$i]}): $ip"
    done

# -----------------------------
# Snapshots
# -----------------------------

# Snapshot all VMs (e.g., before config changes)
snapshot-all name="pre-change":
    #!/usr/bin/env bash
    just _require-host
    IFS=',' read -ra ALL <<< "{{ all_vmids }}"
    for vmid in "${ALL[@]}"; do
        echo "Snapshotting VM $vmid as {{ name }}..."
        just _ssh "qm snapshot $vmid {{ name }} --description 'automated snapshot'"
    done

# Rollback all VMs to a snapshot
rollback-all name="pre-change":
    #!/usr/bin/env bash
    just _require-host
    IFS=',' read -ra ALL <<< "{{ all_vmids }}"
    for vmid in "${ALL[@]}"; do
        echo "Rolling back VM $vmid to {{ name }}..."
        just _ssh "qm stop $vmid --skiplock" 2>/dev/null || true
        just _ssh "qm rollback $vmid {{ name }}"
        just _ssh "qm start $vmid"
    done

# -----------------------------
# Full lifecycle
# -----------------------------

# Recreate VMs from scratch
recreate-vms:
    just destroy-vms
    just create-vms
    just start-vms
    @echo "VMs created and started. Wait for nodes to enter Talos maintenance mode, then run your cluster bootstrap."
