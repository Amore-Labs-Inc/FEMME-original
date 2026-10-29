#!/usr/bin/env bash
# Move the box to another AWS region by copying its disk: image the root volume, copy the image,
# launch it there with the same instance profile, same user, same paths. Nothing on the box is
# rebuilt. Run from the laptop checkout, logged in to AWS (aws login), like provision.sh.
#
#   ./migrate-region.sh status     what exists in both regions
#   ./migrate-region.sh prewarm    no downtime: a first image + copy (the cutover copy is then incremental),
#                                  the security group and the Elastic IP in the new region
#   ./migrate-region.sh cutover    stop the box, image it, copy, launch, verify by IP, then DNS
#   ./migrate-region.sh laptop     ~/.ssh/config, known_hosts, .env and the allowlists → the new IP
#   ./migrate-region.sh rollback   start the old box again and point everything back at it
#   ./migrate-region.sh cleanup    a week later: terminate the old box, release its IP, drop old images
#
# Every step finds what it already made (tag Name=femme, femme:role=...) and skips it, so a rerun
# continues where it stopped. FROM/TO/TYPE/PROFILE override the defaults below.
set -euo pipefail
cd "$(dirname "$0")"
. ./.env
FROM=${FROM:-$REGION}
TO=${TO:-eu-central-1}
TYPE=${TYPE:-$INSTANCE_TYPE}
PROFILE=${PROFILE:-agentbox-s3}                 # the instance profile the box runs as today (IAM is global)
ALLOWLIST_REGIONS=${ALLOWLIST_REGIONS:-eu-north-1 eu-west-1 us-east-1 eu-west-2 eu-central-1}  # other servers that allowlist the box's IP
DOMAIN=${BOARD_URL#https://}
from() { command aws --region "$FROM" --output text "$@"; }
to() { command aws --region "$TO" --output text "$@"; }
at() { command aws --region "$1" --output text "${@:2}"; }
say() { printf '\033[1m%s\033[0m\n' "$*" >&2; }   # stderr: functions print their result on stdout
die() { echo "migrate: $*" >&2; exit 1; }
setenv() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
tags() { local r; r="ResourceType=$1,Tags=[{Key=Name,Value=femme}"; [ -n "${2:-}" ] && r+=",{Key=femme:role,Value=$2}"; echo "$r]"; }

instance() {  # <region>: the box there, "None" if none
  at "$1" ec2 describe-instances --filters Name=tag:Name,Values=femme Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].InstanceId'
}
state() { at "$1" ec2 describe-instances --instance-ids "$2" --query 'Reservations[0].Instances[0].State.Name'; }
image() {  # <region> <role>: our image with that role, "None" if none
  at "$1" ec2 describe-images --owners self --filters "Name=tag:femme:role,Values=$2" Name=state,Values=pending,available \
    --query 'Images[0].ImageId'
}
wait_image() {  # <region> <image>: until available; no time limit, a 235 GB first copy takes an hour
  local s t=0
  while s=$(at "$1" ec2 describe-images --image-ids "$2" --query 'Images[0].State'); [ "$s" != available ]; do
    [ "$s" = pending ] || die "image $2 in $1 is $s"
    sleep 30; t=$((t + 30)); [ $((t % 300)) -eq 0 ] && echo "  still $s after $((t / 60)) min"
  done
}
make_image() {  # <role>: image the FROM box (no reboot: a stopped box gives a consistent image, a running one a warm-up)
  local id; id=$(image "$FROM" "$1")
  if [ "$id" = None ]; then
    id=$(from ec2 create-image --instance-id "$OLD" --name "femme-$1-$(date +%Y%m%d-%H%M)" --no-reboot \
      --tag-specifications "$(tags image "$1")" "$(tags snapshot "$1")" --query ImageId)
    say "imaging $OLD in $FROM: $id"
  fi
  wait_image "$FROM" "$id"; echo "$id"
}
copy_image() {  # <role> <source image>: its copy in TO
  local id; id=$(image "$TO" "$1-copy")
  if [ "$id" = None ]; then
    id=$(to ec2 copy-image --source-region "$FROM" --source-image-id "$2" --name "femme-$1-copy-$(date +%Y%m%d-%H%M)" \
      --tag-specifications "$(tags image "$1-copy")" "$(tags snapshot "$1-copy")" --query ImageId)
    say "copying $2 to $TO: $id"
  fi
  wait_image "$TO" "$id"; echo "$id"
}
sg() {  # the femme security group in TO, created like provision.sh does
  local id; id=$(to ec2 describe-security-groups --filters Name=group-name,Values=femme --query 'SecurityGroups[0].GroupId')
  if [ "$id" = None ]; then
    id=$(to ec2 create-security-group --group-name femme --description "femme ssh + mosh" --query GroupId)
    to ec2 authorize-security-group-ingress --group-id "$id" --ip-permissions \
      'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]' \
      'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' \
      'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' \
      'IpProtocol=udp,FromPort=60000,ToPort=61000,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
    say "security group femme in $TO: $id"
  fi
  echo "$id"
}
eip() {  # <region>: "<allocation> <ip>" of the femme Elastic IP there, allocating in TO only
  local a; a=$(at "$1" ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].[AllocationId,PublicIp]')
  if [ "$a" = None ] || [ "$a" = "None	None" ]; then
    [ "$1" = "$TO" ] || die "no femme Elastic IP in $1"
    a=$(to ec2 allocate-address --domain vpc --tag-specifications "$(tags elastic-ip)" --query '[AllocationId,PublicIp]')
    say "Elastic IP in $TO: ${a#*	}"
  fi
  echo "$a"
}
hostkey() { ssh-keyscan -t ed25519 -T 10 "$1" 2>/dev/null | awk '$2 == "ssh-ed25519" {print $2, $3; exit}'; }
oldkey() { ssh-keygen -F "$1" -f ~/.ssh/known_hosts 2>/dev/null | awk '$2 == "ssh-ed25519" {print $2, $3; exit}'; }
same_host() {  # <old ip> <new ip>: the new box answers with the old box's host key (it is the same disk)
  local o n; o=$(oldkey "$1"); n=$(hostkey "$2")
  [ -n "$n" ] || die "$2 does not answer on ssh yet"
  [ -z "$o" ] && { echo "  (no known_hosts entry for $1 to compare with)"; return; }
  [ "$o" = "$n" ] || die "host key of $2 differs from $1's: not our disk, or cloud-init regenerated the keys. Stop here."
  echo "  host key unchanged"
}

