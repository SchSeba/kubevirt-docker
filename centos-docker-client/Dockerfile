FROM centos

RUN yum install -y yum-utils \
  device-mapper-persistent-data \
  lvm2

RUN yum-config-manager \
    --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo

RUN yum install -y docker-ce

RUN mkdir /kubevirt

WORKDIR /kubevirt

ENTRYPOINT ["cluster/k8s-1.13.0-sriov/dind-cluster-v1.13.sh"]