#!/usr/bin/env bash
# Create the VPS on AWS (default VPC). Safe to rerun: reuses everything tagged femme.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || cp .env.example .env
. ./.env
aws() { command aws --region "$REGION" --output text "$@"; }
setenv() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=femme}]"; }

[ -n "$NTFY_TOPIC" ] || { NTFY_TOPIC=femme-$(openssl rand -hex 16); setenv NTFY_TOPIC "$NTFY_TOPIC"; }

[ -n "$(aws ec2 describe-instance-type-offerings --filters "Name=instance-type,Values=$INSTANCE_TYPE" --query 'InstanceTypeOfferings[].InstanceType')" ] \
  || { echo "$INSTANCE_TYPE is not offered in $REGION" >&2; exit 1; }

sg=$(aws ec2 describe-security-groups --filters Name=group-name,Values=femme --query 'SecurityGroups[0].GroupId')
if [ "$sg" = None ]; then
  sg=$(aws ec2 create-security-group --group-name femme --description "femme ssh + mosh" --query GroupId)
  aws ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions \
    'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]' \
    'IpProtocol=udp,FromPort=60000,ToPort=61000,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
fi
if [ -n "${BOARD_URL:-}" ]; then  # board: Caddy needs 80 for the certificate challenge, 443 to serve
  aws ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions \
    'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' \
    'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null 2>&1 || true  # already open
fi

id=$(aws ec2 describe-instances --query 'Reservations[0].Instances[0].InstanceId' \
  --filters Name=tag:Name,Values=femme Name=instance-state-name,Values=pending,running,stopping,stopped)
if [ "$id" = None ]; then
  ami=$(aws ssm get-parameter --query Parameter.Value \
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id)
  userdata=$(mktemp)
  trap 'rm -f "$userdata"' EXIT
  sed -e "s|__USER__|$USER|g" -e "s|__HOST__|$HOST|g" -e "s|__PUBKEY__|$(cat ~/.ssh/id_ed25519.pub)|" cloud-init.yaml > "$userdata"
  id=$(aws ec2 run-instances --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$sg" --user-data "file://$userdata" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3}" \
    --metadata-options HttpTokens=required --disable-api-termination \
    --tag-specifications "$(tag instance)" "$(tag volume)" --query 'Instances[0].InstanceId')
fi
aws ec2 wait instance-running --instance-ids "$id"

read -r alloc ip < <(aws ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].[AllocationId,PublicIp]')
if [ "$alloc" = None ]; then
  read -r alloc ip < <(aws ec2 allocate-address --domain vpc --tag-specifications "$(tag elastic-ip)" --query '[AllocationId,PublicIp]')
fi
aws ec2 associate-address --instance-id "$id" --allocation-id "$alloc" >/dev/null
setenv IP "$ip"

if ! grep -q "^Host $HOST\$" ~/.ssh/config; then
  cat >> ~/.ssh/config <<EOF
Host $HOST
    HostName $ip
    User $USER
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
EOF
fi
echo "$HOST is $ip ($id). Next: ssh $HOST cloud-init status --wait && ./sync.sh"
