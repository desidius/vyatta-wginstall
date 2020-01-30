#!/bin/vbash
run="/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper"

if [ "$EUID" -eq 0 ]
	then echo "Please do not run as root"
	exit
fi

##
## TODO
##
## Fix Key generation, change ownership?
##
## Fix firmware var
## Auto-detection of firmware version
## cat /etc/version | grep -oP '([v][0-9])'


#Default firmware version
firmware="v2.0-"
#Path to git
gitpath="https://github.com/Lochnair/vyatta-wireguard/releases/download/"
#Get the latest version
version=$(curl --silent "https://api.github.com/repos/Lochnair/vyatta-wireguard/releases" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
#External IP
extip=$(curl -s https://ipinfo.io/ip)
#Host port
wgport=51820

devices() {
	echo "
	E50
		EdgeRouter X
	E100
		EdgeRouter Lite
		EdgeRouter PoE
	E200
		EdgeRouter 8
		EdgeRouter Pro
	E300
		EdgeRouter 4
		EdgeRouter 6P
		EdgeRouter 12
	E1000
		EdgeRouter Infinity
	UGW3
		UniFi Security Gateway
	UGW4
		UniFi Security Gateway Pro 4
	UGWXG
		UniFi Security Gateway XG 8"
  exit 2
}

help() {
echo "	-h              | Displays this text
		-a [key]		| Add peer, use with -i
        -i [ip]         | IP address of VPN interface
        -m [model]      | Model version: e100, e200, e300 etc.
        -m [l or list]	| List available models
		-p [port]		| Optional, listening port of server. Default: 51820
        -v [version]    | Optional, latest is installed. Example: 0.0.20191219-2
        -f [1 or 2]   	| Optional, Firmware version. Default v2"
}
usage() {
	echo "Usage: $0 [-i VPN_IP] [ -m MODEL ]"
	echo "For help use -h"
	exit 2
}

function valid_ip() { #https://www.linuxjournal.com/content/validating-ip-address-bash-script
    local  ip=$1
    local stat=1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

#This is not double checked
addpeer() {
	$run begin
	$run set interfaces wireguard wg0 peer ${1} allowed-ips ${2}/32
	$run end
}

if [ $# -eq 0 ]
	then
	usage
fi

while getopts ":a:f:hi:m:v:" opt; do
  case $opt in
	a)
		if [[ ${#OPTARG} != 44 ]]; then
			echo "Please enter peer public key"
			exit
		else
			clkey=$OPTARG
		fi
		;;
	f)
        if [[ $OPTARG =~ ^[1-2]+$ ]];then
            if [ $OPTARG == 1 ]; then
			firmware="" 
		else
			firmware="v2.0-"
		fi
        else
                echo "Firmware version is either 1 or 2"
        fi
        ;;
    h)
		help
        exit
        ;;
	i)
		if valid_ip $OPTARG; then
			ip=$OPTARG 
			servernet=$(echo $OPTARG | cut -d"." -f1-3).0
		else
			echo "Please use a valid ip in the form 10.0.0.1"
			exit
		fi
        ;;
	m)
		if [ $OPTARG == "l" ] || [ $OPTARG == "list" ]
		then
			devices
			exit
		fi
		model=$OPTARG
	;;
	v)
		version=$OPTARG
	;;
	\?) echo "Invalid option -$OPTARG, use -h for help" >&2
	;;
  esac
done

#Add peer
if [$clkey] && [$ip]; then
	addpeer $clkey $ip
fi


if [ -z $model ] || [ -z $ip ]; then
	echo "Please define model, IP"
	exit
fi

#Fetch lates package and install
deb=wireguard-${firmware}${model}-${version}.deb
debpath=${gitpath}${version}/${deb}
status=$(curl -I -s $debpath | head -n 1|cut -d$' ' -f2)

if [ $status == "404" ]; then
	echo Package was not found on git, please verify that VERSION and FIRMWARE are correct.
	echo This might mean a package does not exist for your current setup.
	echo For more information visit https://github.com/Lochnair/vyatta-wireguard/releases/

else
	echo "Fetching deb package and installing"
	echo "Version: ${version}"

	cd /tmp
	curl -s -L -O $debpath
	sudo dpkg -i $deb && rm -f $deb

sudo wg genkey | tee /config/auth/wg-private.key | wg pubkey | tee /config/auth/wg-public.key
#Generate keys
#Store keys and configuration
pubkey=$(head -n 1 /config/auth/wg-public.key)
clientcfg="[Interface]
Address = 10.0.0.$(cat /dev/urandom | tr -dc '0-9' | fold -w 2 | head -n 1)/32
PrivateKey = $(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 44 | head -n 1)

[Peer]
AllowedIPs = ${servernet}/24
Endpoint = ${extip}:51820
PublicKey = ${pubkey}"

mkdir -p /config/wireguard
echo "$clientcfg" > /config/wireguard/wg0-client.config
chmod 775 -R /config/wireguard/

#Start Configuration of Interface and Firewall
configure

#Configure the WireGuard interface
echo "Configuring interface wg0"
$run begin
$run set interfaces wireguard wg0 address ${ip}/24
$run set interfaces wireguard wg0 listen-port ${wgport}
$run set interfaces wireguard wg0 route-allowed-ips true
$run set interfaces wireguard wg0 private-key /config/auth/wg-private.key
#Configure firewall to let connections to WireGuard through
echo "Setting firewall rule for port ${wgport}"
$run set firewall name WAN_LOCAL rule 20 action accept
$run set firewall name WAN_LOCAL rule 20 protocol udp
$run set firewall name WAN_LOCAL rule 20 description 'WireGuard'
$run set firewall name WAN_LOCAL rule 20 destination port ${wgport}
$run commit
$run save
$run end
fi
echo
echo
echo -e "Server Public key is \e[1;32m${pubkey}\e[0m"
echo "Generated keys can be found in /config/wireguard/"
echo 
echo "To add peers simply enter configuration and run:
set interfaces wireguard wg0 peer [Client Public Key] allowed-ips [Client VPN interface IP]/32" 
echo 
echo "Sample client configuration (also stored in config folder):"
echo "${clientcfg}"