# Keys and secrets

The private keys and secrets the image carries are not in this repository
(`.gitignore` lists them). A build needs them in place; without them the
packages that install them fail. Templates of the two configuration files are
under `secrets.example/`, at the same paths.

| File | What it is | Installed as |
|---|---|---|
| `files/etc/certificate/bmc.key` | key of the device certificate `bmc.crt` (uhttpd, bmcfirewall, bmcfido) | `/etc/certificate/bmc.key` |
| `files/etc/certificate/key.pem` | key of `cert.pem` | `/etc/certificate/key.pem` |
| `package/network/services/uhttpd/files/uhttpd.key` | key of `uhttpd.crt` | `/etc/uhttpd.key` |
| `package/community/squid/files/squid_CA.key` | key of the SSL-bump CA `squid_CA.crt` | `/etc/squid/ssl_cert/` |
| `package/community/squid/files/squid_CA.pem` | `squid_CA.crt` followed by `squid_CA.key` (squid.conf reads it) | `/etc/squid/ssl_cert/` |
| `package/bmc/bmcfido/files/fido2cap-server/.env` | `ENABLE_HTTPS`, `SESSION_KEY` of bmcfido | `/etc/bmcfido/.env` |
| `files/etc/config/account` | the default web accounts (bcrypt hashes) | `/etc/config/account` |

The certificates (`.crt`, `cert.pem`) are in the repository. A key has to
match its certificate: with a new key, make the certificate again too and
replace the one in the tree.

## Making them

From the top of the tree:

```sh
# the device certificate and its key
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=bmc" \
	-keyout files/etc/certificate/bmc.key -out files/etc/certificate/bmc.crt
# cert.pem / key.pem
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=bmc" \
	-keyout files/etc/certificate/key.pem -out files/etc/certificate/cert.pem
# uhttpd
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=uhttpd" \
	-keyout package/network/services/uhttpd/files/uhttpd.key \
	-out package/network/services/uhttpd/files/uhttpd.crt
# the squid SSL-bump CA (clients must trust squid_CA.crt)
d=package/community/squid/files
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=BMC Proxy CA" \
	-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
	-keyout $d/squid_CA.key -out $d/squid_CA.crt
cat $d/squid_CA.crt $d/squid_CA.key > $d/squid_CA.pem

# bmcfido and the web accounts, from the templates
cp secrets.example/package/bmc/bmcfido/files/fido2cap-server/.env \
	package/bmc/bmcfido/files/fido2cap-server/.env
sed -i "s/^SESSION_KEY=.*/SESSION_KEY=$(openssl rand -hex 64)/" \
	package/bmc/bmcfido/files/fido2cap-server/.env
cp secrets.example/files/etc/config/account files/etc/config/account
```

In `files/etc/config/account`, replace each `CHANGE_ME` with the bcrypt hash
(`$2b$10$...`) of the password, for example:

```sh
python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())' '<password>'
```
