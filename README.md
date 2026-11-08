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
8. Ajusta hilos y caché a la máquina (vCPU y RAM) y activa `serve-expired`.
9. **Prueba** que resuelve y que DNSSEC rechaza firmas rotas. Solo si todo pasa, apunta Pi-hole a
   `127.0.0.1#5335`. Si Pi-hole deja de resolver, **restaura los upstreams anteriores solo**.
10. Programa la actualización diaria de las listas de bloqueo.

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

### `CONNECTION_ERROR ... Connection prematurely closed by remote server`

Aparece en **Pi-hole → Diagnosis** con el upstream `127.0.0.1#5335`:

```
Connection error (127.0.0.1#5335): TCP connection failed while receiving payload length
from upstream (Connection prematurely closed by remote server)
```

En `/var/log/pihole/pihole.log` se ve como una ráfaga de consultas TCP del mismo cliente (cada
`dnsmasq[PID]` distinto es una conexión TCP) seguida de `TCP connection failed`.

**Causa:** Unbound acepta por defecto `incoming-num-tcp: 10` conexiones TCP entrantes por hilo. Según
la documentación de `tcp-idle-timeout` en
[unbound.conf(5)](https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound.conf.html), cuando
quedan libres menos del 50 % de esas conexiones, el tiempo de espera baja al 1 %; por debajo del 35 % baja
al 0,2 %, y por debajo del 20 % llega a 0. Con 6 a 8 conexiones TCP a la vez (navegadores y apps lo hacen),
si Unbound está resolviendo un nombre que no tiene en caché, cierra la conexión antes de contestar.

**Solución** (incluida en el script):

```
    incoming-num-tcp: 100
```

Gasta muy poca memoria (en las pruebas el RSS no cambió), Unbound ajusta su límite de archivos
abiertos sin intervención (4096 + 100 + …) y, como escucha solo en `127.0.0.1`, nadie de fuera puede
ocupar esas conexiones. Probado con 40 consultas TCP simultáneas sin ningún corte.

### Rendimiento: caché, serve-stale e hilos

La guía usa los valores por defecto de caché (4 MB) y un solo hilo. Con un Pi-hole que atiende
a toda una red, Unbound pasa la mayor parte del tiempo resolviendo desde la raíz (en las pruebas,
0,25 s de media y más de 1 s en dominios lejanos). El script añade:

```
    num-threads: <vCPU, de 1 a 4>
    msg-cache-size: 64m        # 16m si la máquina tiene menos de 2 GB de RAM
    rrset-cache-size: 128m     # 32m si la máquina tiene menos de 2 GB de RAM
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-client-timeout: 1800
```

`serve-expired` ([RFC 8767](https://www.rfc-editor.org/rfc/rfc8767)): si un registro caducó, Unbound
intenta renovarlo durante 1,8 s y, si no lo consigue, responde con el que tenía guardado (como mucho de
hace 24 h). El usuario no espera y, si un servidor autoritativo se cae, el dominio sigue resolviendo.

### Listas al día

Pi-hole actualiza las listas solo los domingos (`/etc/cron.d/pihole`). Listas como
[HaGeZi](https://github.com/hagezi/dns-blocklists) cambian varias veces al día, así que el script
crea `/etc/cron.d/pihole-gravity-diario` (lunes a sábado, 04:17, `pihole -g`). Es un archivo
propio: las actualizaciones de Pi-hole no lo sobrescriben.

### Bloquear los anuncios dentro de juegos y apps

StevenBlack (la lista por defecto) está pensada sobre todo para la web y deja pasar a las redes de
anuncios de juegos móviles (Moloco, Mintegral, Pangle, Kidoz, la mediación de Unity, AppsFlyer…).
Las cubre [HaGeZi Pro](https://github.com/hagezi/dns-blocklists). En **Pi-hole → Lists** añade (formato
adblock, Pi-hole v6 lo entiende y bloquea también los subdominios):

```
https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt
https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/doh.txt   # opcional
```

La segunda bloquea los servidores de **DNS cifrado** (`dns.google`, `cloudflare-dns.com`,
`dns.adguard.com`…) con los que móviles y navegadores se saltan el Pi-hole. Si un Android tiene el
"DNS privado" puesto a mano con uno de ellos, se queda sin internet hasta ponerlo en *Automático*.
Los juegos con "ver anuncio para obtener recompensa" pueden dejar de dar la recompensa. El script
**no** añade estas listas: es decisión de cada red.

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
| `serve-expired` (servir datos caducados) | [RFC 8767](https://www.rfc-editor.org/rfc/rfc8767) |
| Listas de bloqueo HaGeZi | [github.com/hagezi/dns-blocklists](https://github.com/hagezi/dns-blocklists) |
| Rangos de `private-address` | [RFC 6303](https://www.rfc-editor.org/rfc/rfc6303) · [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737) |
| Dominios de prueba DNSSEC (`dnssec.works`, `fail01.dnssec.works`) | [dnssec.works](https://dnssec.works/) |
| Uso del nombre Pi-hole | [Pi-hole — Trademark rules and brand guidelines](https://pi-hole.net/trademark-rules-and-brand-guidelines/) |

Lo que **no** viene de la guía y se aprendió en pruebas reales: `webserver.serve_all` para la
redirección, `wmem_max` por el `so-sndbuf` de Unbound 1.2x, `incoming-num-tcp: 100` contra el
`CONNECTION_ERROR` de conexiones TCP, no desinstalar `resolvconf` en Debian 13
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
