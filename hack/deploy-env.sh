#!/bin/bash

set +x

# https://minikube.sigs.k8s.io/docs/drivers/kvm2/

function wait_for_ssh() {
    local tries=100
    while (( tries > 0 )) ; do
        if minikube ssh --profile $1 echo connected &> /dev/null ; then
            return 0
        fi
        tries=$(( tries - 1 ))
        sleep 0.1
    done
    echo ERROR: ssh did not come up >&2
    exit 1
}

function wait_for_condition() {
    local count=71
    local condition=${1}
    local result
    shift

    while ((count > 0)); do
        result=$("${@}")
        if [[ "$result" == "$condition" ]]; then
            return 0
        fi
        count=$((count - 1))
        sleep 5
    done

    echo "Failed to meet $condition for command $*"
    echo ""
    exit 1
}

function setup_network() {
    echo "Define a network to share between clusters"
    sudo virsh net-define br10.xml

    echo "Start network"
    sudo virsh net-start br10

    echo "Set network to autostart"
    sudo virsh net-autostart br10

    echo "Verify network in list"
    sudo virsh net-list --all

    echo "Verify network details"
    ip addr show dev br10

    echo "Restart libvirtd"
    sudo systemctl restart libvirtd

    echo ""
}

function attach_disk() {
    UUID=$(uuidgen)
    IMAGE=/var/lib/libvirt/images/minikube-$1-$UUID
    for i in b c d; do
        IMAGE=$IMAGE-$i
        sudo qemu-img create -f raw $IMAGE 30G
        sudo virsh attach-disk $1 $IMAGE vd$i --cache none --persistent
    done
    minikube -p $1 stop
    minikube -p $1 start

    minikube ssh -p $1 "sudo rm -rf /mnt/vda1/rook/ /var/lib/rook && sudo rm -rf /mnt/vda1/rook/ && sudo mkdir /mnt/vda1/rook/ && sudo ln -sf /mnt/vda1/rook/ /var/lib/ && sudo rm -rf /var/log/ceph/rook-ceph/"
}

function start_minikube() {
    echo "Start hub cluster"
    minikube start --driver=kvm2 --network=br10 --profile=$1
    wait_for_ssh $1
    echo ""

    echo "Start cluster1 ManagedCluster"
    minikube start --driver=kvm2 --network=br10 --extra-disks=3 --profile=$2
    wait_for_ssh $2
    # attach_disk $2
    minikube ssh -p $2 "sudo rm -rf /mnt/vda1/rook/ /var/lib/rook && sudo rm -rf /mnt/vda1/rook/ && sudo mkdir /mnt/vda1/rook/ && sudo ln -sf /mnt/vda1/rook/ /var/lib/ && sudo rm -rf /var/log/ceph/rook-ceph/"
    echo ""

    echo "Start cluster2 ManagedCluster"
    minikube start --driver=kvm2 --network=br10 --extra-disks=3 --profile=$3
    wait_for_ssh $3
    # attach_disk $3
    minikube ssh -p $3 "sudo rm -rf /mnt/vda1/rook/ /var/lib/rook && sudo rm -rf /mnt/vda1/rook/ && sudo mkdir /mnt/vda1/rook/ && sudo ln -sf /mnt/vda1/rook/ /var/lib/ && sudo rm -rf /var/log/ceph/rook-ceph/"
    echo ""
}

function deploy_olm() {
    echo "Deploying OLM"

    release="v0.21.2"
    base_url="https://github.com/operator-framework/operator-lifecycle-manager/releases/download"
    url="${base_url}/${release}"
    namespace=olm

    for cl in "$@"
    do
        if kubectl --context $cl get deployment olm-operator -n ${namespace} > /dev/null 2>&1; then
            echo "OLM is already installed in ${namespace} namespace. Exiting..."
            return
        fi

        kubectl --context $cl create -f "${url}/crds.yaml"
        kubectl --context $cl wait --for=condition=Established -f "${url}/crds.yaml"
        kubectl --context $cl create -f "${url}/olm.yaml"

        # wait for deployments to be ready
        kubectl --context $cl rollout status -w deployment/olm-operator --namespace="${namespace}"
        kubectl --context $cl rollout status -w deployment/catalog-operator --namespace="${namespace}"


        retries=30
        until [[ $retries == 0 ]]; do
            new_csv_phase=$(kubectl --context $cl get csv -n "${namespace}" packageserver -o jsonpath='{.status.phase}' 2>/dev/null || echo "Waiting for CSV to appear")
            if [[ $new_csv_phase != "$csv_phase" ]]; then
                csv_phase=$new_csv_phase
                echo "Package server phase: $csv_phase"
            fi
            if [[ "$new_csv_phase" == "Succeeded" ]]; then
            break
            fi
            sleep 10
            retries=$((retries - 1))
        done

        if [ $retries == 0 ]; then
            echo "CSV \"packageserver\" failed to reach phase succeeded"
            exit 1
        fi

        kubectl --context $cl rollout status -w deployment/packageserver --namespace="${namespace}"
    done
}