OLD=$(instance "$FROM"); NEW=$(instance "$TO")

case ${1:-} in
status)
  echo "$FROM: box $OLD ($([ "$OLD" = None ] || state "$FROM" "$OLD")), ip $(from ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].PublicIp'), images prewarm=$(image "$FROM" prewarm) cutover=$(image "$FROM" cutover)"
  echo "$TO: box $NEW ($([ "$NEW" = None ] || state "$TO" "$NEW")), ip $(to ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].PublicIp'), sg $(to ec2 describe-security-groups --filters Name=group-name,Values=femme --query 'SecurityGroups[0].GroupId'), images prewarm=$(image "$TO" prewarm-copy) cutover=$(image "$TO" cutover-copy)"
  echo "dns: $DOMAIN → $(getent hosts "$DOMAIN" | awk '{print $1}')"
  ;;

prewarm)
  [ "$OLD" != None ] || die "no box tagged femme in $FROM"
  [ -n "$(to ec2 describe-instance-type-offerings --filters "Name=instance-type,Values=$TYPE" --query 'InstanceTypeOfferings[].InstanceType')" ] \
    || die "$TYPE is not offered in $TO"
  say "1/3 image of the running box (warm-up: the cutover image is then incremental)"
  src=$(make_image prewarm)
  say "2/3 copy to $TO (first copy is full: an hour for 235 GB)"
  copy_image prewarm "$src" >/dev/null
  say "3/3 security group and Elastic IP in $TO"
  sg >/dev/null; read -r _ ip < <(eip "$TO")
  say "ready for cutover. The box will be $ip in $TO. Nothing changed for the running box."
  ;;

cutover)
  [ "$OLD" != None ] || die "no box tagged femme in $FROM"
  read -r alloc ip < <(eip "$TO"); sgid=$(sg)
  oldip=$(from ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].PublicIp')
  if [ "$NEW" = None ]; then
    s=$(state "$FROM" "$OLD")
    if [ "$s" = running ] || [ "$s" = pending ]; then
      say "1/5 stopping $OLD in $FROM (clean shutdown; agents, board and API are down from here)"
      from ec2 stop-instances --instance-ids "$OLD" >/dev/null
    fi
    from ec2 wait instance-stopped --instance-ids "$OLD"
    say "2/5 consistent image of the stopped box"
    src=$(make_image cutover)
    say "3/5 copy to $TO$([ "$(image "$TO" prewarm-copy)" = None ] && echo ' (no prewarm: this is the full hour)' || echo ' (incremental)')"
    ami=$(copy_image cutover "$src")
    say "4/5 launching in $TO"
    userdata=$(mktemp); trap 'rm -f "$userdata"' EXIT
    cat > "$userdata" <<'EOF'
