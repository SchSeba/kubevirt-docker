FROM centos:7

RUN yum update -y && yum install -y pciutils && yum clean all
COPY sriov.sh /sriov.sh

CMD ["/sriov.sh"]