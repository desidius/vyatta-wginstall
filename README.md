curl -L -O https://raw.githubusercontent.com/desidius/vyatta-wginstall/master/wg-inst.sh &&
chmod +x wg-inst.sh &&
./wg-inst.sh -h

If you have problems modifying rules i recommend changing route-allowed-ips to false:
set interfaces wireguard wg0 route-allowed-ips false