function deploy_ocm() {
    echo "Deploy Registration Operator (hub)"
    # git clone and make deploy-hub



    echo "Deploy Registration Operator (cluster1)"
    # git clone and make deploy-spoke



    echo "Deploy Registration Operator (cluster2)"
    # git clone and make deploy-spoke

    echo "Approve CSR for ManagedClusters"
    # kubectl certificate approve <csrName>

    echo "Patch ManagedCluster (in hub)"
    # kubectl patch managedcluster cluster1 -p='{"spec":{"hubAcceptsClient":true}}' --type=merge --context=hub
}

function token_exchange() {
    echo "Injecting token from" $1 "to" $2
    cluster=`kubectl --context $1 get secret cluster-peer-token-my-cluster -n rook-ceph -ojsonpath={.data.cluster} | base64 -d`
    token=`kubectl --context $1 get secret cluster-peer-token-my-cluster -n rook-ceph -ojsonpath={.data.token} | base64 -d`
    kubectl --context $2 -n rook-ceph create secret generic $1-peer-secret --from-literal=token=$token --from-literal=cluster=$cluster
    kubectl --context $2 -n rook-ceph patch cephblockpool replicapool --type merge --patch '{"spec": {"mirroring": {"peers": {"secretNames": ["cluster1-peer-secret"]}}}}'
    echo ""

    echo "Injecting token from" $2 "to" $1
    cluster=`kubectl --context $2 get secret cluster-peer-token-my-cluster -n rook-ceph -ojsonpath={.data.cluster} | base64 -d`
    token=`kubectl --context $2 get secret cluster-peer-token-my-cluster -n rook-ceph -ojsonpath={.data.token} | base64 -d`
    kubectl --context $1 -n rook-ceph create secret generic $2-peer-secret --from-literal=token=$token --from-literal=cluster=$cluster
    kubectl --context $1 -n rook-ceph patch cephblockpool replicapool --type merge --patch '{"spec": {"mirroring": {"peers": {"secretNames": ["cluster2-peer-secret"]}}}}'
    echo ""
}

function deploy_rook() {
    for cl in "$@"
    do
        echo "Cluster:" $cl
        echo "Deploying Rook"
        kubectl --context $cl apply -f https://raw.githubusercontent.com/rook/rook/492786404c768024382c9f1544b33f559f3f7173/deploy/examples/crds.yaml
        kubectl --context $cl apply -f https://raw.githubusercontent.com/rook/rook/492786404c768024382c9f1544b33f559f3f7173/deploy/examples/common.yaml
        kubectl --context $cl apply -f https://raw.githubusercontent.com/rook/rook/492786404c768024382c9f1544b33f559f3f7173/deploy/examples/operator.yaml
        echo "Deploying CephCluster"
        kubectl --context $cl apply -f https://raw.githubusercontent.com/RamenDR/ramen/2de057515a55ca3aa9fbf330eec56a3730b43dba/hack/dev-rook-cluster.yaml
        echo "Deploying CephBlockPool with mirroring enabled"
        kubectl --context $cl apply -f https://raw.githubusercontent.com/RamenDR/ramen/d8482ea600a5bdcde4f2df3c317618d8178e9465/hack/dev-rook-rbdpool.yaml
        echo "Creating StorageClass for CephBlockPool"
        kubectl --context $cl apply -f https://raw.githubusercontent.com/RamenDR/ramen/d8482ea600a5bdcde4f2df3c317618d8178e9465/hack/dev-rook-sc.yaml
        echo "Enabling CSI sidecars"
        kubectl --context $cl patch cm rook-ceph-operator-config -n rook-ceph --type json --patch  '[{ "op": "add", "path": "/data/CSI_ENABLE_OMAP_GENERATOR", "value": "true" }]'
        kubectl --context $cl patch cm rook-ceph-operator-config -n rook-ceph --type json --patch  '[{ "op": "add", "path": "/data/CSI_ENABLE_VOLUME_REPLICATION", "value": "true" }]'
        echo "Adding VolumeReplicationOperator v0.3.0 CRDs"
        kubectl --context $cl apply -f https://raw.githubusercontent.com/csi-addons/volume-replication-operator/v0.3.0/config/crd/bases/replication.storage.openshift.io_volumereplications.yaml
        kubectl --context $cl apply -f https://raw.githubusercontent.com/csi-addons/volume-replication-operator/v0.3.0/config/crd/bases/replication.storage.openshift.io_volumereplicationclasses.yaml
        echo "Creating RBD mirror daemon"
        kubectl --context $cl apply -f https://raw.githubusercontent.com/rook/rook/833c458f606c2b9db9885497d3d1364d6e4ce34d/deploy/examples/rbdmirror.yaml
        echo ""
        echo "Deploy Rook-Ceph toolbox"
        kubectl --context $cl apply -f https://raw.githubusercontent.com/rook/rook/833c458f606c2b9db9885497d3d1364d6e4ce34d/deploy/examples/toolbox.yaml
        echo ""
        echo "Creating VolumeReplicationClass"
        cat <<EOF | kubectl --context=$cl apply -f -
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplicationClass
metadata:
  name: vrc-1m
spec:
  provisioner: rook-ceph.rbd.csi.ceph.com
  parameters:
    replication.storage.openshift.io/replication-secret-name: rook-csi-rbd-provisioner
    replication.storage.openshift.io/replication-secret-namespace: rook-ceph
    schedulingInterval: 1m
EOF
        echo ""
    done
}

