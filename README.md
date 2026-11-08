# pihole-unbound-installer

Convierte un **Pi-hole v6** en un DNS que resuelve por sí mismo, sin depender de Google ni de Cloudflare:
**Unbound** como resolver recursivo local con **validación DNSSEC**. De paso deja la web del Pi-hole
entrando por `http://IP/`, sin tener que escribir `/admin`.

Sigue la [guía oficial de Pi-hole + Unbound](https://docs.pi-hole.net/guides/dns/unbound/) y le suma
las correcciones que la guía no trae para **Pi-hole v6** y **Debian 13**.

> Proyecto independiente: **no está afiliado ni aprobado por Pi-hole ni por NLnet Labs**.
> Fuentes, créditos y licencias en [Fuentes oficiales](#fuentes-oficiales) y [NOTICE.md](NOTICE.md).

## ⚡ Instalación rápida (one-liner)

En un servidor **Debian 12/13 o Ubuntu** con **Pi-hole v6** ya instalado, como `root`:

```bash
curl -fsSL --retry 5 --retry-all-errors https://raw.githubusercontent.com/mtandazo35/pihole-unbound-installer/main/install.sh -o /root/pihole-unbound-install.sh && bash /root/pihole-unbound-install.sh
```

Solo una parte:

```bash
bash /root/pihole-unbound-install.sh --solo-web       # solo la redirección / -> /admin/
bash /root/pihole-unbound-install.sh --solo-unbound   # solo Unbound
bash /root/pihole-unbound-install.sh --desinstalar    # volver a los upstreams anteriores
```

¿Aún no tienes Pi-hole? Instálalo primero con `curl -sSL https://install.pi-hole.net | bash`.

## Qué hace, paso a paso

1. **Comprueba** que eres root, que es Debian/Ubuntu y que el Pi-hole es v6 (`pihole-FTL --config`).
2. **Respalda** `pihole.toml`, `resolv.conf`, `/etc/unbound` y el resto de lo que toca en `/root/backups/`.
3. **Web**: escribe un `index.html` que redirige a `/admin/` y activa `webserver.serve_all`.
4. **Prueba previa**: consulta `a.root-servers.net` por UDP y TCP y pide `version.bind`. Si el DNS
   está interceptado o el TCP/53 bloqueado (típico de CGNAT), **se detiene sin tocar nada**.
5. **Simula** `apt install unbound` y aborta si apt fuese a quitar algún paquete.
6. Instala `unbound` + `dns-root-data`, apaga `unbound-resolvconf` y sube los buffers de red.
7. Escribe `/etc/unbound/unbound.conf.d/pi-hole.conf` (puerto `5335`, solo `127.0.0.1`),
   autodetecta IPv6, valida con `unbound-checkconf` y reinicia.
8. **Prueba** que resuelve y que DNSSEC rechaza firmas rotas. Solo si todo pasa, apunta Pi-hole a
   `127.0.0.1#5335`. Si Pi-hole deja de resolver, **restaura los upstreams anteriores solo**.

Al final debe verse algo así:

```
[OK] Root servers alcanzables por UDP y TCP, sin interceptación.
[OK] Unbound 1.26.2 instalado.
[OK] unbound-resolvconf desactivado (sin forwarders heredados).
[OK] Resuelve: pi-hole.net -> 192.0.2.10
[OK] DNSSEC: fail01.dnssec.works -> SERVFAIL (firma rota rechazada).
[OK] DNSSEC: dnssec.works con flag ad.
[OK] Pi-hole resuelve vía Unbound (example.com -> 192.0.2.20). Upstreams: [ 127.0.0.1#5335 ]
```

Se puede ejecutar más de una vez: reescribe la misma configuración y vuelve a probar.

## Lo aprendido (por qué el script hace cada cosa)

### Pi-hole v6: `/` da 404 aunque exista `index.html`

En v6 **ya no hay lighttpd**: la web la sirve el propio `pihole-FTL`. Con `webserver.serve_all = false`
(el valor por defecto) FTL solo entrega lo que está bajo `/admin/`, así que la receta antigua
(`index.html` con meta-refresh + `systemctl reload lighttpd`) deja de funcionar. Falta una línea:

```bash
pihole-FTL --config webserver.serve_all true
```

### `resolvconf` convierte Unbound en un simple reenviador

Si el sistema tiene `resolvconf` u `openresolv` (las imágenes cloud de Debian 13 lo traen),
`unbound-resolvconf.service` copia los `nameserver` de `/etc/resolv.conf` (p. ej. `8.8.8.8`) como
*forwarders* de Unbound. Todo "funciona", pero Unbound ya no resuelve desde la raíz: le pregunta a
Google. El script apaga ese servicio, comenta `unbound_conf=` en `/etc/resolvconf.conf` y borra
`resolvconf_resolvers.conf`. Compruébalo con:

```bash
unbound-control list_forwards     # vacío = recursivo de verdad
```

> **No desinstales `resolvconf` con apt** en una VM cloud de Debian 13: la resolución de
> dependencias puede llevarse el kernel por delante. Basta con apagar el servicio.

### Avisos de `so-rcvbuf` y `so-sndbuf`

La configuración pide `so-rcvbuf: 1m` y Unbound 1.2x trae `so-sndbuf` de 4 MB por defecto; el kernel
de Debian da 208 KB, y Unbound avisa al arrancar:

```
warning: so-sndbuf 4194304 was not granted. Got 425984.
```

La guía solo cubre el de recepción. El script crea `/etc/sysctl.d/99-unbound.conf` con los dos:

```
net.core.rmem_max=1048576
net.core.wmem_max=4194304
```

### IPv6

Con `do-ip6: yes` y sin salida IPv6 real, Unbound pierde tiempo probando servidores IPv6 que no
contestan. El script pone `do-ip6: yes` solo si hay dirección IPv6 global **y** responde
`a.root-servers.net` por IPv6. Se puede forzar con `FORCE_IPV6=yes|no`.

### Pi-hole v6 se configura con `pihole-FTL --config`

Ya no hay `setupVars.conf`: el upstream se cambia con

```bash
pihole-FTL --config dns.upstreams '["127.0.0.1#5335"]'
```

No hace falta activar DNSSEC en Pi-hole (`dns.dnssec`): ya valida Unbound.

### Log en archivo y AppArmor

El script deja Unbound escribiendo al journal (`journalctl -u unbound`). Para un archivo propio
hay que darle permiso en AppArmor, o Unbound no podrá escribirlo:

```bash
mkdir -p /var/log/unbound && touch /var/log/unbound/unbound.log && chown unbound /var/log/unbound/unbound.log
echo '/var/log/unbound/unbound.log rw,' >> /etc/apparmor.d/local/usr.sbin.unbound
apparmor_parser -r /etc/apparmor.d/usr.sbin.unbound
# y en pi-hole.conf: logfile: "/var/log/unbound/unbound.log"  +  log-time-ascii: yes  +  verbosity: 1
systemctl restart unbound
```

`verbosity` alto en uso diario llena el disco: déjalo en 0 o 1.

### Antes de instalar: ¿llegas a la raíz de verdad?

Si tu red intercepta el DNS o bloquea el TCP/53 (CGNAT de algunos operadores), un resolver recursivo
va a fallar de forma intermitente. La prueba manual:

```bash
dig @198.41.0.4 . NS +norec +time=3 | grep flags          # aa y SIN ra
dig @198.41.0.4 . NS +norec +tcp +time=3 | grep flags    # igual; timeout = TCP/53 bloqueado
dig @198.41.0.4 version.bind CH TXT +short               # "ATLAS"
```

## Comprobar a mano

```bash
dig pi-hole.net @127.0.0.1 -p 5335                         # resuelve (la 1ª vez tarda más)
dig fail01.dnssec.works @127.0.0.1 -p 5335                 # SERVFAIL
dig +ad dnssec.works @127.0.0.1 -p 5335 | grep flags       # incluye ad
pihole-FTL --config dns.upstreams                          # [ 127.0.0.1#5335 ]
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/ # 200
```

## Volver atrás

```bash
bash /root/pihole-unbound-install.sh --desinstalar
```

Restaura los upstreams que tenía Pi-hole antes de la primera ejecución (guardados en
`/root/.pihole-unbound-installer/upstreams.prev`; si no existen, usa `1.1.1.1` y `1.0.0.1`) y
detiene Unbound. A mano:

```bash
pihole-FTL --config dns.upstreams '["1.1.1.1","1.0.0.1"]'
systemctl disable --now unbound
pihole-FTL --config webserver.serve_all false   # solo si quieres quitar la redirección
```

Cada ejecución deja un `tar.gz` en `/root/backups/` con lo que había antes.

## Variables

| Variable | Defecto | Para qué |
|---|---|---|
| `UNBOUND_PORT` | `5335` | puerto local de Unbound |
| `FORCE_IPV6` | autodetectado | `yes` / `no` para `do-ip6` |
| `SKIP_PRECHECK` | `0` | `1` salta la prueba de root servers (no recomendado) |

Ejemplo: `FORCE_IPV6=no bash /root/pihole-unbound-install.sh --solo-unbound`

## Probado en

- Debian 13 (trixie), Pi-hole Core v6.5 / Web v6.6.1 / FTL v6.8, Unbound 1.26.2.

## Fuentes oficiales

Todo lo que hace el script sale de estas fuentes (consultadas el 2026-11-08):

| Tema | Fuente |
|---|---|
| Guía Pi-hole + Unbound (configuración base, pruebas previas, DNSSEC, `unbound-resolvconf`, `so-rcvbuf`, log y AppArmor) | [docs.pi-hole.net/guides/dns/unbound](https://docs.pi-hole.net/guides/dns/unbound/) |
| Opciones de Pi-hole v6 (`webserver.serve_all`, `webserver.paths.webroot`, `dns.upstreams`, `dns.dnssec`) | [docs.pi-hole.net/ftldns/configfile](https://docs.pi-hole.net/ftldns/configfile/) |
| Instalar Pi-hole | [docs.pi-hole.net/main/basic-install](https://docs.pi-hole.net/main/basic-install/) |
| Directivas de Unbound (`so-rcvbuf`, `so-sndbuf`, `edns-buffer-size`, `harden-*`, `private-address`, `do-ip6`) | [unbound.conf(5) — NLnet Labs](https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound.conf.html) |
| Documentación general de Unbound | [unbound.docs.nlnetlabs.nl](https://unbound.docs.nlnetlabs.nl/en/latest/) |
| Root servers (`a.root-servers.net` = 198.41.0.4 / 2001:503:ba3e::2:30) | [IANA — Root Servers](https://www.iana.org/domains/root/servers) · [root-servers.org](https://root-servers.org/) |
| Archivo de root hints | [InterNIC — named.root](https://www.internic.net/domain/named.root) |
| Paquetes de Debian usados | [unbound](https://packages.debian.org/trixie/unbound) · [dns-root-data](https://packages.debian.org/trixie/dns-root-data) |
| `edns-buffer-size: 1232` | [DNS Flag Day 2020](https://www.dnsflagday.net/2020/) |
| Rangos de `private-address` | [RFC 6303](https://www.rfc-editor.org/rfc/rfc6303) · [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737) |
| Dominios de prueba DNSSEC (`dnssec.works`, `fail01.dnssec.works`) | [dnssec.works](https://dnssec.works/) |
| Uso del nombre Pi-hole | [Pi-hole — Trademark rules and brand guidelines](https://pi-hole.net/trademark-rules-and-brand-guidelines/) |

Lo que **no** viene de la guía y se aprendió en pruebas reales: `webserver.serve_all` para la
redirección, `wmem_max` por el `so-sndbuf` de Unbound 1.2x, no desinstalar `resolvconf` en Debian 13
cloud, la autodetección de IPv6 y la reversión automática de upstreams.

## Licencia, créditos y marcas

- **Código del script:** MIT — ver [LICENSE](LICENSE).
- **Configuración de Unbound y las secciones de este README adaptadas de la guía de Pi-hole:**
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.es), igual que la obra original
  ([*unbound — Pi-hole documentation*](https://docs.pi-hole.net/guides/dns/unbound/), © Pi-hole y
  colaboradores de [pi-hole/docs](https://github.com/pi-hole/docs)). Cambios respecto al original en
  [NOTICE.md](NOTICE.md).
- **Pi-hole®** es una marca registrada de Pi-hole; **Unbound** es software de NLnet Labs (BSD-3-Clause).
  Este proyecto no está afiliado, patrocinado ni aprobado por ninguno de los dos; el nombre se usa solo
  para indicar compatibilidad, sin fines comerciales y sin el logo.
- El instalador no redistribuye software de terceros: instala Unbound desde los repositorios oficiales
  de la distribución.
