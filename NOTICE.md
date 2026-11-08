# Avisos, créditos y licencias de terceros

## Licencias de este repositorio

| Parte | Licencia |
|---|---|
| Código propio de `install.sh` (lógica, comprobaciones, reversión) | [MIT](LICENSE) |
| Bloque de configuración de Unbound que escribe `install.sh` (`/etc/unbound/unbound.conf.d/pi-hole.conf`) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.es), por ser adaptación de la guía oficial de Pi-hole |
| Las partes del `README.md` que resumen o adaptan esa guía (instalación de Unbound, pruebas previas a los root servers, pruebas DNSSEC, `unbound-resolvconf`, `so-rcvbuf`, log y AppArmor) | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.es) |

## Obra de la que se adapta

- **Título:** *unbound — Pi-hole documentation* ("Pi-hole as All-Around DNS Solution")
- **URL:** https://docs.pi-hole.net/guides/dns/unbound/
- **Autores:** Pi-hole y colaboradores del repositorio [pi-hole/docs](https://github.com/pi-hole/docs)
- **Licencia de la obra:** [Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)](https://creativecommons.org/licenses/by-sa/4.0/)
  (licencia declarada en el repositorio [pi-hole/docs](https://github.com/pi-hole/docs))
- **Consultada:** 2026-11-08

### Cambios hechos sobre la obra original

1. `do-ip6` se autodetecta (`yes` solo si hay IPv6 global y responde `a.root-servers.net`) en lugar de `yes` fijo.
2. `port` es configurable (`UNBOUND_PORT`, por defecto `5335`, el mismo de la guía).
3. Se quitaron los comentarios largos de la guía y la línea comentada de `root-hints`; se añadieron comentarios propios.
4. No se activa `logfile` (Unbound escribe al journal) para no depender de AppArmor.
5. Se añade `net.core.wmem_max=4194304` al sysctl de la guía, por el `so-sndbuf` por defecto de Unbound 1.2x
   (ver la [documentación de unbound.conf](https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound.conf.html)).
6. Se añade `incoming-num-tcp: 100`, que la guía no trae, para evitar los cortes de conexiones TCP
   que Pi-hole muestra como `CONNECTION_ERROR` (ver README).
7. `num-threads` y caché (`msg-cache-size`, `rrset-cache-size`) se ajustan a la máquina, y se activa
   `serve-expired` (RFC 8767). La guía usa 1 hilo y los valores por defecto.
8. Los pasos se ajustaron a Pi-hole v6 (`pihole-FTL --config`), que la guía no trata.

## Software que el instalador usa (no se redistribuye)

`install.sh` **no incluye ni redistribuye** código de terceros: instala paquetes desde los repositorios
oficiales de la distribución y configura el Pi-hole que ya tengas instalado.

| Software | Autor | Licencia | Fuente oficial |
|---|---|---|---|
| Unbound | NLnet Labs | BSD-3-Clause | https://nlnetlabs.nl/projects/unbound/about/ · https://github.com/NLnetLabs/unbound |
| dns-root-data | Debian (datos de IANA) | — | https://packages.debian.org/trixie/dns-root-data |
| Pi-hole | Pi-hole | ver su repositorio | https://pi-hole.net · https://github.com/pi-hole/pi-hole |

## Marcas

**Pi-hole®** es una marca registrada de Pi-hole. Este proyecto **no está afiliado, patrocinado,
respaldado ni aprobado** por Pi-hole ni por NLnet Labs. El nombre se usa solo para indicar con qué
software funciona, sin fines comerciales, conforme a las
[reglas de marca de Pi-hole](https://pi-hole.net/trademark-rules-and-brand-guidelines/).
No se usa el logo de Pi-hole. Unbound es un proyecto de NLnet Labs.

Este documento no es asesoramiento legal.