#cloud-config
hostname: agentbox
preserve_hostname: true
ssh_deletekeys: false
users: []
package_update: false
package_upgrade: false
EOF
    sed -i "s/^hostname: .*/hostname: $HOST/" "$userdata"
    NEW=$(to ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --security-group-ids "$sgid" \
      --iam-instance-profile "Name=$PROFILE" --user-data "file://$userdata" \
      --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled --disable-api-termination \
      --tag-specifications "$(tags instance)" "$(tags volume)" --query 'Instances[0].InstanceId')
    echo "  $NEW"
  else
    say "box $NEW already exists in $TO: continuing from there"
  fi
  to ec2 wait instance-running --instance-ids "$NEW"
  [ "$(to ec2 describe-instances --instance-ids "$NEW" --query 'Reservations[0].Instances[0].PublicIpAddress')" = "$ip" ] \
    || to ec2 associate-address --instance-id "$NEW" --allocation-id "$alloc" >/dev/null
  say "5/5 waiting for the status checks, then verifying over ssh at $ip"
  to ec2 wait instance-status-ok --instance-ids "$NEW" || to ec2 wait instance-status-ok --instance-ids "$NEW"   # a 500 GB disk from a snapshot boots slowly
  same_host "$oldip" "$ip"
  kh=$(mktemp); trap 'rm -f "$userdata" "$kh"' EXIT; ssh-keyscan -T 10 "$ip" > "$kh" 2>/dev/null
  ssh -o UserKnownHostsFile="$kh" -o ControlMaster=no -o ControlPath=none -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 "$USER@$ip" '
    set -u; fail=0
    echo "  hostname: $(hostname)"; [ "$(hostname)" = '"$HOST"' ] || fail=1
    for u in femme-board herdr-server herdr-instinct femme-worker femme-cswap femme-fable-cap femme-deploy.timer; do
      s=$(systemctl --user is-active "$u"); echo "  $u: $s"; [ "$s" = active ] || fail=1
    done
    echo "  board: $(curl -s -m 5 127.0.0.1:8787/api/ping || echo no-answer)"
    echo "  aws: $(aws sts get-caller-identity --query Arn --output text 2>&1 | cut -c1-90) region $(aws configure list 2>/dev/null | awk "/region/{print \$2}")"
    echo "  claude accounts: $(cswap list --json 2>/dev/null | jq ".accounts | length")"
    echo "  swap: $(swapon --show --noheadings | awk "{print \$3}")  disk: $(df -h / | awk "NR==2{print \$3\" used of \"\$2}")"
    echo "  stray ubuntu user: $(id ubuntu >/dev/null 2>&1 && echo yes || echo no)"
    exit $fail' || die "the new box failed a check above. The old one is stopped and untouched: ./migrate-region.sh rollback"
  say "new box is good. Now in Cloudflare set the A record $DOMAIN → $ip (DNS only), then press Enter"
  read -r _
  for _ in $(seq 60); do [ "$(getent hosts "$DOMAIN" | awk '{print $1}')" = "$ip" ] && break; sleep 10; done
  [ "$(getent hosts "$DOMAIN" | awk '{print $1}')" = "$ip" ] || die "$DOMAIN still does not resolve to $ip; run ./migrate-region.sh laptop once it does"
  echo "  https://$DOMAIN/login: $(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$DOMAIN/login")"
  say "done. Next: ./migrate-region.sh laptop"
  ;;

