# Security

XTermX is a terminal: commands run with the permissions of the account running the host. Pairing a device and enabling remote control grants access to terminal sessions according to host permissions. Keep pairing links, QR codes, host secrets, agent-tool tokens and SSH credentials private.

The transport uses authenticated encrypted frames and replay counters. That does not make an exposed terminal host risk-free. Use a trusted network or VPN, review firewall exposure and disable sharing for private panes. Optional external notifications may transmit the configured event content to the services you select.

To revoke existing pairings, use **Forget all devices** and pair trusted devices again. This rotates the shared pairing secret. An offline device-history entry is not proof of an active network connection.

## Reporting

Do not disclose a live credential or an exploitable private environment in a public issue. Use the contact options on [cassel.us](https://cassel.us) to arrange a private report. Provide a minimal reproduction using fictional data, the affected component and version, and the expected impact. No response-time commitment or independent security audit is claimed.

The separately maintained proprietary iOS and Watch applications are outside this source repository's publication scope.
