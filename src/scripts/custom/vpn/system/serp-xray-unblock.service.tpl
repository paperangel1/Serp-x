# Managed by Serpantinum. Removes the kill-switch blackhole (started by the user through polkit).
[Unit]
Description=Serpantinum VPN kill-switch release

[Service]
Type=oneshot
ExecStart=@HELPER@ unblock
