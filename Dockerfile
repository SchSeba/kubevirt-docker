FROM mirantis/kubeadm-dind-cluster:596f7d093470c1dc3a3e4466bcdfb34438a99b90-v1.13
MAINTAINER sebassch@gmail.com

RUN apt-get update && apt-get install wget tar git make -y

# Install Go
RUN wget -O /tmp/golang.tar.gz "https://dl.google.com/go/go1.11.4.linux-amd64.tar.gz"; \
    tar -C /usr/local -xzf /tmp/golang.tar.gz

ENV PATH "$PATH:/usr/local/go/bin"

RUN mkdir -p /go/src/kubevirt.io/kubevirt
WORKDIR /go/src/kubevirt.io/kubevirt

ENV GOPATH "/go/"

COPY localstore /usr/local/bin/localstore