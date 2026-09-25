Test	Result
VPN route 10.0.8.0/21	Pass
DC DNS 10.0.9.4:53	Pass
DC RDP 10.0.9.4:3389	Pass
SQL-VM-1 10.0.10.4:1433	Pass
SQL-VM-2 10.0.11.4:1433	Pass
Active listener 10.0.10.11:14333	Pass
Passive listener 10.0.11.11:14333	Offline, expected
ag-listener.contoso.local DNS	Resolves to both listener IPs
