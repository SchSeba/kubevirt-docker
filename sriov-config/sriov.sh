#!/bin/bash

#set -x

echo "#########################################"
echo "############## STARTING SRIOV ###########"
echo "#########################################"

SRIOV_IGB_MAX_VFS=7

get_sriov_pci_addresses() {

  # TODO: this is very fragile
  pci_addresses=($(lspci |grep "Ethernet controller" |grep $SRIOV_IFC_NAME | grep -v Virtual | awk '{print$1}'))
}

create_pci_string() {
  local quoted_values=($(echo "${pci_addresses[@]}" | xargs printf "\"%s\" "  ))
  local quoted_as_string=${quoted_values[@]}
  pci_string=${quoted_as_string// /, }
}

sriov_device_plugin() {
  get_sriov_pci_addresses
  create_pci_string

  cat <<EOF > /host/etc/pcidp/config.json
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
}

sriov_device_plugin