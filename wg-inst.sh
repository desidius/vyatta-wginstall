#!/bin/vbash
if [ "$EUID" -eq 0 ]
	then echo "Please do not run as root" #View vyatta docs regarding configuration as root then remove this check if you wish
	exit
fi

# There's no real validation for anything here..
# Router Model, Router FW, Router Firewall Rule# and WG interface have to be changed in this file for now.

#Used to enter configuration and adding rules
run="/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper"

#Router defaults
router_external_ip=$(curl -s http://whatismyip.akamai.com/) #Get external IP of router
router_model=$(cat /etc/version | grep -oP 'e[0-9]{2,3}') #This is most likely not a catchall
router_fw=$(cat /etc/version | grep -oP "(v[0-9]{1})") #Check device firmware, same as above - This has to be changed manually if autodetection does not work

#WireGuard Defaults
wg_package_installed=$(dpkg-query -s wireguard 2>/dev/null | grep -c "ok installed") #Check DPKG for installation status
wg_package_version=$(dpkg -s wireguard | grep '^Version:' | awk '{print $2}') #Check DPKG for WG version
wg_port=51820 #Default WG port
wg_interface_ip=10.0.0.1
wg_interface=0 #Default WG interface number (wg#)
wg_rule=15

if [[ $router_fw == "v2" ]]; then git_router_fw="v2.0-"; fi #Not a good fix
git_package_latest=$(curl --silent "https://api.github.com/repos/Lochnair/vyatta-wireguard/releases" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
git_download_path="https://github.com/Lochnair/vyatta-wireguard/releases/download/"
git_deb_file=wireguard-${git_router_fw}${router_model}-${git_package_latest}.deb
git_deb_path=${git_download_path}${git_package_latest}/${git_deb_file}


wg_cfg() {
	case $1 in
		host)
			echo "Configuring interface ${wg_interface_ip}/24:${wg_port} on wg${wg_interface}"

			if [[ $(ls /sys/class/net/ | grep -c "wg${wg_interface}") -eq 1 ]]; then 
				echo -e "\033[0;31mInterface wg${wg_interface} is already configured\033[0m"
				echo "Stopping.."
				echo
				exit 1
			fi
			$run begin
			$run set interfaces wireguard wg${wg_interface} address ${wg_interface_ip}/24
			$run set interfaces wireguard wg${wg_interface} listen-port ${wg_port}
			$run set interfaces wireguard wg${wg_interface} route-allowed-ips true
			$run set interfaces wireguard wg${wg_interface} private-key /config/auth/wg-private.key
			$run commit
			$run save
			$run end
		;;
		firewall)
			echo "Adding firewall rule ${wg_rule} for WireGuard"
			$run begin
			$run set firewall name WAN_LOCAL rule 15 action accept
			$run set firewall name WAN_LOCAL rule 15 protocol udp
			$run set firewall name WAN_LOCAL rule 15 description 'WireGuard'
			$run set firewall name WAN_LOCAL rule 15 destination port ${wg_port}
			$run commit
			$run save
			$run end
		;;
		peer)
			echo "Adding peer ${peer_ip}/32 with publick key ${peer_public_key} to interface ${wg_interface}"
			$run begin
			$run set interfaces wireguard wg${wg_interface} peer ${peer_public_key} allowed-ips ${peer_ip}/32
			$run commit
			$run save
			$run end
			echo -e "\e[1;32mPeer added\033[0m"
			echo
			exit 0
		;;
		view)
			echo -e "\nDevice information and default configuration"
			echo -e "Model:		${router_model}\nFirmware:	${router_fw}\nExternal IP:	${router_external_ip}\nWG port:	${wg_port}\nWG interface:	wg${wg_interface}\nWG interf. IP:	${wg_interface_ip}"
		;;
		package)
			echo -e "\e[1;32mLatest WireGuard version is: ${wg_package_version}\033[0m"
			if [[ $wg_package_installed -eq 1 ]]; then
				echo -e "\033[0;31mWireGuard version ${wg_package_version} is installed\033[0m"
				read -r -p "Do you with to continue to (re)Install the package [y/N] " response
				case "$response" in
					[yY][eE][sS]|[yY]) 
						wg_install_deb=1
						;;
					*)
						echo "Package installation will be skipped"
						wg_install_deb=0
						;;
				esac
			fi
			if  [[ $wg_install_deb -eq 1 ]]; then 

				$deb_http_response=$(curl -w %{http_code} -s -I -o /dev/null $git_deb_path)
				if [ $deb_http_response == "404" ]; then
					echo Package was not found on git, please verify that VERSION and FIRMWARE are correct.
					echo This might mean a package does not exist for your current setup.
					echo For more information visit https://github.com/Lochnair/vyatta-wireguard/releases/

					cd /tmp
					curl -s -L -O $debpath
					sudo dpkg -i $deb && rm -f $deb #change SUDO?
			fi
		;;
	esac
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

help() {
echo "Optional, run script to install with defaults.
		-h              | Displays this text
		-a [ip]			| Peer IP to add, use with -x
		-x [pubkey]		| Client public key
        -i [ip]         | IP of interface
		-p [port]		| listening port of server"
}


if [ $# -eq 0 ]
	then
	help
fi

while getopts ":a:f:hi:m:v:" opt; do
  case $opt in
	a)
		if valid_ip $OPTARG; then
			peer_ip=$OPTARG
		else
			echo "Please use a valid ip in the form 10.0.0.1" >&2
			exit
		fi
		;;
    h)
		help
        exit
        ;;
	i)
		if valid_ip $OPTARG; then
			wg_interface_ip=$OPTARG 
			peer_allowed_ips=$(echo $OPTARG | cut -d"." -f1-3).0
		else
			echo "Please use a valid ip in the form 10.0.0.1" >&2
			exit
		fi
	;;
	p)
		if [[ $OPTARG =~ ^[0-9]+$ ]]; then
			wg_port=$OPTARG
		else
			echo "Port is not a valid number"
			exit 1
		fi
	;;
	x)
	if [[ ${#OPTARG} != 44 ]]; then #Might have to change this
		echo "Please enter a proper public key" >&2
		exit
	else
		peer_public_key=$OPTARG
	fi
	;;
	\?) echo "Invalid option, use -h for help" >&2
	;;
  esac
done

#Add peer
if [[ ! -z "$peer_public_key" && ! -z "$peer_ip" ]]; then
	wg_cfg peer
fi



#Generate Keys after install
wg genkey | tee /config/auth/wg-private.key | wg pubkey | tee /config/auth/wg-public.key
#Store public key in var so it does not need to be called again
wg_public_key=$(head -n 1 /config/auth/wg-public.key)

#Create an example client config
peer_config="[Interface]
Address = 10.0.0.$(cat /dev/urandom | tr -dc '0-9' | fold -w 2 | head -n 1)/32
PrivateKey = $(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 44 | head -n 1)

[Peer]
AllowedIPs = ${peer_allowed_ips}/24
Endpoint = ${router_external_ip}:51820
PublicKey = ${wg_public_key}"

mkdir -p /config/wireguard
echo "$peer_config" > /config/wireguard/wg${wg_interface}-peer.config
chmod 775 -R /config/wireguard/


fi
echo
echo
echo -e "Server Public key is \e[1;32m${wg_public_key}\e[0m"
echo "Generated keys can be found in /config/auth/"
echo 
echo "To add peers simply use the script with the following arguments:
$0 -a [Peer IP] -x [Peer public key]" 
echo 
echo "Sample client configuration (also stored in config folder):"
echo "${peer_config}"