laptop|rollback)
  if [ "$1" = rollback ]; then
    [ "$OLD" != None ] || die "no box in $FROM to go back to"
    [ "$(state "$FROM" "$OLD")" = running ] || { say "starting $OLD in $FROM"; from ec2 start-instances --instance-ids "$OLD" >/dev/null; from ec2 wait instance-status-ok --instance-ids "$OLD"; }
    [ "$NEW" = None ] || { say "stopping $NEW in $TO"; to ec2 stop-instances --instance-ids "$NEW" >/dev/null; }
    read -r _ ip < <(eip "$FROM"); other=$(to ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].PublicIp'); region=$FROM
    say "in Cloudflare set the A record $DOMAIN → $ip, then press Enter"; read -r _
  else
    read -r _ ip < <(eip "$TO"); other=$(from ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].PublicIp'); region=$TO
  fi
  say "1/5 ~/.ssh/config: Host $HOST → $ip"
  cp ~/.ssh/config ~/.ssh/config.bak-"$(date +%Y%m%d-%H%M%S)"
  awk -v h="$HOST" -v ip="$ip" '/^Host /{in_block = ($2 == h)} in_block && $1 == "HostName" {sub($2, ip)} {print}' ~/.ssh/config > ~/.ssh/config.new \
    && mv ~/.ssh/config.new ~/.ssh/config && chmod 600 ~/.ssh/config
  grep -A1 "^Host $HOST\$" ~/.ssh/config | sed 's/^/  /'
  say "2/5 known_hosts: $ip gets the host key $other had"
  [ "$other" = None ] || same_host "$other" "$ip"
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  ssh-keyscan -T 10 "$ip" 2>/dev/null | grep -v '^#' >> ~/.ssh/known_hosts
  say "3/5 the links: ssh, femme-link, Mutagen, herdr"
  ssh -o ControlMaster=no -o ControlPath=none "$HOST" true && echo "  ssh $HOST: ok"
  systemctl --user restart femme-link 2>/dev/null && echo "  femme-link restarted" || echo "  femme-link: not installed here"
  command -v mutagen >/dev/null && { sleep 3; echo "  mutagen: $(mutagen sync list 2>/dev/null | grep -c '^Name:') sessions, $(mutagen sync list 2>/dev/null | grep -c 'Status: Watching') watching"; }
  command -v herdr >/dev/null && herdr machine status 2>/dev/null | sed 's/^/  /' | head -4
  say "4/5 .env: REGION=$region IP=$ip (sync.sh carries it; provision.sh is not to be run)"
  setenv REGION "$region"; setenv IP "$ip"
  say "5/5 allowlists on other servers: every rule for $other/32 gets a twin for $ip/32"
  for r in $ALLOWLIST_REGIONS; do
    at "$r" ec2 describe-security-group-rules --query "SecurityGroupRules[?CidrIpv4=='$other/32' && !IsEgress].[GroupId,IpProtocol,FromPort,ToPort]" 2>/dev/null \
      | while read -r g p f t; do
        [ -n "$g" ] || continue
        at "$r" ec2 authorize-security-group-ingress --group-id "$g" --ip-permissions "IpProtocol=$p,FromPort=$f,ToPort=$t,IpRanges=[{CidrIp=$ip/32,Description=femme}]" >/dev/null 2>&1 \
          && echo "  $r $g $p $f-$t: added" || echo "  $r $g $p $f-$t: already there"
      done
  done
  say "phone: in Moshi set the host to $USER@$ip (same key). Done."
  ;;

cleanup)
  [ "$NEW" != None ] && [ "$(state "$TO" "$NEW")" = running ] || die "the box in $TO is not running; not cleaning up"
  [ "$(getent hosts "$DOMAIN" | awk '{print $1}')" = "$(to ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].PublicIp')" ] \
    || die "$DOMAIN does not point at the $TO box; not cleaning up"
  oldip=$(from ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].PublicIp')
  say "This terminates $OLD in $FROM (its 500 GB disk goes with it), releases $oldip and deletes the $FROM images. Type yes to go on:"
  read -r a; [ "$a" = yes ] || exit 1
  if [ "$OLD" != None ]; then
    from ec2 modify-instance-attribute --instance-id "$OLD" --no-disable-api-termination
    from ec2 terminate-instances --instance-ids "$OLD" >/dev/null; from ec2 wait instance-terminated --instance-ids "$OLD"; echo "  $OLD terminated"
  fi
  read -r alloc _ < <(from ec2 describe-addresses --filters Name=tag:Name,Values=femme --query 'Addresses[0].[AllocationId,PublicIp]')
  [ "$alloc" = None ] || { from ec2 release-address --allocation-id "$alloc"; echo "  $oldip released"; }
  for spec in "$FROM prewarm" "$FROM cutover" "$TO prewarm-copy"; do   # the cutover copy in TO stays: the first backup the box ever had
    set -- $spec; id=$(image "$1" "$2"); [ "$id" = None ] && continue
    snaps=$(at "$1" ec2 describe-images --image-ids "$id" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId')
    at "$1" ec2 deregister-image --image-id "$id"; for s in $snaps; do at "$1" ec2 delete-snapshot --snapshot-id "$s"; done
    echo "  $1 $id deregistered"
  done
  say "allowlists: dropping $oldip/32"
  for r in $ALLOWLIST_REGIONS; do
    at "$r" ec2 describe-security-group-rules --query "SecurityGroupRules[?CidrIpv4=='$oldip/32' && !IsEgress].[GroupId,SecurityGroupRuleId]" 2>/dev/null \
      | while read -r g rid; do [ -n "$g" ] && at "$r" ec2 revoke-security-group-ingress --group-id "$g" --security-group-rule-ids "$rid" >/dev/null && echo "  $r $g: removed"; done
  done
  say "done. Keep the $TO cutover image a month, then: aws ec2 deregister-image + delete-snapshot"
  ;;

*) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
