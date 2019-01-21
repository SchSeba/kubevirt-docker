#!/bin/bash

#set -x

echo "#########################################"
echo "############## STARTING #################"
echo "#########################################"



# TODO: should this be hardcoded/taken from config?
HOST_IP=$(ip route get 1 | awk '{print $7}')


CLUSTER_UP_LOG=/tmp/cluster_up_log
CLUSTER_UP_PID=/tmp/cluster_up_pid
SRIOV_IGB_MAX_VFS=7
SRIOV_IFC_NAME=I350

cleanup() { 


  if [[ -f $CLUSTER_UP_PID ]]; then
    kill -SIGINT -$(cat $CLUSTER_UP_PID)
  fi
  
  ps -ef|grep "make cluster-up" |grep -v grep | awk '{print $2}'| xargs -I {}  kill -SIGINT -{}
  sleep 5
  
  # just in case any garbage survives
  if [[ -f $CLUSTER_UP_PID ]]; then
    kill -9 $(cat $CLUSTER_UP_PID)
  fi  
  ps -ef|grep "make cluster-up" |grep -v grep | awk '{print $2}'| xargs -I {}  kill -9 {}
  ps -ef|grep "kube" |grep -v grep | awk '{print $2}'| xargs -I {}  kill -9 {}
  
  
  rm -f $CLUSTER_UP_LOG
  rm -f /etc/pcidp/config.json
  rm -rf /tmp/*
  rm -rf /opt/cni/bin/*
  
  git checkout -- cluster/examples/vmi-sriov.yaml
  pkill etcd
  
  systemctl stop docker
  yum remove -y docker
  
  rm -rf $GOPATH/src/github.com/containernetworking/plugins/
  rm -rf $GOPATH/src/k8s.io/kubernetes
  rm -rf $GOPATH/src/github.com/intel/sriov-network-device-plugin/
  rm -rf $GOPATH/src/github.com/intel/multus-cni
  rm -rf $GOPATH/src/github.com/intel/sriov-network-device-plugin/
  rm -rf $GOPATH/src/github.com/intel/sriov-cni/
  rm -rf $GOPATH/src/kubevirt.io/kubevirt
  
}

get_sriov_pci_addresses() { 
  
  # TODO: this is very fragile
  pci_addresses=($(lspci |grep "Ethernet controller" |grep $SRIOV_IFC_NAME | grep -v Virtual | awk '{print$1}'))
}

# TODO: alternative to get_sriov_pci_addresses
get_sriov_pci_addresses2() { 
  local pcis=()
  local devs=($(ls /sys/class/net))
  
  for dev in ${devs[@]}; do
    if [[ -f "/sys/class/net/$dev/device/sriov_numvfs" ]]; then
      local files=($(ls /sys/class/net/$dev/device/driver/))
      for file in ${files[@]}; do
        if [[ $file == 0000* ]]; then
           file=${file#"0000:"}
           pcis+=($file)
        fi
      done
    fi
  done
  pci_addresses=($(echo "${pcis[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
}

# TODO: alternative to get_sriov_pci_addresses
get_sriov_pci_addresses3() { 
  local pcis=($(find /sys/devices/ -name sriov_totalvfs |awk -F '/' '{print$6}'))
  pci_addresses=($(echo ${pcis[@]#"0000:"}))
  
}

create_pci_string() {
  local quoted_values=($(echo "${pci_addresses[@]}" | xargs printf "\"%s\" "  ))
  local quoted_as_string=${quoted_values[@]}
  pci_string=${quoted_as_string// /, }
}


configure_sriov_on_os() { 
  modprobe -r igb
  modprobe igb max_vfs=$SRIOV_IGB_MAX_VFS
  modprobe vfio-pci

}

os_setup() { 
  setenforce 0
  swapoff -a
  systemctl disable firewalld --now
  iptables -P FORWARD ACCEPT
  sysctl net.ipv4.conf.all.forwarding=1
  systemctl stop firewalld

  yum install -y wget git gcc docker
  if [[ ! `grep kubdev /etc/hosts` ]]; then
    echo "$HOST_IP kubdev" >> /etc/hosts
  fi

  systemctl enable docker
  systemctl start docker

  wget https://dl.google.com/go/go1.11.4.linux-amd64.tar.gz
  tar -C /usr/local -xzf go1.11.4.linux-amd64.tar.gz

  export GOPATH=~/go
  export PATH=$PATH:/usr/local/go/bin
  if [[ ! `grep GOPATH ~/.bash_profile` ]]; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bash_profile
    echo 'export GOPATH=~/go' >> ~/.bash_profile
  fi
}


install_network_plugins() { 
  go get -u -d github.com/containernetworking/plugins/
  cd $GOPATH/src/github.com/containernetworking/plugins/
  ./build_linux.sh
  mkdir -p /opt/cni/bin/
  cp bin/* /opt/cni/bin/
}

install_kubernetes() { 
  go get -u -d k8s.io/kubernetes
  cd $GOPATH/src/k8s.io/kubernetes
  # TODO: master is broken
  git checkout release-1.12
  
  # TODO: edit in place would be nicer
  awk '{print} /leader-elect/ && !n {print "      --cert-dir=\"$CERT_DIR\" \\"; print "      --allocate-node-cidrs=true --cluster-cidr=10.244.0.0/16 \\"; n++}' hack/local-up-cluster.sh > tmp && mv -f tmp hack/local-up-cluster.sh
  chmod 755  hack/local-up-cluster.sh

  export NET_PLUGIN=cni
  export CNI_CONF_DIR=/etc/cni/net.d/
  export CNI_BIN_DIR=/opt/cni/bin/

  if [[ ! `grep NET_PLUGIN ~/.bash_profile` ]]; then
    echo 'export NET_PLUGIN=cni' >> ~/.bash_profile
    echo 'export CNI_CONF_DIR=/etc/cni/net.d/' >> ~/.bash_profile
    echo 'export CNI_BIN_DIR=/opt/cni/bin/' >> ~/.bash_profile
  fi
}

start_etcd() { 
  cd $GOPATH/src/k8s.io/kubernetes
  ./hack/install-etcd.sh
  export PATH=$PATH:/root/go/src/k8s.io/kubernetes/third_party/etcd

  if [[ ! `grep "kubernetes/third_party/etcd" ~/.bash_profile` ]]; then
    echo 'export PATH=$GOPATH/src/k8s.io/kubernetes/third_party/etcd:${PATH}' >> ~/.bash_profile
  fi
}

install_kubevirt() { 
  go get -u -d kubevirt.io/kubevirt
  export KUBEVIRT_PROVIDER=local
  
  if [[ ! `grep "KUBEVIRT_PROVIDER" ~/.bash_profile` ]]; then
    echo 'export KUBEVIRT_PROVIDER=local' >> ~/.bash_profile
  fi  
}

make_cluster_up(){

  INACTIVITY_TIMEOUT=30
  CLUSTER_UP=0
  TIMEOUT_COUNT=0

  touch $CLUSTER_UP_LOG

  export KUBEVIRT_PROVIDER=local
  cd $GOPATH/src/kubevirt.io/kubevirt

  #make cluster-up |tee  $CLUSTER_UP_LOG  &
  (make cluster-up & echo $! >&3) 3>/tmp/make_pid | tee $CLUSTER_UP_LOG
  
  echo "Waiting for up status"

  timeout 120 grep -m 1 "Local Kubernetes cluster is running" <( tail -f $CLUSTER_UP_LOG )
  result=$?
  
  # TODO: the cluster seems to need a little extra time
  sleep 5
  return $result
}

deploy_sriov_services() { 
  go get -u -d github.com/intel/multus-cni
  cd $GOPATH/src/github.com/intel/multus-cni/
  # change multus image to snapshot
  sed -i 's/multus:latest/multus:snapshot/' images/multus-daemonset.yml
  mkdir -p /etc/cni/net.d
  cp images/70-multus.conf /etc/cni/net.d/

  cd $GOPATH/src/kubevirt.io/kubevirt
  ./cluster/kubectl.sh create -f $GOPATH/src/github.com/intel/multus-cni/images/multus-daemonset.yml
  ./cluster/kubectl.sh create -f $GOPATH/src/github.com/intel/multus-cni/images/flannel-daemonset.yml
}

sriov_device_plugin() { 
  cd $GOPATH/src/kubevirt.io/kubevirt
  go get -u -d github.com/intel/sriov-network-device-plugin/
  
  get_sriov_pci_addresses
  create_pci_string  
  
  mkdir -p /etc/pcid
  cat <<EOF > /etc/pcidp/config.json
{
    "resourceList":
    [
        {
            "resourceName": "sriov",
            "rootDevices": [$pci_string],
            "sriovMode": true,
            "deviceType": "vfio"
        }
    ]
}
EOF
  ./cluster/kubectl.sh create -f $GOPATH/src/github.com/intel/sriov-network-device-plugin/images/sriovdp-daemonset.yaml

  go get -u -d github.com/intel/sriov-cni/
  ./cluster/kubectl.sh create -f $GOPATH/src/github.com/intel/sriov-cni/images/sriov-cni-daemonset.yaml
  ./cluster/kubectl.sh  create -f $GOPATH/src/github.com/intel/sriov-network-device-plugin/deployments/sriov-crd.yaml

}

update_kubeconfig() { 
  cd $GOPATH/src/kubevirt.io/kubevirt
  ./cluster/kubectl.sh patch configmap kubevirt-config -n kubevirt --patch "data:
  feature-gates: DataVolumes, CPUManager, LiveMigration, SRIOV"

  # Restart pods to read new kube-config
  ./cluster/kubectl.sh get pods -n kubevirt |grep virt |awk '{print$1}' |xargs ./cluster/kubectl.sh delete pods -n kubevirt

}

update_kubevirt_sriov_vmi() { 
  cd $GOPATH/src/kubevirt.io/kubevirt
  sed -i 's/networkName: sriov-net/networkName: sriov-net1/' ./cluster/examples/vmi-sriov.yaml
  sed -i 's/registry:5000\/kubevirt/kubevirt/' ./cluster/examples/vmi-sriov.yaml
}


trap cleanup EXIT

configure_sriov_on_os
os_setup
install_network_plugins
install_kubernetes
start_etcd
install_kubevirt

echo "MAKE CLUSTER_UP"

make_cluster_up


if [ $? -ne 0 ]; then
  echo "ERROR 'make cluster-up' failed. Exiting"
  exit 1
fi

echo "CLUSTER UP DONE"

deploy_sriov_services
sriov_device_plugin

make cluster-sync

update_kubeconfig
update_kubevirt_sriov_vmi

echo "Press any key"
# TODO: tests should go here
read x

echo "Key pressed! Exiting"



