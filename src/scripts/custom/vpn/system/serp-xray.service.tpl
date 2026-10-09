# Managed by Serpantinum (x_vpn.sh install). Root service that runs the Xray core with a TUN device.
# Never enabled at boot; started/stopped by the user through the narrow polkit rule.
[Unit]
Description=Serpantinum VPN (Xray core, TUN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
RuntimeDirectory=serp-xray
RuntimeDirectoryMode=0700
Environment=XVPN_USER=@USER@
Environment=XVPN_USER_STATE=@HOME@/.local/state/serpantinum/vpn
Environment=XVPN_USER_DATA=@HOME@/.local/share/serpantinum-x/vpn
Environment=XRAY_LOCATION_ASSET=/run/serp-xray/geo
ExecStartPre=@HELPER@ guard
ExecStartPre=@HELPER@ prepare
ExecStart=@XRAY@ run -c /run/serp-xray/config.json
ExecStartPost=@HELPER@ post-start
ExecStopPost=@HELPER@ post-stop
Restart=no
TimeoutStartSec=30
TimeoutStopSec=15
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=read-only
ProtectSystem=full