function init_default_pvc_with_mirroring() {
    echo "Creating default PVC and VolumeReplication resources"
    cat <<EOF | kubectl --context $1 apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
EOF
    wait_for_condition "Bound" kubectl get pvc pvc-test --context $1 -o jsonpath='{.status.phase}'

    cat <<EOF | kubectl --context $1 apply -f -
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: vr-1m
spec:
  volumeReplicationClass: vrc-1m
  replicationState: primary
  dataSource:
    kind: PersistentVolumeClaim
    name: pvc-test
EOF
    wait_for_condition "Primary" kubectl get volumereplication vr-1m --context $1 -o jsonpath='{.status.state}'
    echo ""
}

function deploy_benchmark_operator() {
    echo "Deploying FIO load generator"
    kubectl --context $1 create ns benchmark-operator
    kubectl --context $1 apply -f ./benchmark-operator.yaml -n benchmark-operator
    wait_for_condition "Running" kubectl --context $1 get po -n benchmark-operator -l control-plane=controller-manager -ojsonpath='{.items[0].status.phase}'
    kubectl --context $1 apply -f ./fio-benchmark.yaml -n benchmark-operator
    wait_for_condition "StartingServers" kubectl --context $1 get benchmark fio-benchmark-rbd-mirror -n benchmark-operator -ojsonpath='{.status.state}'
    echo "Finished deploying FIO load generator"

    pvcList=(`kubectl --context $1 get pvc -n benchmark-operator -ojsonpath='{.items[*].metadata.name}'`)
    for pvc in ${pvcList[@]}
    do
        echo "Creating VolumeReplication for PVC $pvc"
        cat <<EOF | kubectl --context $1 apply -f -
apiVersion: replication.storage.openshift.io/v1alpha1
kind: VolumeReplication
metadata:
  name: "${pvc}"
  namespace: benchmark-operator
spec:
  volumeReplicationClass: vrc-1m
  replicationState: primary
  dataSource:
    kind: PersistentVolumeClaim
    name: "${pvc}"
EOF
        wait_for_condition "Primary" kubectl --context $1 -n benchmark-operator get volumereplication $pvc -o jsonpath='{.status.state}'
    done
    echo ""
}

function deploy_monitoring() {
    for cl in "$@"
    do
        kubectl --context $cl create ns monitoring
        kubectl --context $cl -n monitoring apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/nodeExporter-serviceAccount.yaml
        kubectl --context $cl -n monitoring apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/nodeExporter-clusterRole.yaml
        kubectl --context $cl -n monitoring apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/nodeExporter-clusterRoleBinding.yaml
        kubectl --context $cl -n monitoring apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/nodeExporter-daemonset.yaml
        kubectl --context $cl -n monitoring apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/nodeExporter-service.yaml
        kubectl --context $cl -n monitoring apply -f https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/nodeExporter-networkPolicy.yaml
    done
}

function create() {
    setup_network
    start_minikube hub cluster1 cluster2
    deploy_olm hub cluster1 cluster2

    deploy_rook cluster1 cluster2
    wait_for_condition "Ready" kubectl --context cluster1 get cephcluster my-cluster -n rook-ceph -o jsonpath={.status.phase}
    wait_for_condition "Ready" kubectl --context cluster2 get cephcluster my-cluster -n rook-ceph -o jsonpath={.status.phase}

    token_exchange cluster1 cluster2
    wait_for_condition "OK" kubectl get cephblockpools.ceph.rook.io replicapool --context="cluster1" -nrook-ceph -o jsonpath='{.status.mirroringStatus.summary.daemon_health}'
    echo RBD mirror daemon health OK
    wait_for_condition "OK" kubectl get cephblockpools.ceph.rook.io replicapool --context="cluster1" -nrook-ceph -o jsonpath='{.status.mirroringStatus.summary.health}'
    echo RBD mirror status health OK
    wait_for_condition "OK" kubectl get cephblockpools.ceph.rook.io replicapool --context="cluster1" -nrook-ceph -o jsonpath='{.status.mirroringStatus.summary.image_health}'
    echo RBD mirror image summary health OK
    echo ""
    echo "SUCCESS!"
    echo ""

    init_default_pvc_with_mirroring cluster1

    deploy_benchmark_operator cluster1

    deploy_monitoring cluster1 cluster2
}

function destroy() {
    minikube delete -p hub
    minikube delete -p cluster1
    minikube delete -p cluster2
    IMAGE2=/var/lib/libvirt/images/minikube-cluster1-*
    IMAGE3=/var/lib/libvirt/images/minikube-cluster2-*
    sudo rm -rf $IMAGE2 $IMAGE3
}

echo "(c)reate or (d)estroy"
read option
case $option in
    c)
        create
        ;;
    d)
        destroy
        ;;
    *)
        echo "Invalid option"
        exit 1
        ;;
esac

exit 0