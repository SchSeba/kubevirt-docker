#!/bin/bash -e
set -x

########################
# This is base on https://github.com/SchSeba/kubevirt-docker

KUBEVIRT_FOLDER=`pwd`/kubevirt
FUNC_TEST_ARGS="--ginkgo.noColor --junit-output=`pwd`/tests.junit.xml --ginkgo.focus=Networking --kubeconfig /etc/kubernetes/admin.conf"

# TODO: Edit this wit the interface name from the ci
SRIOV_INTERFACE_NAME=(p1p1 p1p2)

function finish {
docker run --rm -e KUBEVIRT_FOLDER=${KUBEVIRT_FOLDER} -v /var/run/docker.sock:/var/run/docker.sock -v `pwd`:/kubevirt-docker -v $HOME/.kube:/root/.kube/ --network host -t sebassch/centos-docker-client clean
}

trap finish EXIT

docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -e FUNC_TEST_ARGS=${FUNC_TEST_ARGS}  -e KUBEVIRT_FOLDER=${KUBEVIRT_FOLDER} -v `pwd`:/kubevirt-docker -v $HOME/.kube:/root/.kube/ --network host -t sebassch/centos-docker-client up

# Wait for nodes to become ready
kubectl get nodes --no-headers
kubectl_rc=$?
while [ $kubectl_rc -ne 0 ]; do
    echo "Waiting for all nodes to become ready ..."
    kubectl get nodes --no-headers
    kubectl_rc=$?
    sleep 10
done

# Wait until k8s pods are running
while [ -n "$(kubectl get pods --all-namespaces --no-headers | grep -v Running)" ]; do
    echo "Waiting for all pods to enter the Running state ..."
    kubectl get pods --all-namespaces --no-headers | >&2 grep -v Running || true
    sleep 10
done

# Make sure all containers are ready
while [ -n "$(kubectl get pods --all-namespaces -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers | grep false)" ]; do
    echo "Waiting for all containers to become ready ..."
    kubectl get pods --all-namespaces -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers
    sleep 10
done

ln -s /var/run/docker/netns/ /var/run/ -f

DOCKER_NAMESPACE=`docker inspect kube-master | grep netns | tr "/" " "  | awk '{print substr($7, 1, length($7)-2)}'`

for ifc in ${SRIOV_INTERFACE_NAME[@]}; do

   ip link set $ifc netns ${DOCKER_NAMESPACE}
   for i in {0..6}; do
       ip link set ${ifc}_$i netns ${DOCKER_NAMESPACE}
   done

done

#deploy multus
kubectl apply -f manifests/multus.yaml
kubectl apply -f manifests/sriov-crd.yaml
kubectl apply -f manifests/sriov-config-job.yaml
sleep 10

# wait for the sriov-config-job to finnish
while [[ `kubectl -n kube-system get job --no-headers | awk '{ print $2}'` -ne "1/1" ]]; do
  echo "wait for job to finnish"
  kubectl -n kube-system get job
  sleep 10
done

kubectl delete -f manifests/sriov-config-job.yaml

kubectl apply -f manifests/sriovdp-daemonset.yaml
kubectl apply -f manifests/sriov-cni-daemonset.yaml
sleep 10

# Make sure all containers are ready
while [ -n "$(kubectl get pods --all-namespaces -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers | grep false)" ]; do
    echo "Waiting for all containers to become ready ..."
    kubectl get pods --all-namespaces -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers
    sleep 10
done

# Build docker containers
docker exec -t kube-master make

docker exec -t kube-master make docker

docker exec -t kube-master make cluster-deploy

# Make sure all kubevirt containers are ready
while [ -n "$(kubectl get pods -n kubevirt -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers | grep false)" ]; do
    echo "Waiting for all kubevirt containers to become ready ..."
    kubectl get pods -n kubevirt -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers
    sleep 10
done

docker exec -t kube-master make functest
