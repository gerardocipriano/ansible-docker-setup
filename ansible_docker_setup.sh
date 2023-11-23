#!/bin/bash

# Check if the number of nodes is passed as an argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 NUMBER_OF_NODES"
    exit 1
fi

NUMBER_OF_NODES=$1

# Debug function
debug_message() {
  echo "[DEBUG] $1"
}

# Dockerfile for the master node
cat <<EOF > Dockerfile_master
FROM debian

# Install Python3, Nano, OpenSSH Server, Ansible, sudo and generate SSH keys
RUN apt-get update && apt-get install -y python3 nano openssh-server ansible sudo && \
    ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/run/sshd && \
    mkdir -p /etc/ansible  # Create the /etc/ansible directory
CMD ["/usr/sbin/sshd", "-D"]
EOF

# Dockerfile for the managed nodes
cat <<EOF > Dockerfile_managed
FROM debian

# Install Python3, Nano, OpenSSH Server, sudo
RUN apt-get update && apt-get install -y python3 nano openssh-server sudo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/run/sshd
CMD ["/usr/sbin/sshd", "-D"]
EOF

# Create Docker images
docker build -t debian-ansible-master - < Dockerfile_master
docker build -t debian-ansible-node - < Dockerfile_managed

# Create the Ansible master node
docker run -d --name ansible-master --hostname ansible-master debian-ansible-master
ansible_master_ip=$(docker inspect -f '{{ .NetworkSettings.IPAddress }}' ansible-master)
debug_message "Ansible master node created. IP Address: $ansible_master_ip"

# Create the Ansible managed nodes based on user input.
for i in $(seq 1 $NUMBER_OF_NODES); do
  node_name="ansible-node-$i"
  docker run -d --name "$node_name" --hostname "$node_name" debian-ansible-node
  node_ip=$(docker inspect -f '{{ .NetworkSettings.IPAddress }}' "$node_name")
  debug_message "Managed node $i created. IP Address: $node_ip"
done

# Configure SSH between the master and managed nodes.
debug_message "Configuring SSH between the master and managed nodes..."
master_ssh_key=$(docker exec ansible-master cat /root/.ssh/id_rsa.pub)
for i in $(seq 1 $NUMBER_OF_NODES); do
  node_name="ansible-node-$i"
  docker exec "$node_name" bash -c "echo $master_ssh_key >> /root/.ssh/authorized_keys"
  debug_message "Master's public key added to $node_name."
done

# Create an Ansible inventory file (added)
cat <<EOF > hosts
[ansible-nodes]
EOF

for i in $(seq 1 $NUMBER_OF_NODES); do 
echo "ansible-node-$i ansible_host=$(docker inspect -f '{{ .NetworkSettings.IPAddress }}' ansible-node-$i)" >> hosts 
done 

# Copy the inventory file to the master node (added)
docker cp hosts ansible-master:/etc/ansible/hosts
# Execute the verification ping between the master and managed nodes with the added inventory.
ansible_master_container_id=$(docker ps -qf "name=ansible-master")
ansible_ping_playbook="---
- hosts: all
  gather_facts: no
  tasks:
  - name: Ping test
    ping:
    vars:
      ansible_ssh_common_args: '-o StrictHostKeyChecking=no'"
docker exec -i "$ansible_master_container_id" sh -c "echo '$ansible_ping_playbook' > /ping_test.yml"
if docker exec -i "$ansible_master_container_id" ansible-playbook /ping_test.yml; then
  echo "Configuration completed."
else
  echo "Configuration not completed due to Ansible playbook execution failure."
fi


# docker cp playbook-example.yml ansible-master:/root/
# docker exec -i ansible-master ansible-playbook /root/playbook-example.yml