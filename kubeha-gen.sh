#!/usr/bin/env bash
#/bin/bash

if [ -f ./cluster-info ]; then
	source ./cluster-info 
fi

masterList=(${MASTER//,/ })
nodeList=(${NODE//,/ })

echo """
cluster-info:
$(for data in ${!masterList[@]};do echo "  "master-${data}:"         "${masterList[${data}]};done)
$(for data in ${!nodeList[@]};do echo "  "node-${data}:"           "${nodeList[${data}]};done)
  VIP:              ${VIP}
  Net Interface:    ${NET_IF}
  CIDR:             ${CIDR}
"""
echo -n 'Please print "yes" to continue or "no" to cancel: '
read AGREE
while [ "${AGREE}" != "yes" ]; do
	if [ "${AGREE}" == "no" ]; then
		exit 0;
	else
		echo -n 'Please print "yes" to continue or "no" to cancel: '
		read AGREE
	fi
done

mkdir -p ~/ikube/tls

STATE=()
for index in ${!masterList[@]};do
    if [ ${index} -eq 0 ];then
     STATE+=( "MASTER" )
    else
     STATE+=( "BACKUP" )
    fi
done

HEALTH_CHECK=""
for index in ${!masterList[@]}; do
  HEALTH_CHECK=${HEALTH_CHECK}"""
    real_server ${masterList[$index]} 6443 {
        weight 1
        SSL_GET {
            url {
              path /healthz
              status_code 200
            }
            connect_timeout 3
            nb_get_retry 3
            delay_before_retry 3
        }
    }
"""
done

for index in ${!masterList[@]}; do
  ip=${masterList[${index}]}
  echo """
global_defs {
   router_id LVS_DEVEL
}

vrrp_instance VI_1 {
    state ${STATE[${index}]}
    interface ${NET_IF}
    virtual_router_id 80
    priority 50
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass just0kk
    }
    virtual_ipaddress {
        ${VIP}
    }
}

virtual_server ${VIP} 6443 {
    delay_loop 6
    lb_algo loadbalance
    lb_kind DR
    nat_mask 255.255.255.0
    persistence_timeout 0
    protocol TCP

${HEALTH_CHECK}
}
""" > ~/ikube/keepalived-${index}.conf
  scp ~/ikube/keepalived-${index}.conf ${ip}:/etc/keepalived/keepalived.conf

  ssh ${ip} "
    systemctl stop keepalived
    systemctl enable keepalived
    systemctl start keepalived
    kubeadm reset -f
    rm -rf /etc/kubernetes/pki/"
done

mkdir -p /etc/kubernetes/pki

echo """
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: v1.13.0
controlPlaneEndpoint: "${VIP}:6443"
apiServer:
  certSANs:
$(for data in ${masterList[@]};do echo "  "- ${data};done)
  - ${VIP}
networking:
  # This CIDR is a Calico default. Substitute or remove for your CNI provider.
  podSubnet: ${CIDR}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
""" > /etc/kubernetes/kubeadm-config.yaml

openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -days 10000 -out ca.crt -subj "/CN=kubernetes/O=k8s"
mv ca.key /etc/kubernetes/pki
mv ca.crt /etc/kubernetes/pki
docker load -i k8s-offline-images.tar
kubeadm init --config /etc/kubernetes/kubeadm-config.yaml
mkdir -p ${HOME}/.kube
cp -f /etc/kubernetes/admin.conf ${HOME}/.kube/config

kubectl apply -f calico/rbac.yaml
cat calico/calico.yaml | sed "s!8.8.8.8!${masterList[0]}!g" | sed "s!10.244.0.0/16!${CIDR}!g" | kubectl apply -f -

MASTER_JOIN=`kubeadm token create --print-join-command`
for index in ${!masterList[@]}; do
  if [ ${index} -eq 0 ];then
   echo "ignore master-0"
  else
   ip=${masterList[${index}]}
   ssh ${ip} "mkdir -p /etc/kubernetes/pki/etcd; mkdir -p ~/.kube/;"
   scp /etc/kubernetes/pki/ca.crt $ip:/etc/kubernetes/pki/ca.crt
   scp /etc/kubernetes/pki/ca.key $ip:/etc/kubernetes/pki/ca.key
   scp /etc/kubernetes/pki/sa.key $ip:/etc/kubernetes/pki/sa.key
   scp /etc/kubernetes/pki/sa.pub $ip:/etc/kubernetes/pki/sa.pub
   scp /etc/kubernetes/pki/front-proxy-ca.crt $ip:/etc/kubernetes/pki/front-proxy-ca.crt
   scp /etc/kubernetes/pki/front-proxy-ca.key $ip:/etc/kubernetes/pki/front-proxy-ca.key
   scp /etc/kubernetes/pki/etcd/ca.crt $ip:/etc/kubernetes/pki/etcd/ca.crt
   scp /etc/kubernetes/pki/etcd/ca.key $ip:/etc/kubernetes/pki/etcd/ca.key
   scp /etc/kubernetes/admin.conf $ip:/etc/kubernetes/admin.conf
   scp /etc/kubernetes/admin.conf $ip:~/.kube/config

   ssh ${ip} "${MASTER_JOIN} --experimental-control-plane"
  fi
done

echo """$(kubeadm token create --print-join-command)""" > add.sh
for index in ${!nodeList[@]}; do
    ip=${nodeList[${index}]}
    scp add.sh $ip:~/
    scp k8s-offline-images.tar $ip:~/
    ssh ${ip} "docker load -i ~/k8s-offline-images.tar"
    ssh ${ip} "chmod +x ~/add.sh;sh add.sh"
done

echo "Cluster create finished."
echo """
[req]
distinguished_name = req_distinguished_name
prompt = yes

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
countryName_value               = CN

stateOrProvinceName             = State or Province Name (full name)
stateOrProvinceName_value       = SiChuan

localityName                    = Locality Name (eg, city)
localityName_value              = Chendu

organizationName                = Organization Name (eg, company)
organizationName_value          = BBDSoftware

organizationalUnitName          = Organizational Unit Name (eg, section)
organizationalUnitName_value    = Kunlun Department

commonName                      = Common Name (eg, your name or your server\'s hostname)
commonName_value                = craftli.io

emailAddress                    = Email Address
emailAddress_value              = l453595892@gmail.com
""" > ~/ikube/tls/openssl.cnf
openssl req -newkey rsa:4096 -nodes -config ~/ikube/tls/openssl.cnf -days 3650 -x509 -out ~/ikube/tls/tls.crt -keyout ~/ikube/tls/tls.key
kubectl create -n kube-system secret tls ssl --cert ~/ikube/tls/tls.crt --key ~/ikube/tls/tls.key
kubectl apply -f plugin/traefik.yaml



echo "Plugin install finished."
echo "Waiting for all pods into 'Running' status. You can press 'Ctrl + c' to terminate this waiting any time you like."
POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
while [ "${POD_UNREADY}" != "" -o "${NODE_UNREADY}" != "" ]; do
  sleep 1
  POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
  NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
done

echo

kubectl get cs
kubectl get nodes
kubectl get pods -n kube-system
